import AppKit
import QuireCore
import QuireRender

/// 阅读视图控制器：NSScrollView + ReaderTextView，订阅 DocumentSession。
@MainActor
final class ReaderViewController: NSViewController, NSTextViewDelegate {
    let session: DocumentSession
    private(set) var textView: ReaderTextView!
    private var scrollView: NSScrollView!
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var prefsObserver: NSObjectProtocol?
    private var banner: NSView!
    private var bannerTop: NSLayoutConstraint!
    private var lastTopBlock: Int?
    /// 视口顶部块变化回调（目录高亮）
    var onTopBlockChanged: ((Int) -> Void)?
    /// 侧栏"当前章节"所在块变化（取样点在可见区上部，见 ReaderTextView.sectionBlockIndex）
    var onSectionChanged: ((Int) -> Void)?
    private var lastSectionBlock: Int?

    init(session: DocumentSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let style = session.style
        textView = HybridTextView(style: style)   // 混合模式（实验）是它的子类；关着就是普通阅读视图
        textView.delegate = self
        textView.baseURL = session.document?.fileURL
        textView.onDropFiles = { urls in FileOpener.open(urls) }
        textView.onImageClick = { [weak self] src in
            guard let url = ImageLoader.resolve(src, relativeTo: self?.session.document?.fileURL) else { return }
            NSWorkspace.shared.open(url)   // 系统看图 / 浏览器
        }

        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = style.background
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = true
        textView.showsCodeCopyButtons = Preferences.shared.codeCopyButton

        // 容器：顶部可选横幅（大文件模式）+ 滚动视图
        let container = NSView(frame: scrollView.frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        banner = makeBanner()
        banner.isHidden = true
        container.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        bannerTop = scrollView.topAnchor.constraint(equalTo: container.topAnchor)
        bannerTop.isActive = true
        view = container
        session.onLargeFileModeChanged = { [weak self] on in self?.setBanner(visible: on) }
        if session.isLargeFile { setBanner(visible: true) }
        prefsObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textView.showsCodeCopyButtons = Preferences.shared.codeCopyButton }
        }

        // 滚动 → 目录高亮（通知驱动，无定时器）
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportDidScroll() }
        }

        session.onRendered = { [weak self] doc, style, reason, diff in
            self?.apply(doc, style: style, reason: reason, diff: diff)
        }
        if let r = session.rendered { apply(r, style: session.style, reason: .opened, diff: nil) }
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) }
    }

    private func makeBanner() -> NSView {
        let v = NSVisualEffectView()
        v.material = .headerView
        v.blendingMode = .withinWindow
        v.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: L("大文件模式：已关闭代码高亮与 Mermaid 渲染以保持流畅（阈值可在设置中调整）"))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.heightAnchor.constraint(equalToConstant: 30),
        ])
        return v
    }

    private func setBanner(visible: Bool) {
        banner.isHidden = !visible
        bannerTop.isActive = false
        bannerTop = visible ? scrollView.topAnchor.constraint(equalTo: banner.bottomAnchor) : scrollView.topAnchor.constraint(equalTo: view.topAnchor)
        bannerTop.isActive = true
    }

    private static var didReportLaunch = false
    /// QUIRE_MEASURE_LAUNCH=1：首个文档首帧后打印进程启动 → 首帧耗时并退出（scripts/bench.sh launch）
    private func reportLaunchIfNeeded() {
        guard !Self.didReportLaunch, ProcessInfo.processInfo.environment["QUIRE_MEASURE_LAUNCH"] != nil else { return }
        Self.didReportLaunch = true
        DispatchQueue.main.async {   // 等这一帧真正画出来
            let ms = LaunchClock.millisecondsSinceProcessStart()
            FileHandle.standardError.write("QUIRE_LAUNCH_MS=\(Int(ms))\n".data(using: .utf8)!)
            if ProcessInfo.processInfo.environment["QUIRE_MEASURE_LAUNCH"] == "exit" { exit(0) }
        }
    }

    private func apply(_ doc: RenderedDocument, style: RenderStyle, reason: DocumentSession.ChangeReason, diff: BlockDiff?) {
        defer { if reason == .opened { reportLaunchIfNeeded() } }
        // 增量路径：编辑时只替换变化块，视口不动
        if reason == .edited, let diff, let previous = textView.rendered, style === textView.style {
            (textView as? HybridTextView)?.source = session.source
            if diff.isEmpty { textView.updateRendered(doc); return }
            textView.replaceBlocks(with: doc, diff: diff, previous: previous)
            viewportDidScroll()
            return
        }
        // 记住位置：顶部块 + 块内偏移
        let top = textView.topVisibleBlockIndex()
        let offset = top.map { textView.scrollOffset(withinBlock: $0) } ?? 0
        let topHash = top.flatMap { textView.rendered?.blocks[safe: $0]?.block.contentHash }

        scrollView.backgroundColor = style.background
        textView.baseURL = session.document?.fileURL
        (textView as? HybridTextView)?.source = session.source
        textView.setRendered(doc, style: style)
        LaunchClock.mark("setRendered done")

        switch reason {
        case .opened:
            scrollView.contentView.setBoundsOrigin(CGPoint(x: 0, y: -scrollView.contentInsets.top))
        case .externalChange, .edited, .theme, .zoom:
            // 优先按内容哈希找回原块（块可能移动），否则按下标
            if let top, let idx = Self.nearestBlock(withHash: topHash, around: top, in: doc) {
                textView.scroll(toBlock: idx, offset: offset)
            }
        }
        viewportDidScroll()
    }

    /// 找回原顶部块：优先同下标同哈希；否则以原下标为中心向两侧找同哈希（文档里可能有重复内容块，不能取 first）；再否则原下标
    static func nearestBlock(withHash hash: Int?, around top: Int, in doc: RenderedDocument) -> Int? {
        let n = doc.blocks.count
        guard n > 0 else { return nil }
        guard let hash else { return min(top, n - 1) }
        if top < n, doc.blocks[top].block.contentHash == hash { return top }
        var d = 1
        while top - d >= 0 || top + d < n {
            if top + d < n, doc.blocks[top + d].block.contentHash == hash { return top + d }
            if top - d >= 0, doc.blocks[top - d].block.contentHash == hash { return top - d }
            d += 1
        }
        return min(top, n - 1)
    }

    /// 程序化滚动（侧栏点击）期间挂起"顶部块 → 高亮"，避免动画途中逐个章节高亮
    private var isNavigating = false

    private func viewportDidScroll() {
        guard !isNavigating else { return }
        if let idx = textView.topVisibleBlockIndex(), idx != lastTopBlock { lastTopBlock = idx; onTopBlockChanged?(idx) }
        if let s = textView.sectionBlockIndex(), s != lastSectionBlock { lastSectionBlock = s; onSectionChanged?(s) }
    }

    /// 侧栏点击：动画滚到块，结束后把"当前块"明确设为目标块（哪怕它滚不到顶部，如文末章节）
    func scroll(toBlock index: Int) {
        isNavigating = true
        textView.scroll(toBlock: index, animated: true) { [weak self] in
            guard let self else { return }
            self.isNavigating = false
            self.lastTopBlock = index
            self.onTopBlockChanged?(index)
            self.lastSectionBlock = index
            self.onSectionChanged?(index)
        }
    }

    // MARK: - 链接

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let target: String
        if let u = link as? URL { target = u.absoluteString } else if let s = link as? String { target = s } else { return false }
        return LinkOpener.open(target, from: session.document?.fileURL, in: self)
    }

    /// 内部锚点跳转：标题 id 或脚注 fn-<label>
    func scroll(toAnchor id: String) -> Bool {
        guard let rendered = textView.rendered else { return false }
        for (i, b) in rendered.blocks.enumerated() {
            switch b.block.kind {
            case .heading(_, _, let hid) where hid == id:
                scroll(toBlock: i); return true
            case .footnoteDefinition(let label, _) where id == "fn-\(label)":
                scroll(toBlock: i); return true
            default: continue
            }
        }
        return false
    }

    /// 打印 / PDF 用视图：独立一份文本视图，宽度按纸张；缩放固定为 1，主题为当前主题
    /// 打印 / 导出用的视图：独立渲染一份（浅色主题、打印宽度），**等全部图片 / Mermaid 加载完**再分页——
    /// 屏幕视图那套异步加载对同步的 NSPrintOperation.run() 没用，以前导出的 PDF 里图片全是占位框
    func printableView(width: CGFloat = 540, layout: PDFLayout? = nil, document: MarkdownDocument? = nil) async -> ReaderTextView {
        var options = session.style.options
        if let layout { options.headingNumbers = layout.headingNumbers }
        // 打印 / PDF 永远用浅色主题；导出图片（layout == nil 且来自 writeImage）保留当前主题
        let theme = layout != nil ? ThemeManager.shared.printTheme : session.style.theme
        let style = RenderStyle(theme: theme, scale: 1, options: options)
        let tv = ReaderTextView(style: style)
        tv.showsCodeCopyButtons = false
        tv.loadsAttachmentsAutomatically = false
        tv.keepHeadingsWithNext = layout?.keepHeadingWithNext ?? false
        tv.baseURL = document?.fileURL ?? session.document?.fileURL
        tv.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        tv.textContainerInset = CGSize(width: 0, height: 0)
        tv.setPrintingWidth(width)
        // 打印用同一份 Document 重新渲染（可能与屏幕缩放不同）
        let rendered = DocumentRenderer(style: style).render(session.parsed)
        tv.setRendered(rendered, style: style)
        tv.textContainerInset = CGSize(width: 0, height: 0)
        tv.setPrintingWidth(width)
        await tv.loadAllAttachmentsForExport()
        tv.layoutAllForPrinting()
        if let layout {
            let title = session.parsed.outline.entries.first(where: { $0.level == 1 })?.title ?? document?.fileURL?.deletingPathExtension().lastPathComponent ?? ""
            let file = document?.fileURL?.lastPathComponent ?? ""
            let font = NSFont.systemFont(ofSize: 9)
            let color = NSColor(white: 0.45, alpha: 1)
            tv.printHeaderFooter = { page, pages in
                let h = PDFLayout.expand(layout.header, page: page, pages: pages, title: title, file: file).map { PDFLayout.line($0, width: width, font: font, color: color) }
                let f = PDFLayout.expand(layout.footer, page: page, pages: pages, title: title, file: file).map { PDFLayout.line($0, width: width, font: font, color: color) }
                return (h, f)
            }
        }
        return tv
    }
}

enum LinkOpener {
    @MainActor
    static func open(_ target: String, from base: URL?, in vc: ReaderViewController) -> Bool {
        if WikiLink.isWikiLink(target) {
            let name = (WikiLink.target(target).removingPercentEncoding ?? WikiLink.target(target))
            guard let wc = vc.view.window?.windowController as? DocumentWindowController else { return false }
            return wc.openWikiLink(name)
        }
        if target.hasPrefix("#") {
            return vc.scroll(toAnchor: String(target.dropFirst()).removingPercentEncoding ?? String(target.dropFirst()))
        }
        if let url = URL(string: target), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" || scheme == "mailto" { NSWorkspace.shared.open(url); return true }
            if scheme == "file" { return openLocal(url, from: base) }
        }
        // 相对路径
        guard let base else { return false }
        let path = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
        let url = URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: base.deletingLastPathComponent()).standardizedFileURL
        return openLocal(url, from: base)
    }

    /// 本地文件：Markdown 在 Quire 里打开（记进跳转历史，⌃⌘← 能回来），其他交给系统
    @MainActor
    static func openLocal(_ url: URL, from current: URL? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if QuireDocumentController.markdownExtensions.contains(url.pathExtension.lowercased()) {
            NavigationHistory.shared.push(current: current, to: url)
            FileOpener.open([url])   // 统一走 FileOpener：打不开会提示，不再 `{ _, _, _ in }` 吞掉
        } else {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}


/// 进程启动时刻（kernel p_starttime）到现在的毫秒数
public enum LaunchClock {
    public static let enabled = ProcessInfo.processInfo.environment["QUIRE_MEASURE_LAUNCH"] != nil
    public static func mark(_ label: String) {
        guard enabled else { return }
        FileHandle.standardError.write("  [launch] \(String(format: "%6.0f", millisecondsSinceProcessStart())) ms  \(label)\n".data(using: .utf8)!)
    }
    public static func millisecondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let startMs = Double(start.tv_sec) * 1000 + Double(start.tv_usec) / 1000
        var now = timeval()
        gettimeofday(&now, nil)
        let nowMs = Double(now.tv_sec) * 1000 + Double(now.tv_usec) / 1000
        return nowMs - startMs
    }
}


/// 打开一组文件（拖放 / 侧栏）
@MainActor
enum FileOpener {
    static func open(_ urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }
}

