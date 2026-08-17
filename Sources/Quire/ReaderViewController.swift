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

    init(session: DocumentSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let style = session.style
        textView = ReaderTextView(style: style)
        textView.delegate = self
        textView.baseURL = session.document?.fileURL
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
        let label = NSTextField(labelWithString: "大文件模式：已关闭代码高亮与 Mermaid 渲染以保持流畅（阈值可在设置中调整）")
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
        if reason == .edited, let diff, let previous = textView.rendered, previous.blocks.count == diff.oldChanged.upperBound + (previous.blocks.count - diff.oldChanged.upperBound), style === textView.style {
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
        textView.setRendered(doc, style: style)
        LaunchClock.mark("setRendered done")

        switch reason {
        case .opened:
            scrollView.contentView.setBoundsOrigin(.zero)
        case .externalChange, .edited, .theme, .zoom:
            // 优先按内容哈希找回原块（块可能移动），否则按下标
            if let topHash, let idx = doc.blocks.firstIndex(where: { $0.block.contentHash == topHash }) {
                textView.scroll(toBlock: idx, offset: offset)
            } else if let top, top < doc.blocks.count {
                textView.scroll(toBlock: top, offset: offset)
            }
        }
        viewportDidScroll()
    }

    private func viewportDidScroll() {
        guard let idx = textView.topVisibleBlockIndex(), idx != lastTopBlock else { return }
        lastTopBlock = idx
        onTopBlockChanged?(idx)
    }

    func scroll(toBlock index: Int) {
        textView.scroll(toBlock: index, animated: true)
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
                textView.scroll(toBlock: i, animated: true); return true
            case .footnoteDefinition(let label, _) where id == "fn-\(label)":
                textView.scroll(toBlock: i, animated: true); return true
            default: continue
            }
        }
        return false
    }

    /// 打印 / PDF 用视图：独立一份文本视图，宽度按纸张；缩放固定为 1，主题为当前主题
    func printableView(width: CGFloat = 540) -> NSView {
        let style = RenderStyle(theme: session.style.theme, scale: 1, options: session.style.options)
        let tv = ReaderTextView(style: style)
        tv.showsCodeCopyButtons = false
        tv.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        tv.textContainerInset = CGSize(width: 0, height: 0)
        tv.setPrintingWidth(width)
        // 打印用同一份 Document 重新渲染（可能与屏幕缩放不同）
        let rendered = DocumentRenderer(style: style).render(session.parsed)
        tv.setRendered(rendered, style: style)
        tv.textContainerInset = CGSize(width: 0, height: 0)
        tv.setPrintingWidth(width)
        tv.layoutAllForPrinting()
        return tv
    }
}

enum LinkOpener {
    @MainActor
    static func open(_ target: String, from base: URL?, in vc: ReaderViewController) -> Bool {
        if target.hasPrefix("#") {
            return vc.scroll(toAnchor: String(target.dropFirst()).removingPercentEncoding ?? String(target.dropFirst()))
        }
        if let url = URL(string: target), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" || scheme == "mailto" { NSWorkspace.shared.open(url); return true }
            if scheme == "file" { return openLocal(url) }
        }
        // 相对路径
        guard let base else { return false }
        let path = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
        let url = URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: base.deletingLastPathComponent()).standardizedFileURL
        return openLocal(url)
    }

    @MainActor
    static func openLocal(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if QuireDocumentController.markdownExtensions.contains(url.pathExtension.lowercased()) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
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
