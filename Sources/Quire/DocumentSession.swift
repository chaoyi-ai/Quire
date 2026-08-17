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
    private var source: String = ""
    private var generation = 0
    private var watcher: FileWatcher?
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?

    /// UI 订阅：每次有新渲染结果时调用（主线程）
    var onRendered: ((RenderedDocument, RenderStyle, ChangeReason) -> Void)?
    var onOutline: ((Outline) -> Void)?

    private let parser = MarkdownParser()

    init(document: MarkdownDocument) {
        self.document = document
        self.style = ThemeManager.shared.currentStyle
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.themeDidChange() }
        }
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    // MARK: - 输入

    func sourceDidChange(_ newSource: String, reason: ChangeReason) {
        source = newSource
        generation += 1
        let gen = generation
        let parser = self.parser
        let renderer = DocumentRenderer(style: style)
        let previous = rendered
        let src = newSource
        Task.detached(priority: .userInitiated) { [weak self] in
            let sp = OSSignpostID(log: perfLog)
            os_signpost(.begin, log: perfLog, name: "parse+render", signpostID: sp, "%d bytes", src.utf8.count)
            let doc = parser.parse(src)
            let out: RenderedDocument
            var diff: BlockDiff? = nil
            if let previous, reason == .externalChange || reason == .edited {
                let (r, d) = renderer.render(doc, reusing: previous)
                out = r; diff = d
            } else {
                out = renderer.render(doc)
            }
            os_signpost(.end, log: perfLog, name: "parse+render", signpostID: sp, "%d blocks", doc.blocks.count)
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.parsed = doc
                self.rendered = out
                _ = diff
                self.onRendered?(out, self.style, reason)
                self.onOutline?(doc.outline)
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
        let renderer = DocumentRenderer(style: style)
        let s = style
        Task.detached(priority: .userInitiated) { [weak self] in
            let sp = OSSignpostID(log: perfLog)
            os_signpost(.begin, log: perfLog, name: "rerender", signpostID: sp)
            let out = renderer.render(doc)
            os_signpost(.end, log: perfLog, name: "rerender", signpostID: sp)
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.rendered = out
                self.onRendered?(out, s, reason)
            }
        }
    }

    // MARK: - 文件监控

    func startWatching() {
        guard let url = document?.fileURL else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                self?.document?.reloadFromDisk()
            }
        }
    }

    func stopWatching() { watcher = nil }
}
