import AppKit
import QuireCore
import QuireRender

/// 文档窗口：侧栏（目录）| 编辑器 | 阅读视图，三态（阅读 / 编辑 / 分栏），滚动同步。
@MainActor
final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    enum Mode: Int { case reader = 0, editor = 1, split = 2 }

    let readerViewController: ReaderViewController
    /// 编辑器按需创建（阅读模式启动时不构建，省启动时间）
    private(set) lazy var editorViewController: EditorViewController = makeEditor()
    let sidebarViewController: SidebarViewController
    private var fileURLObserver: NSKeyValueObservation?
    private let splitViewController = NSSplitViewController()
    private var editorItem: NSSplitViewItem?
    private var readerItem: NSSplitViewItem!
    private let session: DocumentSession
    private var modeControl: NSSegmentedControl?
    private var isSyncingScroll = false

    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

    private(set) var mode: Mode = .reader {
        didSet { applyMode(); UserDefaults.standard.set(mode.rawValue, forKey: "view.mode") }
    }

    init(document: MarkdownDocument) {
        session = document.session
        readerViewController = ReaderViewController(session: document.session)
        sidebarViewController = SidebarViewController()
        LaunchClock.mark("  wc: view controllers")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 320)
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        super.init(window: window)
        LaunchClock.mark("  wc: window")
        // 注意：不要在这里 self.document = document —— NSDocument.addWindowController 会因"已关联"而跳过登记
        window.delegate = self

        // 侧栏 + 编辑器 + 阅读
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 420
        sidebar.canCollapse = true
        sidebar.isCollapsed = UserDefaults.standard.bool(forKey: "sidebar.collapsed")
        readerItem = NSSplitViewItem(viewController: readerViewController)
        readerItem.minimumThickness = 280
        readerItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebar)
        splitViewController.addSplitViewItem(readerItem)
        splitViewController.splitView.autosaveName = "QuireSplit3"
        splitViewController.splitView.dividerStyle = .thin
        window.contentViewController = splitViewController   // 注意：这会按子视图初始 frame 改窗口大小
        // 恢复上次窗口位置/大小；没有则用默认尺寸并居中
        if !window.setFrameUsingName("QuireDocumentWindow") {
            window.setContentSize(NSSize(width: 1240, height: 800))
            window.center()
        }
        window.setFrameAutosaveName("QuireDocumentWindow")
        LaunchClock.mark("  wc: split view")

        // 工具栏
        let toolbar = NSToolbar(identifier: "QuireToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        LaunchClock.mark("  wc: toolbar")

        // 侧栏：标题 → 跳转（阅读视图 + 编辑器）；文件 → 打开
        sidebarViewController.onSelectHeading = { [weak self] entry in
            guard let self else { return }
            self.readerViewController.scroll(toBlock: entry.blockIndex)
            if self.mode != .reader, let line = entry.line { self.editorViewController.scroll(toLine: line) }
        }
        sidebarViewController.onOpenFile = { url, line in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, _ in
                guard let line, let wc = doc?.windowControllers.first as? DocumentWindowController else { return }
                // 打开后跳到指定行（大纲里点的是其他文件的标题）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { wc.jump(toLine: line) }
            }
        }
        // 阅读视图滚动 → 侧栏高亮 + 编辑器同步
        readerViewController.onTopBlockChanged = { [weak self] index in
            self?.syncEditorToReader(blockIndex: index)
        }
        readerViewController.onSectionChanged = { [weak self] index in
            self?.sidebarViewController.highlight(blockIndex: index)
        }
        document.session.onOutline = { [weak self] outline in
            self?.sidebarViewController.outline = outline
        }
        sidebarViewController.currentURL = document.fileURL
        if !document.session.parsed.blocks.isEmpty { sidebarViewController.outline = document.session.parsed.outline }
        // 存储为 / 首次存储后 URL 变化 → 侧栏跟随
        fileURLObserver = document.observe(\.fileURL, options: [.new]) { [weak self] doc, _ in
            Task { @MainActor [weak self] in
                self?.sidebarViewController.currentURL = doc.fileURL
                if self?.editorItem != nil { self?.editorViewController.documentURLDidChange(doc.fileURL) }
            }
        }

        // 初始模式：新文档 → 分栏；已有文档 → 上次选择（默认阅读）
        let saved = Mode(rawValue: UserDefaults.standard.integer(forKey: "view.mode")) ?? .reader
        mode = document.isNewDocument ? .split : saved
        applyMode()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        LaunchClock.mark("showWindow")
        super.showWindow(sender)
        LaunchClock.mark("window shown")
        markdownDocument?.session.startWatching()
        if mode != .reader { window?.makeFirstResponder(editorViewController.textView) }
    }

    private func makeEditor() -> EditorViewController {
        let vc = EditorViewController(session: session)
        vc.onScroll = { [weak self] line in self?.syncReaderToEditor(line: line) }
        return vc
    }

    /// 首次进入编辑/分栏时把编辑器插入 split view（sidebar 之后、reader 之前）
    private func ensureEditorPane() {
        guard editorItem == nil else { return }
        let item = NSSplitViewItem(viewController: editorViewController)
        item.minimumThickness = 280
        item.canCollapse = true
        item.isCollapsed = true
        splitViewController.insertSplitViewItem(item, at: 1)
        editorItem = item
        // 编辑器可能晚于文档打开创建：同步当前源码
        if let doc = markdownDocument { editorViewController.replaceSource(doc.source) }
    }

    func windowWillClose(_ notification: Notification) {
        markdownDocument?.session.stopWatching()
    }

    /// 让 NSTextView 的撤销走文档的 UndoManager（自动标脏 / ⌘Z 与文档一致）
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager
    }

    /// 跳到源码行（阅读视图按块、编辑器按行）
    func jump(toLine line: Int) {
        if let rendered = readerViewController.textView.rendered, let idx = rendered.blockIndex(forLine: line) {
            readerViewController.scroll(toBlock: idx)
        }
        if mode != .reader { editorViewController.scroll(toLine: line) }
    }

    /// 文档从磁盘（重新）读入：同步编辑器文本
    func documentDidReload(_ source: String) {
        guard editorItem != nil, editorViewController.isViewLoaded else { return }
        editorViewController.replaceSource(source)
    }

    // MARK: - 模式

    private func applyMode() {
        guard readerItem != nil else { return }
        if mode != .reader { ensureEditorPane() }
        if window?.isVisible == true {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                editorItem?.animator().isCollapsed = (mode == .reader)
                readerItem.animator().isCollapsed = (mode == .editor)
            }
        } else {
            // 启动路径：不动画（runAnimationGroup 在初始化阶段要 40 ms）
            editorItem?.isCollapsed = (mode == .reader)
            readerItem.isCollapsed = (mode == .editor)
        }
        modeControl?.selectedSegment = mode.rawValue
        if mode != .reader, let w = window, w.isVisible { w.makeFirstResponder(editorViewController.textView) }
    }

    @objc func setModeReader(_ sender: Any?) { mode = .reader }
    @objc func setModeEditor(_ sender: Any?) { mode = .editor }
    @objc func setModeSplit(_ sender: Any?) { mode = .split }
    @objc private func modeChanged(_ sender: NSSegmentedControl) { mode = Mode(rawValue: sender.selectedSegment) ?? .reader }

    // MARK: - 滚动同步

    private func syncReaderToEditor(line: Int) {
        guard mode == .split, !isSyncingScroll else { return }
        guard let rendered = readerViewController.textView.rendered, let idx = rendered.blockIndex(forLine: line) else { return }
        isSyncingScroll = true
        readerViewController.textView.scroll(toBlock: idx, animated: false)
        DispatchQueue.main.async { self.isSyncingScroll = false }
    }

    private func syncEditorToReader(blockIndex: Int) {
        guard mode == .split, !isSyncingScroll else { return }
        guard let rendered = readerViewController.textView.rendered, blockIndex < rendered.blocks.count,
              let line = rendered.blocks[blockIndex].block.sourceRange?.start.line else { return }
        // 只有阅读视图是第一响应者（用户在滚它）时才反向同步，避免编辑输入引起的抖动
        guard window?.firstResponder === readerViewController.textView else { return }
        isSyncingScroll = true
        editorViewController.scroll(toLine: line)
        DispatchQueue.main.async { self.isSyncingScroll = false }
    }

    // MARK: - 动作

    @objc func toggleSidebar(_ sender: Any?) {
        splitViewController.toggleSidebar(sender)
        UserDefaults.standard.set(splitViewController.splitViewItems.first?.isCollapsed ?? false, forKey: "sidebar.collapsed")
    }

    @objc func chooseSidebarFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("选择")
        panel.directoryURL = sidebarViewController.rootURL ?? markdownDocument?.fileURL?.deletingLastPathComponent()
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.sidebarViewController.setRoot(url)
            if self?.splitViewController.splitViewItems.first?.isCollapsed == true { self?.toggleSidebar(nil) }
        }
    }

    @objc func revealInSidebar(_ sender: Any?) {
        if splitViewController.splitViewItems.first?.isCollapsed == true { toggleSidebar(nil) }
        sidebarViewController.revealCurrent()
    }

    @objc func showThemeMenu(_ sender: Any?) {
        guard let button = sender as? NSView else { return }
        let menu = MainMenu.buildThemeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: - NSToolbarDelegate

    private enum Item {
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        static let mode = NSToolbarItem.Identifier("mode")
        static let theme = NSToolbarItem.Identifier("theme")
        static let appearance = NSToolbarItem.Identifier("appearance")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.sidebar, .sidebarTrackingSeparator, .flexibleSpace, Item.mode, .flexibleSpace, Item.appearance, Item.theme]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Item.sidebar:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L("目录"); item.toolTip = L("显示/隐藏目录（⌘⌥S）")
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: L("目录"))
            item.target = self; item.action = #selector(toggleSidebar(_:))
            item.isNavigational = true
            return item
        case Item.mode:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L("视图")
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: L("阅读"))!,
                NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: L("编辑"))!,
                NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: L("分栏"))!,
            ], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
            control.setToolTip(L("阅读（⌘1）"), forSegment: 0)
            control.setToolTip(L("编辑（⌘2）"), forSegment: 1)
            control.setToolTip(L("分栏（⌘3）"), forSegment: 2)
            control.selectedSegment = mode.rawValue
            control.segmentStyle = .automatic
            item.view = control
            modeControl = control
            return item
        case Item.theme:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L("主题"); item.toolTip = L("选择主题")
            item.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: L("主题"))
            item.target = self; item.action = #selector(showThemeMenu(_:))
            return item
        case Item.appearance:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L("外观"); item.toolTip = L("切换亮 / 暗")
            item.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: L("外观"))
            item.target = MainMenu.Handler.shared; item.action = #selector(MainMenu.Handler.toggleAppearance(_:))
            return item
        default: return nil
        }
    }
}
