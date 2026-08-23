import AppKit
import os
import QuireCore
import QuireRender

let perfLog = OSLog(subsystem: "com.korako.quire", category: "perf")

/// 一份文档的解析 / 渲染管线：源码变化或主题变化 → 后台工作 → 主线程发布 RenderedDocument。
/// 主线程只做装配；过期的后台结果按 generation 丢弃。
@MainActor
final class DocumentSession {
    enum ChangeReason { case opened, externalChange, edited, theme, zoom }

    weak var document: MarkdownDocument?
    private(set) var parsed: Document = .empty
    private(set) var rendered: RenderedDocument?
    private(set) var style: RenderStyle
    private(set) var source: String = ""
    private var generation = 0
    private var watcher: FileWatcher?
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?

    /// UI 订阅：每次有新渲染结果时调用（主线程）；`diff` 非空表示可增量替换（相对上一次发布的 rendered）
    var onRendered: ((RenderedDocument, RenderStyle, ChangeReason, BlockDiff?) -> Void)?
    /// 一次性等待：当前源码对应的渲染结果已发布就立刻回调，否则等下一次发布；`timeout` 秒内没等到回调 false。
    /// 给 URL scheme / Shortcuts / 跳行这类"打开后再做事"的路径用——以前用固定延时轮询，大文件（异步解析）下会带着空文档继续
    func whenRendered(timeout: TimeInterval = 15, _ body: @escaping @MainActor (Bool) -> Void) {
        if rendered != nil, parsedSource == source { body(true); return }
        renderWaiters.append(body)
        let gen = renderWaiterGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, gen == self.renderWaiterGeneration, !self.renderWaiters.isEmpty else { return }
            let ws = self.renderWaiters; self.renderWaiters = []
            ws.forEach { $0(false) }
        }
    }
    private var renderWaiters: [@MainActor (Bool) -> Void] = []
    private var renderWaiterGeneration = 0
    /// `parsed` 对应的源码（用来判断渲染是否已经赶上了最新编辑）
    private(set) var parsedSource: String = ""
    private func didPublish() {
        renderWaiterGeneration += 1
        guard !renderWaiters.isEmpty else { return }
        let ws = renderWaiters; renderWaiters = []
        ws.forEach { $0(true) }
    }
    private var editDebounce: DispatchWorkItem?
    var onOutline: ((Outline) -> Void)?
    /// 全文统计（与解析同一趟后台任务里算）
    var onStats: ((TextStats) -> Void)?
    private(set) var stats = TextStats()

    private var parser = MarkdownParser(options: Preferences.shared.parserOptions)
    nonisolated(unsafe) private var prefsObserver: NSObjectProtocol?

    /// 内容块 `![[file]]` 的根目录（窗口把侧栏根目录给进来；没有则文档所在目录）
    var transclusionRoot: (() -> URL?)?
    private var transclusionEnabled = Preferences.shared.transclusion
    /// 被内联的文件：改了就重解析
    private var includeWatchers: [String: FileWatcher] = [:]

    private var indexToken: ChangeObservers.Token?
    private func transclusionLoader() -> Transclusion.Loader? {
        guard transclusionEnabled, source.utf8.contains(0x21), source.contains("![[") else { return nil }
        guard let root = transclusionRoot?() ?? document?.fileURL?.deletingLastPathComponent() else { return nil }
        // 文件索引还在扫（刚打开）：这次按文件系统就近找，索引扫完再重解析一次，免得 `![[note]]` 一直停在"找不到"
        let index = FileIndex.index(for: root)
        if index.isScanning, indexToken == nil {
            indexToken = index.observers.add { [weak self] in
                guard let self else { return }
                self.indexToken = nil
                self.sourceDidChange(self.source, reason: .externalChange)
            }
        }
        return TransclusionLoader.make(root: root, document: document?.fileURL)
    }

    private func watchIncludes(_ paths: [String]) {
        let keep = Set(paths.prefix(32))
        for k in includeWatchers.keys where !keep.contains(k) { includeWatchers[k] = nil }
        for p in keep where includeWatchers[p] == nil {
            includeWatchers[p] = FileWatcher(url: URL(fileURLWithPath: p)) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sourceDidChange(self.source, reason: .externalChange)
                }
            }
        }
    }

    init(document: MarkdownDocument) {
        self.document = document
        self.style = ThemeManager.shared.currentStyle
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.themeDidChange() }
        }
        prefsObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let o = Preferences.shared.parserOptions
                let t = Preferences.shared.transclusion
                if o.math != self.parser.options.math || o.toc != self.parser.options.toc || o.smartPunctuation != self.parser.options.smartPunctuation || o.extendedInline != self.parser.options.extendedInline || t != self.transclusionEnabled {   // 解析选项变了：重解析
                    self.parser = MarkdownParser(options: o)
                    self.transclusionEnabled = t
                    self.sourceDidChange(self.source, reason: .externalChange)
                }
            }
        }
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) }
    }

    // MARK: - 输入

    /// 编辑器击键：合并 50 ms 内的多次变化
    func sourceDidChangeDebounced(_ newSource: String) {
        source = newSource
        editDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sourceDidChange(self.source, reason: .edited)
        }
        editDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    /// 首次打开的小文件同步渲染的阈值：256 KB 内 parse+render ≈ 40 ms，比再来一轮空视图布局更划算
    static let syncRenderThreshold = 256 * 1024

    /// 大文件模式（超过阈值：不高亮、不渲染 Mermaid）
    private(set) var isLargeFile = false
    var onLargeFileModeChanged: ((Bool) -> Void)?

    /// 大文件模式下的派生 style（缓存：同一基础 style 复用同一实例，保证 `===` 身份稳定，增量路径才能命中）
    private var largeFileStyle: (base: RenderStyle, derived: RenderStyle)?

    /// 当前有效 style（大文件模式下带 largeFile 选项）
    private func effectiveStyle() -> RenderStyle {
        let large = source.utf8.count > Preferences.shared.largeFileThresholdBytes
        if large != isLargeFile { isLargeFile = large; onLargeFileModeChanged?(large) }
        guard large else { return style }
        if let cached = largeFileStyle, cached.base === style { return cached.derived }
        var o = style.options; o.largeFile = true
        let derived = RenderStyle(theme: style.theme, scale: style.scale, options: o)
        largeFileStyle = (style, derived)
        return derived
    }

    /// 混合模式击键：只更新源码（保存 / 统计用），不解析不渲染；离开块时再 `sourceDidChange`
    func updateSourceWithoutRendering(_ newSource: String) {
        source = newSource
        editDebounce?.cancel()
    }

    func sourceDidChange(_ newSource: String, reason: ChangeReason) {
        source = newSource
        editDebounce?.cancel()
        generation += 1
        let gen = generation
        let parser = self.parser
        let renderer = DocumentRenderer(style: effectiveStyle())
        let previous = rendered
        let src = newSource
        let loader = transclusionLoader()
        let docPath = document?.fileURL?.path
        if reason == .opened, src.utf8.count <= Self.syncRenderThreshold {
            // 同步路径：窗口首帧就带内容
            var doc = parser.parse(src)
            if let loader { let r = Transclusion.expand(doc, parser: parser, fromPath: docPath, loader: loader); doc = r.document; watchIncludes(r.includedPaths) }
            let out = renderer.render(doc)
            parsed = doc
            parsedSource = src
            rendered = out
            LaunchClock.mark("parse+render done (sync)")
            onRendered?(out, renderer.style, reason, nil)
            onOutline?(doc.outline)
            stats = TextStats.compute(src)
            onStats?(stats)
            didPublish()
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let sp = OSSignpostID(log: perfLog)
            os_signpost(.begin, log: perfLog, name: "parse+render", signpostID: sp, "%d bytes", src.utf8.count)
            var doc = parser.parse(src)
            var includes: [String] = []
            if let loader { let r = Transclusion.expand(doc, parser: parser, fromPath: docPath, loader: loader); doc = r.document; includes = r.includedPaths }
            let out: RenderedDocument
            var diff: BlockDiff? = nil
            if let previous, reason == .externalChange || reason == .edited {
                let (r, d) = renderer.render(doc, reusing: previous)
                out = r
                // 变化块太多（如粘贴大段）就整体替换，避免逐块拼接开销
                diff = (d.newChanged.count <= 64 && d.oldChanged.count <= 64) ? d : nil
            } else {
                out = renderer.render(doc)
            }
            os_signpost(.end, log: perfLog, name: "parse+render", signpostID: sp, "%d blocks", doc.blocks.count)
            let st = TextStats.compute(src)
            let d = diff
            LaunchClock.mark("parse+render done (bg)")
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                LaunchClock.mark("publish to UI")
                self.parsed = doc
                self.parsedSource = src
                self.rendered = out
                self.watchIncludes(includes)
                self.onRendered?(out, renderer.style, reason, d)
                self.onOutline?(doc.outline)
                self.stats = st
                self.onStats?(st)
                self.didPublish()
            }
        }
    }

    func themeDidChange() {
        let newStyle = ThemeManager.shared.currentStyle
        guard newStyle !== style else { return }
        let reason: ChangeReason = newStyle.theme.id == style.theme.id ? .zoom : .theme
        style = newStyle
        rerender(reason: reason)
    }

    /// 不重解析，只重建属性字符串
    private func rerender(reason: ChangeReason) {
        // 最新编辑还没解析完（或被防抖压着）：重解析而不是拿旧的 parsed 重建，否则那次编辑的结果会被这里的 generation 顶掉、永远不再发布
        if parsedSource != source { sourceDidChange(source, reason: .edited); return }
        generation += 1
        let gen = generation
        let doc = parsed
        let renderer = DocumentRenderer(style: effectiveStyle())
        let s = renderer.style
        Task.detached(priority: .userInitiated) { [weak self] in
            let sp = OSSignpostID(log: perfLog)
            os_signpost(.begin, log: perfLog, name: "rerender", signpostID: sp)
            let out = renderer.render(doc)
            os_signpost(.end, log: perfLog, name: "rerender", signpostID: sp)
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.rendered = out
                self.onRendered?(out, s, reason, nil)
            }
        }
    }

    // MARK: - 文件监控

    /// 可重复调用：路径变了 / 偏好变了就换监视器；关了偏好或没有路径就停
    func startWatching() {
        guard Preferences.shared.autoReload, let url = document?.fileURL else { watcher = nil; watchedURL = nil; return }
        if watchedURL == url, watcher != nil { return }
        watchedURL = url
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                self?.document?.reloadFromDisk()
            }
        }
    }

    private var watchedURL: URL?
    func stopWatching() { watcher = nil; watchedURL = nil }
}
