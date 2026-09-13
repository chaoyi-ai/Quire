import AppKit
import QuireCore
import QuireRender

/// 工作区窗口（docs/research/window-chrome.md §3）：一个窗口 = 一个工作区（侧栏根目录）；文档是正文列里的标签。
/// 结构：工具栏行（全宽铬色）／ 侧栏（工具栏行之下、全高）| 正文列（标签条 + 编辑器 | 阅读视图）。
/// 侧栏选中项 == 当前标签；单击侧栏文件开临时标签（斜体、下次单击替换），双击 / 编辑后固定。
/// 所有文档共用这一个 NSWindowController：`document` 随当前标签换挂（关闭询问、脏标记、标题都跟着当前标签走）。
@MainActor
final class WorkspaceWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    enum Mode: Int { case reader = 0, editor = 1, split = 2, hybrid = 3 }   // hybrid = 混合实时预览（实验，spike #85）

    /// 标签（顺序 = 标签条顺序）；工作区至少一个标签，最后一个关掉 = 关窗口
    private(set) var tabs: [DocumentTab] = []
    private(set) var current: DocumentTab!
    let sidebarViewController: SidebarViewController
    private let splitViewController = NSSplitViewController()
    private let themedSplitView = ThemedSplitView()
    /// 正文区：编辑器 + 阅读视图放在一个经典 NSSplitView 里（不用 NSSplitViewController：那套用约束握着窗格宽度，
    /// setPosition 不生效、给窗格加宽度约束会把窗口撑大，每种启动模式分出来的宽度都不一样）。折叠 = 隐藏子视图
    private let contentSplit = ThemedSplitView()
    private let contentColumn: ContentColumnView
    private var tabStrip: TabStripView { contentColumn.strip }
    private let paneHost = NSViewController()
    private var modeControl: NSSegmentedControl?
    private let wordCount = WordCountView(frame: .zero)
    nonisolated(unsafe) private var selectionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var prefsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var editedObserver: NSObjectProtocol?
    private var isSyncingScroll = false

    // 当前标签的快捷访问（旧代码都按"一个窗口一份文档"写，这几个名字保住它们）
    var markdownDocument: MarkdownDocument? { current?.document }
    var session: DocumentSession { current.session }
    var readerViewController: ReaderViewController { current.reader }
    /// 当前标签的编辑器（按需创建；是否已插进分栏看 `hasEditorPane`）
    var editorViewController: EditorViewController { ensureEditor(current) }
    private var editorAdded: Bool { current.editorAdded }
    var rootURL: URL? { sidebarViewController.rootURL }

    var mode: Mode {
        get { current?.mode ?? (Mode(rawValue: UserDefaults.standard.integer(forKey: "view.mode")) ?? .reader) }   // 工具栏在第一个标签之前就建
        set { let old = current.mode; current.mode = newValue; applyMode(from: old); UserDefaults.standard.set(newValue.rawValue, forKey: "view.mode") }
    }

    /// 所有工作区窗口（前后顺序）
    static var all: [WorkspaceWindowController] {
        NSApp.orderedWindows.compactMap { $0.windowController as? WorkspaceWindowController }
    }
    /// 当前（key / main）工作区
    static var key: WorkspaceWindowController? {
        (NSApp.keyWindow?.windowController as? WorkspaceWindowController) ?? (NSApp.mainWindow?.windowController as? WorkspaceWindowController) ?? all.first
    }

    init(document: MarkdownDocument, root: URL?, ephemeral: Bool = false) {
        sidebarViewController = SidebarViewController()
        contentColumn = ContentColumnView(split: contentSplit)
        LaunchClock.mark("  wc: view controllers")

        // 不用 fullSizeContentView：内容视图从工具栏行之下开始，侧栏自然从工具栏行之下开始（规则 3）；
        // 标题栏透明，透出的是 window.backgroundColor —— 设成铬色，工具栏行就是铬色，不用再垫一块
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 320)
        window.tabbingMode = .disallowed   // 标签页是自己的（正文列里的标签条），不用系统标签组
        window.isReleasedWhenClosed = false
        window.isRestorable = false        // 状态恢复按工作区自己做（WorkspaceState），不让系统按文档一份一窗地恢复
        window.titleVisibility = .hidden   // 标题就是选中的标签
        super.init(window: window)
        LaunchClock.mark("  wc: window")
        window.delegate = self

        // 侧栏 | 正文列。侧栏是普通 split item（不是 sidebarWithViewController:）：macOS 26 给 .sidebar 行为的项套一层"浮板"——
        // 向内缩 8 pt、圆角、玻璃描边、投影；我们自己按主题铺色，浮板的每一层都成了要对齐的缝（ADR-17）
        themedSplitView.isVertical = true   // 自己给的 split view 控制器不再替我们配置：方向、分隔线样式都要自己设
        themedSplitView.dividerStyle = .thin
        splitViewController.splitView = themedSplitView   // 要在 splitView 被读到之前换成自己的子类（分隔线颜色跟主题）
        let sidebar = NSSplitViewItem(viewController: sidebarViewController)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 420
        sidebar.holdingPriority = NSLayoutConstraint.Priority(300)   // 窗口 / 窗格宽度变化都落在正文窗格上，侧栏保持自己的宽度
        sidebar.canCollapse = true
        sidebar.isCollapsed = UserDefaults.standard.bool(forKey: "sidebar.collapsed")
        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.delegate = self
        paneHost.view = contentColumn
        let contentItem = NSSplitViewItem(viewController: paneHost)
        contentItem.minimumThickness = 280
        splitViewController.addSplitViewItem(sidebar)
        splitViewController.addSplitViewItem(contentItem)
        // 不用 NSSplitView 的 autosave：它会把某个模式下（有窗格折叠着）的三栏宽度原样复原到别的模式，每次启动都不一样；
        // 侧栏宽度自己记（sidebar.width），双栏在 showWindow / 切模式时按等宽分
        window.contentViewController = splitViewController   // 注意：这会按子视图初始 frame 改窗口大小
        if !window.setFrameUsingName("QuireDocumentWindow") {
            window.setContentSize(NSSize(width: 1240, height: 800))
            window.center()
        }
        window.setFrameAutosaveName("QuireDocumentWindow")
        LaunchClock.mark("  wc: split view")

        // 工具栏：左段（侧栏钮）与侧栏同宽——NSTrackingSeparatorToolbarItem 跟着外层分栏的分隔线走（规则 1）
        let toolbar = NSToolbar(identifier: "QuireToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        applyWindowBackground()
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyWindowBackground() }
        }
        LaunchClock.mark("  wc: toolbar")

        // 标签条
        tabStrip.onSelect = { [weak self] i in if let t = self?.tabs[safe: i] { self?.select(t) } }
        tabStrip.onClose = { [weak self] i in if let t = self?.tabs[safe: i] { self?.closeTab(t) } }
        tabStrip.onPin = { [weak self] i in if let t = self?.tabs[safe: i] { self?.pin(t) } }
        tabStrip.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabStrip.onNew = { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
            NSDocumentController.shared.newDocument(nil)
        }
        editedObserver = NotificationCenter.default.addObserver(forName: MarkdownDocument.editedStateDidChange, object: nil, queue: .main) { [weak self] n in
            nonisolated(unsafe) let obj = n.object
            MainActor.assumeIsolated {
                guard let self, let doc = obj as? MarkdownDocument, let tab = self.tab(for: doc) else { return }
                if doc.isDocumentEdited, tab.isEphemeral { tab.isEphemeral = false }   // 改过的标签不再是临时的
                if tab === self.current { self.window?.isDocumentEdited = doc.isDocumentEdited }
                self.refreshStrip()
            }
        }

        // 侧栏：标题 → 跳转（阅读视图 + 编辑器）；文件 → 作为标签打开
        sidebarViewController.onSelectHeading = { [weak self] entry in
            guard let self else { return }
            self.readerViewController.scroll(toBlock: entry.blockIndex)
            if self.mode != .reader, let line = entry.line {
                // 编辑器滚动会经 onScroll 反过来同步阅读视图（非动画），和上面的动画滚动打架：这一下不同步
                self.isSyncingScroll = true
                self.editorViewController.scroll(toLine: line)
                DispatchQueue.main.async { [weak self] in self?.isSyncingScroll = false }
            }
        }
        sidebarViewController.onOpenFile = { [weak self] url, line, pinned in
            guard let self else { return }
            NavigationHistory.shared.push(current: self.markdownDocument?.fileURL, to: url)
            self.open(url, ephemeral: !pinned, line: line)
        }
        selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] n in
            nonisolated(unsafe) let obj = n.object
            MainActor.assumeIsolated {
                guard let self, let tv = obj as? NSTextView, tv.window === self.window, let cur = self.current else { return }
                // 只认正文的两个视图：侧栏筛选框、⌘P 面板的字段编辑器也是同一窗口里的 NSTextView，在里面选字不该变成"已选 N 字"
                let isReader = tv === cur.reader.textView
                let isEditor = cur.hasEditorPane && tv === cur.editor?.textView
                guard isReader || isEditor else { return }
                let r = tv.selectedRange()
                if cur.mode == .editor, isEditor { self.followCaretInSidebar(location: r.location) }
                guard r.length > 0, let s = tv.textStorage?.string as NSString? else { self.wordCount.update(selection: nil); return }
                self.wordCount.update(selection: TextStats.compute(s.substring(with: r)))
            }
        }
        prefsObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isImmersive { self.wordCount.isHidden = !Preferences.shared.showWordCount }
                if self.window?.isVisible == true { self.session.startWatching() }   // 自动重新载入 开 / 关
            }
        }
        wordCount.isHidden = !Preferences.shared.showWordCount

        if let root { sidebarViewController.setRoot(root) }
        addTab(document, ephemeral: ephemeral)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        for o in [themeObserver, prefsObserver, selectionObserver, sidebarResizeObserver, editedObserver] { if let o { NotificationCenter.default.removeObserver(o) } }
    }

    override func showWindow(_ sender: Any?) {
        LaunchClock.mark("showWindow")
        let firstShow = window?.isVisible == false
        super.showWindow(sender)
        LaunchClock.mark("window shown")
        current.session.startWatching()
        guard firstShow else { return }
        focusContent()
        restoreSidebarWidth()
        // 启动那几百毫秒里窗口还在布局（inset 到位）：这期间不做滚动同步，也等它们完了再把双栏分成等宽
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.readyForScrollSync = true
            if self.mode == .split { self.equalizePanes() }
        }
    }

    private func focusContent() {
        guard let window, let cur = current else { return }
        // 焦点给正文，不给侧栏筛选框（否则一打开光标就在筛选框里、方向键滚不了文档）
        if (cur.mode == .editor || cur.mode == .split), cur.hasEditorPane, let tv = cur.editor?.textView { window.makeFirstResponder(tv) }
        else { window.makeFirstResponder(cur.reader.textView) }
    }

    // MARK: - 标签

    func tab(for doc: MarkdownDocument) -> DocumentTab? { tabs.first { $0.document === doc } }
    /// 文件是否属于这个工作区（在根目录下；没有根 = 只有未命名文档的空工作区，什么都收）
    func contains(_ url: URL) -> Bool {
        guard let root = rootURL else { return true }
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    /// 把文档加为标签（默认插在当前标签之后并选中）。临时标签会替换掉已有的、没改过的临时标签
    @discardableResult
    func addTab(_ doc: MarkdownDocument, ephemeral: Bool, select: Bool = true) -> DocumentTab {
        if let existing = tab(for: doc) { if select { self.select(existing) }; return existing }
        let saved = Mode(rawValue: UserDefaults.standard.integer(forKey: "view.mode")) ?? .reader
        let tab = DocumentTab(document: doc, mode: doc.isNewDocument ? .split : saved, ephemeral: ephemeral)
        doc.workspace = self
        wire(tab)
        var index = current.flatMap { c in tabs.firstIndex { $0 === c } }.map { $0 + 1 } ?? tabs.count
        var replacing: DocumentTab?
        if ephemeral, let old = tabs.first(where: { $0.isEphemeral && !$0.document.isDocumentEdited }), let i = tabs.firstIndex(where: { $0 === old }) {
            replacing = old; index = i
        }
        tabs.insert(tab, at: min(index, tabs.count))
        if select || current == nil { self.select(tab) }
        if let replacing { detach(replacing); replacing.document.close() }
        refreshStrip()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak tab] in if let tab, self?.current === tab { self?.noteAuthorshipMismatchIfNeeded() } }
        return tab
    }

    /// 切到某个标签：换挂 document、换正文列的窗格、侧栏选中、标题 / 脏标记
    func select(_ tab: DocumentTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        let old = current
        if old === tab { return }
        if let old, old !== tab { old.document.removeWindowController(self) }
        current = tab
        if document !== tab.document { tab.document.addWindowController(self) }
        window?.isDocumentEdited = tab.document.isDocumentEdited
        mountPanes(tab)
        sidebarViewController.currentURL = tab.document.fileURL
        sidebarViewController.outline = tab.session.parsed.outline
        wordCount.tracker = tab.readingTracker
        wordCount.update(stats: tab.session.stats)
        wordCount.update(selection: nil)
        refreshChapterProgress()
        refreshStrip()
        if window?.isVisible == true {
            tab.session.startWatching()
            focusContent()
        }
        if let old, old !== tab { old.session.stopWatching() }
    }

    /// 固定临时标签（双击）
    func pin(_ tab: DocumentTab) { tab.isEphemeral = false; refreshStrip() }

    /// 设置某个标签的模式（恢复用）：不是当前标签就只记下，切过去时再装配
    func setMode(_ m: Mode, of tab: DocumentTab) {
        if tab === current { mode = m } else { tab.mode = m }
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let t = tabs.remove(at: from); tabs.insert(t, at: to)
        refreshStrip()
    }

    /// 在这个工作区里打开文件：已开着就切过去（固定则取消临时）；否则作为标签打开。文件不在根内 → 交给文档控制器另开窗口
    func open(_ url: URL, ephemeral: Bool, line: Int? = nil) {
        let dc = QuireDocumentController.shared as! QuireDocumentController
        let target = contains(url) ? self : nil
        dc.open(url, in: target, ephemeral: ephemeral) { doc in
            guard let doc, let ws = doc.workspace else { return }
            if !ephemeral, let t = ws.tab(for: doc) { ws.pin(t) }
            // 打开后跳到指定行（大纲里点的是其他文件的标题）：等首次渲染到位，而不是猜一个 0.2 s
            if let line { doc.session.whenRendered { ok in if ok { ws.jump(doc, toLine: line) } } }
        }
    }

    /// 关闭标签：有未存储改动先问；最后一个标签 = 关窗口
    func closeTab(_ tab: DocumentTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if tabs.count == 1 { window?.performClose(nil); return }
        select(tab)
        askThenClose([tab]) { _ in }
    }
    @objc func closeCurrentTab(_ sender: Any?) { if let cur = current { closeTab(cur) } }

    /// 逐个询问未存储的文档（切到那个标签让 sheet 挂对窗口），都同意才 done(true)。除最后一个外，同意的顺手关掉
    private var docCloseCallback: ((Bool) -> Void)?
    private func askThenClose(_ remaining: [DocumentTab], keepLast: Bool = false, done: @escaping (Bool) -> Void) {
        guard let tab = remaining.first else { done(true); return }
        guard tabs.contains(where: { $0 === tab }) else { askThenClose(Array(remaining.dropFirst()), keepLast: keepLast, done: done); return }
        select(tab)
        docCloseCallback = { [weak self] ok in
            guard let self else { return }
            guard ok else { done(false); return }
            if !(keepLast && self.tabs.count == 1) { tab.document.close() }
            self.askThenClose(Array(remaining.dropFirst()), keepLast: keepLast, done: done)
        }
        tab.document.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }
    @objc private func document(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let cb = docCloseCallback; docCloseCallback = nil
        cb?(shouldClose)
    }

    /// 文档要关了（MarkdownDocument.close）：把它的标签摘掉。最后一个标签不摘——窗口跟着文档一起关（NSDocument 的默认路径）
    func documentWillClose(_ doc: MarkdownDocument) {
        guard let tab = tab(for: doc) else { return }
        if tabs.count == 1 { doc.workspace = nil; return }
        detach(tab)
    }

    /// 把标签从工作区摘掉但不关文档（移到别的窗口 / 关闭前）：选中相邻的
    func detach(_ tab: DocumentTab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: i)
        tab.fileURLObserver = nil
        tab.document.workspace = nil
        if current === tab {
            current = nil
            if let next = tabs[safe: min(i, tabs.count - 1)] { select(next) }
            else { unmountPanes(tab); tab.document.removeWindowController(self) }
        } else {
            tab.document.removeWindowController(self)
        }
        tab.session.stopWatching()
        refreshStrip()
    }

    private func refreshStrip() {
        tabStrip.items = tabs.map { .init(title: $0.title, edited: $0.document.isDocumentEdited, ephemeral: $0.isEphemeral, selected: $0 === current) }
    }

    // MARK: - 标签页（窗口菜单）
    @objc func selectNextTab(_ sender: Any?) { cycleTab(1) }
    @objc func selectPreviousTab(_ sender: Any?) { cycleTab(-1) }
    private func cycleTab(_ offset: Int) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0 === current }) else { return }
        select(tabs[(i + offset + tabs.count) % tabs.count])
    }
    /// 「移到新窗口」：当前标签拆出去，新窗口同一个根目录，错开一点显示
    @objc func moveTabToNewWindow(_ sender: Any?) {
        guard tabs.count > 1, let tab = current, let window else { return }
        detach(tab)
        let ws = WorkspaceWindowController(document: tab.document, root: rootURL, ephemeral: false)
        var f = window.frame; f.origin.x += 40; f.origin.y -= 40
        ws.window?.setFrame(f, display: false)
        ws.showWindow(nil)
    }
    /// 「合并所有窗口」：别的工作区的标签全并进这个窗口（根目录保持本窗口的）
    @objc func mergeAllWindows(_ sender: Any?) {
        for other in Self.all where other !== self {
            for t in other.tabs { other.detach(t); addTab(t.document, ephemeral: false, select: false) }
            other.closeApproved = true
            other.window?.close()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 窗格装配

    private func ensureEditor(_ tab: DocumentTab) -> EditorViewController {
        if let e = tab.editor { return e }
        let vc = EditorViewController(session: tab.session)
        vc.onScroll = { [weak self, weak tab] line in if let self, let tab, tab === self.current { self.syncReaderToEditor(line: line) } }
        tab.editor = vc
        return vc
    }

    /// 每个标签的回调都先看"还是不是当前标签"：后台标签的解析结果不该改侧栏
    private func wire(_ tab: DocumentTab) {
        let doc = tab.document
        tab.session.transclusionRoot = { [weak self] in self?.rootURL }
        tab.reader.onTopBlockChanged = { [weak self, weak tab] index in
            guard let self, let tab, tab === self.current else { return }
            self.syncEditorToReader(blockIndex: index)
            self.wordCount.update(chapter: tab.readingTracker.topBlockChanged(index))
        }
        tab.reader.onSectionChanged = { [weak self, weak tab] index in
            guard let self, let tab, tab === self.current else { return }
            self.sidebarViewController.highlight(blockIndex: index)
        }
        tab.session.onOutline = { [weak self, weak tab] outline in
            guard let self, let tab, tab === self.current else { return }
            self.sidebarViewController.outline = outline
            self.refreshChapterProgress()
        }
        tab.session.onStats = { [weak self, weak tab] st in if let self, let tab, tab === self.current { self.wordCount.update(stats: st) } }
        // 存储为 / 首次存储后 URL 变化 → 侧栏跟随、标签标题
        tab.fileURLObserver = doc.observe(\.fileURL, options: [.new]) { [weak self, weak tab] doc, _ in
            Task { @MainActor [weak self, weak tab] in
                guard let self, let tab else { return }
                if tab === self.current { self.sidebarViewController.currentURL = doc.fileURL }
                tab.editor?.documentURLDidChange(doc.fileURL)
                // 未命名文档首次存储 / 存储为：监视新路径、相对图片按新目录解析
                tab.reader.textView.baseURL = doc.fileURL
                if tab === self.current, self.window?.isVisible == true { tab.session.startWatching() }
                self.refreshStrip()
            }
        }
    }

    /// 把标签的窗格换进正文分栏
    private func mountPanes(_ tab: DocumentTab) {
        for child in paneHost.children { child.removeFromParent() }
        for v in contentSplit.arrangedSubviews { contentSplit.removeArrangedSubview(v); v.removeFromSuperview() }
        let h = max(100, contentSplit.bounds.height)
        if tab.editorAdded, let editor = tab.editor {
            paneHost.addChild(editor)
            editor.view.frame = NSRect(x: 0, y: 0, width: max(280, (contentSplit.bounds.width / 2).rounded()), height: h)
            editor.view.autoresizingMask = [.width, .height]
            contentSplit.addArrangedSubview(editor.view)
        }
        paneHost.addChild(tab.reader)
        tab.reader.view.frame = NSRect(x: 0, y: 0, width: max(280, contentSplit.bounds.width), height: h)
        tab.reader.view.autoresizingMask = [.width, .height]
        contentSplit.addArrangedSubview(tab.reader.view)
        contentSplit.adjustSubviews()
        applyMode(from: nil)   // 只切窗格，不动窗口宽度
    }
    private func unmountPanes(_ tab: DocumentTab) {
        for child in paneHost.children { child.removeFromParent() }
        for v in contentSplit.arrangedSubviews { contentSplit.removeArrangedSubview(v); v.removeFromSuperview() }
    }

    /// 首次进入编辑/分栏时把编辑器插入 split view（reader 之前）
    private func ensureEditorPane() {
        guard let tab = current, !tab.editorAdded else { return }
        tab.editorAdded = true
        let editor = ensureEditor(tab)
        editor.loadViewIfNeeded()   // 隐藏着插入不会触发 loadView；后面要直接碰 textView / scrollView
        paneHost.addChild(editor)
        let half = max(280, (contentSplit.bounds.width / 2).rounded())
        editor.view.frame = NSRect(x: 0, y: 0, width: half, height: max(100, contentSplit.bounds.height))
        editor.view.autoresizingMask = [.width, .height]
        editor.view.isHidden = !(tab.mode == .editor || tab.mode == .split)
        contentSplit.insertArrangedSubview(editor.view, at: 0)
        contentSplit.adjustSubviews()
        // 编辑器可能晚于文档打开创建：同步当前源码
        editor.replaceSource(tab.document.source)
        editor.textView.focusMode = focusMode
        editor.textView.posMode = posMode
        if styleCheckOn { editor.textView.styleChecker = StyleRulesStore.checker() }
    }

    // MARK: - 窗口

    /// 关窗口：逐个问过所有未存储的标签，都同意才关（NSWindowController 默认只问自己挂着的那一份）
    private var closeApproved = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved || tabs.isEmpty { return true }
        askThenClose(tabs, keepLast: true) { [weak self] ok in
            guard ok, let self else { return }
            self.closeApproved = true
            self.window?.close()
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        for t in tabs { t.session.stopWatching() }
    }

    /// 窗口底色 = 铬色（透明标题栏透出来的就是它，工具栏行因此是铬色）；分隔线跟主题 border
    private func applyWindowBackground() {
        let bg = ThemeManager.shared.currentStyle.background
        window?.backgroundColor = ChromeColors.elevated(bg)
        themedSplitView.dividerTint = ThemeManager.shared.currentStyle.border
        themedSplitView.needsDisplay = true
        contentSplit.dividerTint = ThemeManager.shared.currentStyle.border
        contentSplit.needsDisplay = true
        tabStrip.needsDisplay = true
    }

    /// 侧栏折叠 / 展开（普通 split item 不能用 NSSplitViewController.toggleSidebar，那只认 .sidebar 行为的项）
    var isSidebarCollapsed: Bool { splitViewController.splitViewItems.first?.isCollapsed ?? false }
    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard let item = splitViewController.splitViewItems.first, item.isCollapsed != collapsed else { return }
        if animated, window?.isVisible == true { item.animator().isCollapsed = collapsed } else { item.isCollapsed = collapsed }
        if !collapsed { DispatchQueue.main.async { [weak self] in self?.restoreSidebarWidth() } }
    }

    // MARK: - 侧栏宽度（自己记：NSSplitView 的 autosave 在窗格折叠 / 展开时会把侧栏一起重新分配，每种启动模式宽度都不一样）
    private static let sidebarWidthKey = "sidebar.width"
    nonisolated(unsafe) private var sidebarResizeObserver: NSObjectProtocol?
    private func restoreSidebarWidth() {
        guard let sidebar = splitViewController.splitViewItems.first, !sidebar.isCollapsed else { return }
        let w = CGFloat(UserDefaults.standard.double(forKey: Self.sidebarWidthKey))
        let target = w > 0 ? min(max(w, sidebar.minimumThickness), sidebar.maximumThickness) : 240
        window?.layoutIfNeeded()
        if abs(sidebar.viewController.view.frame.width - target) > 0.5 { splitViewController.splitView.setPosition(target, ofDividerAt: 0) }
        if sidebarResizeObserver == nil {
            sidebarResizeObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: splitViewController.splitView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let sb = self.splitViewController.splitViewItems.first, !sb.isCollapsed, self.window?.inLiveResize == false else { return }
                    let cur = sb.viewController.view.frame.width
                    if cur >= sb.minimumThickness { UserDefaults.standard.set(Double(cur), forKey: Self.sidebarWidthKey) }
                }
            }
        }
    }

    /// 编辑器面板已经建好（阅读 / 混合模式下没有：此时 `editorViewController.textView` 还是 nil，碰它就崩）
    var hasEditorPane: Bool { current?.hasEditorPane ?? false }
    /// 需要源码编辑器的动作：阅读 / 混合模式先切到编辑模式
    func ensureEditorMode() { if mode == .reader || mode == .hybrid { mode = .editor } }
    // MARK: - 专注 / 沉浸

    private(set) var focusMode: EditorFocusMode = EditorFocusMode(rawValue: UserDefaults.standard.integer(forKey: "editor.focus")) ?? .off {
        didSet {
            UserDefaults.standard.set(focusMode.rawValue, forKey: "editor.focus")
            if hasEditorPane { editorViewController.textView.focusMode = focusMode }
            updateModeIndicator()
        }
    }

    private(set) var posMode: POSMode = POSMode(rawValue: UserDefaults.standard.integer(forKey: "editor.pos")) ?? .off {
        didSet {
            UserDefaults.standard.set(posMode.rawValue, forKey: "editor.pos")
            if hasEditorPane { editorViewController.textView.posMode = posMode }
            updateModeIndicator()
        }
    }
    private(set) var styleCheckOn: Bool = UserDefaults.standard.bool(forKey: "editor.styleCheck") {
        didSet {
            UserDefaults.standard.set(styleCheckOn, forKey: "editor.styleCheck")
            if hasEditorPane { editorViewController.textView.styleChecker = styleCheckOn ? StyleRulesStore.checker() : nil }
            updateModeIndicator()
        }
    }
    /// 字数胶囊里的模式提示（只在编辑器可见时显示）
    private func updateModeIndicator() {
        var modes: [String] = []
        if mode != .reader && mode != .hybrid {
            switch focusMode {
            case .off: break
            case .sentence: modes.append(L("专注：句子"))
            case .paragraph: modes.append(L("专注：段落"))
            case .typewriter: modes.append(L("专注：打字机"))
            }
            if posMode != .off { modes.append(L("词性")) }
            if styleCheckOn { modes.append(L("文风")) }
        }
        wordCount.update(modes: modes)
    }

    @objc func toggleStyleCheck(_ sender: Any?) {
        ensureEditorMode()
        styleCheckOn.toggle()
    }

    @objc func setPOSMode(_ sender: NSMenuItem) {
        ensureEditorMode()
        posMode = POSMode(rawValue: sender.tag) ?? .off
    }

    @objc func setFocusMode(_ sender: NSMenuItem) {
        ensureEditorMode()
        focusMode = EditorFocusMode(rawValue: sender.tag) ?? .off
    }
    @objc func cycleFocusMode(_ sender: Any?) {
        ensureEditorMode()
        focusMode = focusMode.next
    }

    private struct ImmersiveSaved { var mode: Mode; var sidebarCollapsed: Bool; var toolbarVisible: Bool; var rulers: Bool; var wordCountHidden: Bool; var enteredFullScreen: Bool }
    private var immersiveSaved: ImmersiveSaved?
    var isImmersive: Bool { immersiveSaved != nil }

    /// 沉浸写作（⌘⇧D）：只剩正文列——全屏、隐藏工具栏 / 标签栏 / 侧栏 / 行号 / 字数，编辑器居中限宽；Esc 或再按一次退出
    @objc func toggleImmersive(_ sender: Any?) {
        if isImmersive { exitImmersive(restoreFullScreen: true) } else { enterImmersive() }
    }

    private func enterImmersive() {
        guard let window else { return }
        let sidebarCollapsed = splitViewController.splitViewItems.first?.isCollapsed ?? false
        let wasFull = window.styleMask.contains(.fullScreen)
        immersiveSaved = ImmersiveSaved(mode: mode, sidebarCollapsed: sidebarCollapsed, toolbarVisible: window.toolbar?.isVisible ?? true,
                                        rulers: editorAdded ? editorViewController.scrollView.rulersVisible : Preferences.shared.editorLineNumbers,
                                        wordCountHidden: wordCount.isHidden, enteredFullScreen: !wasFull)
        mode = .editor
        if !sidebarCollapsed { setSidebarCollapsed(true, animated: false) }
        window.toolbar?.isVisible = false
        contentColumn.stripHidden = true
        editorViewController.scrollView.rulersVisible = false
        wordCount.isHidden = true
        editorViewController.textView.immersiveWidth = session.style.maxContentWidth
        editorViewController.textView.onEscape = { [weak self] in self?.exitImmersive(restoreFullScreen: true) }
        if !wasFull { window.toggleFullScreen(nil) }
        window.makeFirstResponder(editorViewController.textView)
    }

    private func exitImmersive(restoreFullScreen: Bool) {
        guard let saved = immersiveSaved, let window else { return }
        immersiveSaved = nil
        suppressWidthAdjust = true
        defer { suppressWidthAdjust = false }
        editorViewController.textView.onEscape = nil
        editorViewController.textView.immersiveWidth = 0
        editorViewController.scrollView.rulersVisible = saved.rulers
        wordCount.isHidden = saved.wordCountHidden
        window.toolbar?.isVisible = saved.toolbarVisible
        contentColumn.stripHidden = false
        if !saved.sidebarCollapsed, isSidebarCollapsed { setSidebarCollapsed(false, animated: false) }
        mode = saved.mode
        if restoreFullScreen, saved.enteredFullScreen, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // 用户用系统方式退出全屏（Esc / 绿灯）：沉浸状态一并退出
        if isImmersive { exitImmersive(restoreFullScreen: false) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setFocusMode(_:)) { item.state = item.tag == focusMode.rawValue ? .on : .off }
        if item.action == #selector(setPOSMode(_:)) { item.state = item.tag == posMode.rawValue ? .on : .off }
        if item.action == #selector(toggleStyleCheck(_:)) { item.state = styleCheckOn ? .on : .off }
        if item.action == #selector(toggleAuthorship(_:)) { item.state = Preferences.shared.authorship ? .on : .off }
        if item.action == #selector(markSelectionAsAuthor(_:)) { return hasEditorPane && editorViewController.textView.selectedRange().length > 0 }
        if item.action == #selector(navigateBack(_:)) { return NavigationHistory.shared.canGoBack }
        if item.action == #selector(navigateForward(_:)) { return NavigationHistory.shared.canGoForward }
        if item.action == #selector(toggleImmersive(_:)) { item.title = isImmersive ? L("退出沉浸写作") : L("沉浸写作") }
        return true
    }

    /// 让 NSTextView 的撤销走文档的 UndoManager（自动标脏 / ⌘Z 与文档一致）
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager
    }

    /// 编辑模式：侧栏大纲跟随光标所在的块（阅读 / 双栏由阅读视图的章节回调驱动）
    private func followCaretInSidebar(location: Int) {
        let line = editorViewController.textView.lineNumber(at: location)
        let idx: Int?
        if let rendered = readerViewController.textView.rendered { idx = rendered.blockIndex(forLine: line) }
        else { idx = session.parsed.blocks.lastIndex { ($0.sourceRange?.start.line ?? Int.max) <= line } }
        guard let idx, idx != current.lastCaretBlock else { return }
        current.lastCaretBlock = idx
        sidebarViewController.highlight(blockIndex: idx)
    }

    /// 跳到源码行（阅读视图按块、编辑器按行）；文档不是当前标签就先切过去
    func jump(_ doc: MarkdownDocument, toLine line: Int) {
        guard let tab = tab(for: doc) else { return }
        if tab !== current { select(tab) }
        if let rendered = tab.reader.textView.rendered, let idx = rendered.blockIndex(forLine: line) {
            tab.reader.scroll(toBlock: idx)
        }
        if tab.mode != .reader, tab.hasEditorPane { tab.editor?.scroll(toLine: line) }
    }
    func jump(toLine line: Int) { if let cur = current { jump(cur.document, toLine: line) } }

    /// 文档从磁盘（重新）读入：同步它那个标签的编辑器文本
    func documentDidReload(_ doc: MarkdownDocument, _ source: String) {
        guard let tab = tab(for: doc) else { return }
        tab.hybridSplicer.reset()
        guard tab.hasEditorPane else { return }
        tab.editor?.replaceSource(source)
    }

    // MARK: - 模式

    /// 沉浸模式进出时恢复模式：不要顺带改窗口宽度
    private var suppressWidthAdjust = false
    /// 单栏时的窗口宽度（进双栏前记下，退出时恢复）
    private var singlePaneWindowWidth: CGFloat?

    /// 切换窗格并调整窗口宽度。设计：**双栏 = 两个正文窗格**，不是把当前宽度一分为二把正文挤窄。
    /// - 单栏 → 双栏：窗口加宽一个正文窗格（屏幕放不下就顶满并往左挪），两栏等宽
    /// - 双栏 → 单栏：回到进双栏前的宽度
    /// - 阅读 ↔ 编辑：等宽替换，窗口不动
    /// 窗格折叠用 `.preferResizingSiblingsWithFixedSplitView`（折叠本身不碰窗口），窗口宽度在**下一轮 run loop** 再改——
    /// 同一轮里改会撞上 AppKit 折叠时临时加的"分栏视图宽度固定"约束，内容视图会比窗口还宽。
    /// 全屏 / 沉浸模式下只切窗格不动窗口。
    private func switchPanes(from old: Mode, showEditor: Bool, window: NSWindow) {
        let canResize = !window.styleMask.contains(.fullScreen) && !isImmersive && !suppressWidthAdjust
        let wasSplit = old == .split, isSplit = mode == .split
        let divider = splitViewController.splitView.dividerThickness
        let sidebarItem = splitViewController.splitViewItems.first
        let sidebarW = (sidebarItem?.isCollapsed ?? true) ? 0 : (sidebarItem?.viewController.view.frame.width ?? 0)
        let paneW = (max(320, window.contentView!.frame.width - sidebarW - (wasSplit ? divider : 0)) / (wasSplit ? 2 : 1)).rounded()
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 10_000, height: 10_000)
        // 目标窗口宽度：单 → 双 加一个窗格；双 → 单 回到之前；单 ↔ 单 不变（AppKit 展开窗格时可能把窗口撑大，下面会纠回来）
        var targetWidth = window.frame.width
        if canResize, isSplit != wasSplit {
            if isSplit { singlePaneWindowWidth = window.frame.width; targetWidth = min(visible.width, window.frame.width + paneW + divider) }
            else { targetWidth = min(visible.width, singlePaneWindowWidth ?? max(520, window.frame.width - paneW - divider)); singlePaneWindowWidth = nil }
        }
        func apply(width: CGFloat) {
            var frame = window.frame
            frame.size.width = width
            if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
            if abs(frame.width - window.frame.width) > 0.5 || abs(frame.minX - window.frame.minX) > 0.5 { window.setFrame(frame, display: true) }
        }
        // 要变宽：先把窗口撑开（在任何折叠约束出现之前），再展开窗格，留下的窗格会缩回去给新窗格让位
        if canResize, targetWidth > window.frame.width { apply(width: targetWidth) }
        // 先展开要显示的（从留下的正文窗格里分空间，分栏视图宽度不变），再折叠要藏的（腾出的空间给刚展开的窗格，侧栏不吃）
        setPaneVisibility(showEditor: showEditor)
        guard canResize else { return }
        // 下一轮：AppKit 折叠时临时加的约束已经撤掉，把窗口宽度校正到目标值、双栏分到等宽
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            apply(width: targetWidth)
            if isSplit { self.equalizePanes() }
        }
    }

    /// 显示 / 隐藏正文窗格（隐藏 = NSSplitView 的折叠）；双栏时分成等宽
    private func setPaneVisibility(showEditor: Bool) {
        if let cur = current, cur.editorAdded { cur.editor?.view.isHidden = !showEditor }
        readerViewController.view.isHidden = (mode == .editor)
        contentSplit.adjustSubviews()
        if mode == .split { equalizePanes() }
        if ProcessInfo.processInfo.environment["QUIRE_DEBUG_PANES"] != nil, mode != .split {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                let f = self.contentSplit.arrangedSubviews.map { "\(Int($0.frame.width))\($0.isHidden ? "h" : "")" }
                FileHandle.standardError.write("PANES: sidebar=\(Int(self.sidebarViewController.view.frame.width)) content=\(f) window=\(Int(self.window?.frame.width ?? 0))\n".data(using: .utf8)!)
            }
        }
    }

    /// 双栏：编辑器与阅读视图等宽
    private func equalizePanes() {
        guard mode == .split, editorAdded else { return }
        let w = contentSplit.bounds.width
        guard w > 0 else { return }
        contentSplit.setPosition(((w - contentSplit.dividerThickness) / 2).rounded(), ofDividerAt: 0)
        if ProcessInfo.processInfo.environment["QUIRE_DEBUG_PANES"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                let f = self.contentSplit.arrangedSubviews.map { "\(Int($0.frame.width))\($0.isHidden ? "h" : "")" }
                FileHandle.standardError.write("PANES: sidebar=\(Int(self.sidebarViewController.view.frame.width)) content=\(f) window=\(Int(self.window?.frame.width ?? 0))\n".data(using: .utf8)!)
            }
        }
    }

    private func applyMode(from old: Mode? = nil) {
        let showEditor = mode == .editor || mode == .split
        if showEditor { ensureEditorPane() }
        if let window, window.isVisible, let old {
            switchPanes(from: old, showEditor: showEditor, window: window)
        } else {
            setPaneVisibility(showEditor: showEditor)   // 启动路径
        }
        modeControl?.selectedSegment = mode.rawValue
        // 字数胶囊跟着可见的窗格走（只编辑时阅读窗格折叠）
        (mode == .editor ? editorViewController : readerViewController).attachStatusOverlay(wordCount)
        if mode == .editor { wordCount.update(chapter: nil) } else if old != nil { refreshChapterProgress() }
        updateModeIndicator()
        // 混合模式：阅读视图可点击进入源码态
        let hybrid = readerViewController.textView as? HybridTextView
        hybrid?.isHybridEnabled = (mode == .hybrid)
        if mode == .hybrid { wireHybrid() }
        if showEditor, let w = window, w.isVisible { w.makeFirstResponder(editorViewController.textView) }
        if mode == .hybrid, let w = window, w.isVisible { w.makeFirstResponder(readerViewController.textView) }
    }

    @objc func setModeReader(_ sender: Any?) { mode = .reader }
    @objc func setModeEditor(_ sender: Any?) { mode = .editor }
    @objc func setModeSplit(_ sender: Any?) { mode = .split }
    @objc func setModeHybrid(_ sender: Any?) { mode = .hybrid }

    /// 章节进度：换了块表就重算（源码没变时行起点表复用）。刚 setRendered 时视口还没排版，topVisibleBlockIndex 是 nil，下一轮再算
    private func refreshChapterProgress() {
        guard let cur = current else { return }
        cur.readingTracker.documentChanged(cur.session.parsed, source: cur.session.parsedSource)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let top = self.readerViewController.textView.topVisibleBlockIndex() ?? 0
            self.wordCount.update(chapter: self.current.readingTracker.progress(at: top))
        }
    }
    /// 混合模式的回写：击键只更新文档源码（不重渲染），离开块时重解析 + 按 diff 重渲染
    private func wireHybrid() {
        guard let tab = current, !tab.hybridWired, let hybrid = tab.reader.textView as? HybridTextView else { return }
        tab.hybridWired = true
        hybrid.onSourceEdit = { [weak hybrid, weak tab] _, text, lines in
            guard let hybrid, let tab else { return }
            // 以前整篇 split("\n") + join：1 MB 每击键 ≈ 5 ms。现在只在本次激活的第一击算一次块的 UTF-16 区间，之后按区间替换
            guard let (joined, newLineCount) = tab.hybridSplicer.replace(lines: lines, in: tab.session.source, with: text) else { return }
            tab.document.setSourceFromEditor(joined, tracked: false)
            tab.document.updateChangeCount(.changeDone)
            tab.session.updateSourceWithoutRendering(joined)
            hybrid.source = joined
            // 后续块的行号随之平移：由下次重解析修正；本块行范围的变化在 HybridTextView 内部按 activeLines 维护
            hybrid.activeLinesDidChange(to: lines.lowerBound...(lines.lowerBound + newLineCount - 1))
        }
        hybrid.renderPreview = { [weak tab] src in
            guard let tab else { return nil }
            let doc = MarkdownParser(options: Preferences.shared.parserOptions).parse(src)
            return DocumentRenderer(style: tab.session.style).render(doc).attributed
        }
        hybrid.onDeactivate = { [weak tab] in
            guard let tab else { return }
            tab.hybridSplicer.reset()
            tab.session.sourceDidChange(tab.session.source, reason: .edited)
            if tab.hasEditorPane { tab.editor?.replaceSource(tab.session.source) }
        }
    }
    @objc private func modeChanged(_ sender: NSSegmentedControl) { mode = Mode(rawValue: sender.selectedSegment) ?? .reader }

    // MARK: - 滚动同步

    /// 编辑器滚动 → 阅读视图跟随。按"顶部可见行所在的块 + 行在块内的比例"定位（渲染后的块比源码行高得多，
    /// 只对齐块顶会让阅读视图在文末怎么都到不了底）；编辑器滚到顶 / 底时阅读视图也贴顶 / 底
    private var readyForScrollSync = false
    private func syncReaderToEditor(line: Int) {
        guard mode == .split, !isSyncingScroll, readyForScrollSync else { return }
        let reader = readerViewController.textView!
        guard let rendered = reader.rendered, let idx = rendered.blockIndex(forLine: line) else { return }
        isSyncingScroll = true
        defer { DispatchQueue.main.async { self.isSyncingScroll = false } }
        let editor = editorViewController.textView!
        if editor.isScrolledToBottom { reader.scrollToBottom(); return }
        if editor.isScrolledToTop { reader.scroll(toBlock: 0, animated: false); return }
        var fraction: CGFloat = 0
        if let range = rendered.blocks[idx].block.sourceRange {
            let lines = max(1, range.end.line - range.start.line + 1)
            fraction = min(1, max(0, CGFloat(line - range.start.line) / CGFloat(lines)))
        }
        reader.scroll(toBlock: idx, fraction: fraction)
    }

    private func syncEditorToReader(blockIndex: Int) {
        guard mode == .split, !isSyncingScroll, readyForScrollSync else { return }
        guard let rendered = readerViewController.textView.rendered, blockIndex < rendered.blocks.count,
              let line = rendered.blocks[blockIndex].block.sourceRange?.start.line else { return }
        // 只有阅读视图是第一响应者（用户在滚它）时才反向同步，避免编辑输入引起的抖动
        guard window?.firstResponder === readerViewController.textView else { return }
        isSyncingScroll = true
        defer { DispatchQueue.main.async { self.isSyncingScroll = false } }
        if readerViewController.textView.isScrolledToBottom { editorViewController.textView.scrollToBottom(); return }
        editorViewController.scroll(toLine: line)
    }

    // MARK: - 动作

    @objc func toggleSidebar(_ sender: Any?) {
        let collapsed = !isSidebarCollapsed
        setSidebarCollapsed(collapsed)
        UserDefaults.standard.set(collapsed, forKey: "sidebar.collapsed")
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

    // MARK: - 剪贴板互通

    /// 当前选区对应的 Markdown 源码：编辑器 = 选中文本；阅读视图 = 选区覆盖的整块；无选区 = 全文
    private func selectedMarkdown() -> String {
        let src = session.source
        if mode != .reader, let tv = editorViewController.textView, window?.firstResponder === tv {
            let r = tv.selectedRange()
            if r.length > 0, let ns = tv.textStorage?.string as NSString? { return ns.substring(with: r) }
            return src
        }
        let tv = readerViewController.textView!
        let sel = tv.selectedRange()
        guard sel.length > 0, let rendered = tv.rendered, let a = rendered.blockIndex(at: sel.location), let b = rendered.blockIndex(at: max(sel.location, sel.location + sel.length - 1)),
              let startLine = rendered.blocks[a].block.sourceRange?.start.line, let endLine = rendered.blocks[b].block.sourceRange?.end.line else { return src }
        let lines = src.components(separatedBy: "\n")
        guard startLine >= 1, endLine <= lines.count else { return src }
        return lines[(startLine - 1)...(endLine - 1)].joined(separator: "\n") + "\n"
    }

    /// ⇧⌘C 复制为 Markdown：纯文本 = 源码
    @objc func copyAsMarkdown(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(selectedMarkdown(), forType: .string)
    }

    /// 复制为 HTML：`.html` 给富文本 App 粘，`.string` 是 HTML 代码
    @objc func copyAsHTML(_ sender: Any?) {
        let md = selectedMarkdown()
        let doc = MarkdownParser(options: Preferences.shared.parserOptions).parse(md)   // 与阅读视图同一套选项（扩展语法 / 智能标点）
        var opts = HTMLRenderer.Options(); opts.includeMermaidScript = false
        let html = HTMLRenderer(theme: ThemeManager.shared.currentTheme, options: opts).fragment(doc)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(html, forType: .string)
    }

    /// 复制为纯文本：去掉 Markdown 标记后的文字
    @objc func copyAsPlainText(_ sender: Any?) {
        let doc = MarkdownParser(options: Preferences.shared.parserOptions).parse(selectedMarkdown())
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.plainText(of: doc), forType: .string)
    }

    static func plainText(of doc: Document) -> String {
        func blocks(_ bs: [Block]) -> String { bs.map(block).joined(separator: "\n\n") }
        func block(_ b: Block) -> String {
            switch b.kind {
            case .heading(_, let i, _), .paragraph(let i): return i.plainText
            case .codeBlock(_, let code), .mermaid(let code), .html(let code), .frontMatter(let code), .math(let code): return code
            case .blockQuote(let bs), .footnoteDefinition(_, let bs): return blocks(bs)
            case .list(let ordered, let start, let items):
                return items.enumerated().map { (k, it) in (ordered ? "\(start + k). " : "• ") + blocks(it.blocks) }.joined(separator: "\n")
            case .table(let t): return ([t.header] + t.rows).map { $0.map(\.plainText).joined(separator: "\t") }.joined(separator: "\n")
            case .thematicBreak: return "—"
            case .image(_, _, let alt): return alt
            }
        }
        return blocks(doc.blocks) + "\n"
    }

    @objc func pasteAsPlainText(_ sender: Any?) {
        ensureEditorMode()
        guard hasEditorPane else { NSSound.beep(); return }
        editorViewController.textView.pasteAsPlainText(sender)
    }

    // MARK: - Wikilink 与导航历史

    /// 解析 `[[name]]`：在侧栏根（无则文档目录）的索引里就近找；找不到提示
    @discardableResult
    func openWikiLink(_ name: String) -> Bool {
        guard let root = sidebarViewController.rootURL ?? markdownDocument?.fileURL?.deletingLastPathComponent() else { return false }
        let index = FileIndex.index(for: root)
        let rootPath = root.standardizedFileURL.path
        var fromDir = markdownDocument?.fileURL?.deletingLastPathComponent().standardizedFileURL.path ?? rootPath
        fromDir = fromDir.hasPrefix(rootPath) ? String(fromDir.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
        guard let rel = WikiLink.resolve(name, candidates: index.relativePaths, fromDir: fromDir) else {
            if index.isScanning {
                // 索引还没扫完：扫完再试一次，而不是直接说找不到
                var token: ChangeObservers.Token?
                token = index.observers.add { [weak self] in token = nil; _ = self?.openWikiLink(name) }
                return true
            }
            let a = NSAlert(); a.messageText = String(format: L("找不到「%@」"), name); a.informativeText = L("侧栏根目录下没有同名的 Markdown 文件。"); a.runModal()
            return false
        }
        NavigationHistory.shared.push(current: markdownDocument?.fileURL, to: index.url(for: rel))
        FileOpener.open([index.url(for: rel)])
        return true
    }

    @objc func navigateBack(_ sender: Any?) { NavigationHistory.shared.back(from: markdownDocument?.fileURL) }
    @objc func navigateForward(_ sender: Any?) { NavigationHistory.shared.forward(from: markdownDocument?.fileURL) }

    /// 快速打开 ⌘P：侧栏根目录（没有则文档所在目录）里模糊匹配文件名
    @objc func quickOpen(_ sender: Any?) {
        guard let root = sidebarViewController.rootURL ?? markdownDocument?.fileURL?.deletingLastPathComponent() else { NSSound.beep(); return }
        QuickOpenPanel.present(for: root, over: window) { url in FileOpener.open([url]) }
    }

    /// 全局搜索 ⌘⇧F：侧栏顶部搜索框，根目录内全文搜索
    @objc func showGlobalSearch(_ sender: Any?) {
        if isImmersive { exitImmersive(restoreFullScreen: false) }
        if splitViewController.splitViewItems.first?.isCollapsed == true { toggleSidebar(nil) }
        sidebarViewController.showSearch()
    }

    /// ⌥⌘F：侧栏筛选框（按名字筛树）
    @objc func focusSidebarFilter(_ sender: Any?) {
        if isImmersive { exitImmersive(restoreFullScreen: false) }
        if splitViewController.splitViewItems.first?.isCollapsed == true { toggleSidebar(nil) }
        sidebarViewController.focusFilter()
    }

    @objc func revealInSidebar(_ sender: Any?) {
        if splitViewController.splitViewItems.first?.isCollapsed == true { toggleSidebar(nil) }
        sidebarViewController.revealCurrent()
    }

    /// 阅读版式面板（工具栏 Aa / 显示 → 阅读版式…）
    private var layoutPopover: NSPopover?
    @objc func showReadingLayout(_ sender: Any?) {
        if let p = layoutPopover, p.isShown { p.close(); return }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = ReadingLayoutPanelController()
        layoutPopover = p
        // 挂在工具栏项上（macOS 14 API）：系统负责定位在按钮正下方。以前自己塞一个 NSButton 当 item.view 再按 bounds 弹——
        // 工具栏视图是翻转坐标，.minY 成了上沿，弹到窗口外面；且自定义视图在 macOS 26 的工具栏里第一次点击只是"激活"，不触发 action
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Item.layout }) {
            p.show(relativeTo: item)
        } else if let v = window?.contentView {
            p.show(relativeTo: NSRect(x: v.bounds.maxX - 40, y: v.bounds.maxY - 8, width: 1, height: 1), of: v, preferredEdge: .maxY)
        }
    }

    /// 工具栏图标统一字号 / 字重（否则实心的外观图标比线条图标重一圈）
    private static func toolbarSymbol(_ name: String, _ label: String) -> NSImage {
        (NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()).withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? NSImage()
    }

    // MARK: - NSToolbarDelegate

    private enum Item {
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        static let mode = NSToolbarItem.Identifier("mode")
        static let theme = NSToolbarItem.Identifier("theme")
        static let appearance = NSToolbarItem.Identifier("appearance")
        static let layout = NSToolbarItem.Identifier("readingLayout")
        static let sidebarSeparator = NSToolbarItem.Identifier("sidebarSeparator")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // 左段（侧栏钮）| 跟随侧栏分隔线的分隔项 | 右段：模式居中，版式 / 外观 / 主题靠右
        [Item.sidebar, Item.sidebarSeparator, .flexibleSpace, Item.mode, .flexibleSpace, Item.layout, Item.appearance, Item.theme]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Item.sidebarSeparator:
            // 系统的 sidebarTrackingSeparator 只认 .sidebar 行为的 split item；显式指定分栏视图 + 分隔线序号就能跟普通项
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: themedSplitView, dividerIndex: 0)
        case Item.sidebar:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L("目录"); item.toolTip = L("显示/隐藏目录（⌘⌥S）")
            item.image = Self.toolbarSymbol("sidebar.left", L("目录"))
            item.isBordered = false   // 深色主题的标题栏近黑，标准的圆形底座会像一颗悬浮的灰豆
            item.target = self; item.action = #selector(toggleSidebar(_:))
            item.isNavigational = true
            return item
        case Item.mode:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L("视图")
            let control = NSSegmentedControl(images: [
                Self.toolbarSymbol("doc.richtext", L("阅读")),
                Self.toolbarSymbol("chevron.left.forwardslash.chevron.right", L("编辑")),
                Self.toolbarSymbol("rectangle.split.2x1", L("分栏")),
                Self.toolbarSymbol("square.and.pencil", L("混合")),
            ], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
            control.setToolTip(L("阅读（⌘1）"), forSegment: 0)
            control.setToolTip(L("编辑（⌘2）"), forSegment: 1)
            control.setToolTip(L("分栏（⌘3）"), forSegment: 2)
            control.setToolTip(L("混合（实验，⌘4）：点击块进入源码编辑"), forSegment: 3)
            control.selectedSegment = mode.rawValue
            control.segmentStyle = .automatic
            item.view = control
            modeControl = control
            return item
        case Item.theme:
            // 下拉菜单式工具栏项：点一下弹主题列表（菜单内容每次打开时由 Handler.menuNeedsUpdate 重建）
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = L("主题"); item.toolTip = L("选择主题")
            item.image = Self.toolbarSymbol("paintpalette", L("主题"))
            item.showsIndicator = true
            item.isBordered = false   // 与旁边的图标按钮一致（都不带底座）
            let menu = MainMenu.buildThemeMenu()
            menu.delegate = MainMenu.Handler.shared
            item.menu = menu
            return item
        case Item.layout:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L("版式"); item.toolTip = L("阅读版式：字体、字号、行距、行宽…")
            item.image = Self.toolbarSymbol("textformat.size", L("版式"))
            item.isBordered = false
            item.target = self; item.action = #selector(showReadingLayout(_:))
            return item
        case Item.appearance:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = L("外观"); item.toolTip = L("切换亮 / 暗")
            item.image = Self.toolbarSymbol("circle.lefthalf.filled", L("外观"))
            item.isBordered = false
            item.target = MainMenu.Handler.shared; item.action = #selector(MainMenu.Handler.toggleAppearance(_:))
            return item
        default: return nil
        }
    }
}


// MARK: - 正文区分栏（编辑器 | 阅读）
extension WorkspaceWindowController {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(proposedMinimumPosition, 280) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(proposedMaximumPosition, splitView.bounds.width - 280) }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        splitView.arrangedSubviews.contains { $0.isHidden }   // 单栏时不画分隔线
    }
}

/// 主题色分隔线的 split view（外层 侧栏|正文、内层 编辑器|阅读 都用）：分隔线颜色跟主题的 border 走（系统的 separatorColor 在深色主题里是一条发白的线）
final class ThemedSplitView: NSSplitView {
    var dividerTint: NSColor = .separatorColor
    override var dividerColor: NSColor { dividerTint }
    // macOS 26 的 .thin 分隔线不走 dividerColor（画的是系统材质色，深色主题里几乎看不见）：自己填
    override func drawDivider(in rect: NSRect) { dividerTint.setFill(); rect.fill() }
}
