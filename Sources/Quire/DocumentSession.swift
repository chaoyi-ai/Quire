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
    private var editDebounce: DispatchWorkItem?
    var onOutline: ((Outline) -> Void)?
    /// 全文统计（与解析同一趟后台任务里算）
    var onStats: ((TextStats) -> Void)?
    private(set) var stats = TextStats()

    private var parser = MarkdownParser(options: Preferences.shared.parserOptions)
    nonisolated(unsafe) private var prefsObserver: NSObjectProtocol?

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
                if o.math != self.parser.options.math {   // 解析选项变了：重解析
                    self.parser = MarkdownParser(options: o)
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
        if reason == .opened, src.utf8.count <= Self.syncRenderThreshold {
            // 同步路径：窗口首帧就带内容
            let doc = parser.parse(src)
            let out = renderer.render(doc)
            parsed = doc
            rendered = out
            LaunchClock.mark("parse+render done (sync)")
            onRendered?(out, renderer.style, reason, nil)
            onOutline?(doc.outline)
            stats = TextStats.compute(src)
            onStats?(stats)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let sp = OSSignpostID(log: perfLog)
            os_signpost(.begin, log: perfLog, name: "parse+render", signpostID: sp, "%d bytes", src.utf8.count)
            let doc = parser.parse(src)
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
                self.rendered = out
                self.onRendered?(out, renderer.style, reason, d)
                self.onOutline?(doc.outline)
                self.stats = st
                self.onStats?(st)
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

    func startWatching() {
        guard Preferences.shared.autoReload, let url = document?.fileURL else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                self?.document?.reloadFromDisk()
            }
        }
    }

    func stopWatching() { watcher = nil }
}
