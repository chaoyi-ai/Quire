import AppKit
import QuireCore
import QuireRender

/// 源码编辑器控制器：NSScrollView + EditorTextView + 行号栏；文本变化 → 文档 + 会话（去抖增量渲染）。
@MainActor
final class EditorViewController: NSViewController {
    let session: DocumentSession
    private(set) var textView: EditorTextView!
    private(set) var scrollView: NSScrollView!
    private var ruler: LineNumberRulerView!
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var prefsObserver: NSObjectProtocol?
    /// 编辑器滚动回调（顶部行号）
    var onScroll: ((Int) -> Void)?
    /// 文本变化（由控制器已经转发给 session 后再调用）
    var onEdit: (() -> Void)?

    init(session: DocumentSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let style = session.style
        textView = EditorTextView(style: style)
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
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
        ruler = LineNumberRulerView(editor: textView, scrollView: scrollView)
        ruler.style = style
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = Preferences.shared.editorLineNumbers
        textView.hangingMarkers = Preferences.shared.editorHangingMarkers
        let container = NSView(frame: scrollView.frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        prefsObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scrollView.rulersVisible = Preferences.shared.editorLineNumbers
                self?.textView.hangingMarkers = Preferences.shared.editorHangingMarkers
            }
        }

        textView.documentURL = session.document?.fileURL
        textView.onDropFiles = { urls in FileOpener.open(urls) }
        textView.onTextChange = { [weak self] in
            guard let self else { return }
            let src = self.textView.source
            self.session.document?.setSourceFromEditor(src)
            self.session.sourceDidChangeDebounced(src)
            self.onEdit?()
        }
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ruler.needsDisplay = true
                self.onScroll?(self.textView.topVisibleLine())
            }
        }
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = ThemeManager.shared.currentStyle
                self.textView.applyStyle(s)
                self.scrollView.backgroundColor = s.background
                self.ruler.style = s
            }
        }
        if let doc = session.document { textView.setSource(doc.source) }
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) }
    }

    /// 文档 URL 变化（存储为）
    func documentURLDidChange(_ url: URL?) { if isViewLoaded { textView.documentURL = url } }

    /// 外部（磁盘）变化：替换编辑器文本但保留光标（视图未加载时不用管：loadView 会从文档取源码）
    func replaceSource(_ text: String) {
        guard isViewLoaded, textView.source != text else { return }
        let sel = textView.selectedRange()
        textView.setSource(text)
        let len = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
    }

    func scroll(toLine line: Int) { if isViewLoaded { textView.scroll(toLine: line) } }
    var topVisibleLine: Int { isViewLoaded ? textView.topVisibleLine() : 1 }
}
