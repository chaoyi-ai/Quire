import AppKit
import QuireCore
import QuireRender

/// 文档窗口：侧栏（目录）| 编辑器 | 阅读视图，三态（阅读 / 编辑 / 分栏），滚动同步。
@MainActor
final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    enum Mode: Int { case reader = 0, editor = 1, split = 2, hybrid = 3 }   // hybrid = 混合实时预览（实验，spike #85）

    let readerViewController: ReaderViewController
    /// 编辑器按需创建（阅读模式启动时不构建，省启动时间）
    private(set) lazy var editorViewController: EditorViewController = makeEditor()
    let sidebarViewController: SidebarViewController
    private var fileURLObserver: NSKeyValueObservation?
    private let splitViewController = NSSplitViewController()
    /// 正文区：编辑器 + 阅读视图放在一个经典 NSSplitView 里（不用 NSSplitViewController：那套用约束握着窗格宽度，
    /// setPosition 不生效、给窗格加宽度约束会把窗口撑大，每种启动模式分出来的宽度都不一样）。折叠 = 隐藏子视图
    private let contentSplit = NSSplitView()
    private let paneHost = NSViewController()
    private var editorAdded = false
    let session: DocumentSession
    private var modeControl: NSSegmentedControl?
    private let wordCount = WordCountView(frame: .zero)
    nonisolated(unsafe) private var selectionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var prefsObserver: NSObjectProtocol?
    private var isSyncingScroll = false

    var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

    private(set) var mode: Mode = .reader {
        didSet { applyMode(from: oldValue); UserDefaults.standard.set(mode.rawValue, forKey: "view.mode") }
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
        session.transclusionRoot = { [weak self] in self?.sidebarViewController.rootURL }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.noteAuthorshipMismatchIfNeeded() }
        // 注意：不要在这里 self.document = document —— NSDocument.addWindowController 会因"已关联"而跳过登记
        window.delegate = self

        // 侧栏 + 编辑器 + 阅读
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 420
        sidebar.holdingPriority = NSLayoutConstraint.Priority(300)   // 窗口 / 窗格宽度变化都落在正文窗格上，侧栏保持自己的宽度
        sidebar.canCollapse = true
        sidebar.isCollapsed = UserDefaults.standard.bool(forKey: "sidebar.collapsed")
        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.delegate = self
        paneHost.view = contentSplit
        paneHost.addChild(readerViewController)
        readerViewController.view.autoresizingMask = [.width, .height]
        contentSplit.addArrangedSubview(readerViewController.view)
        let contentItem = NSSplitViewItem(viewController: paneHost)
        contentItem.minimumThickness = 280
        splitViewController.addSplitViewItem(sidebar)
        splitViewController.addSplitViewItem(contentItem)
        // 不用 NSSplitView 的 autosave：它会把某个模式下（有窗格折叠着）的三栏宽度原样复原到别的模式，每次启动都不一样；
        // 侧栏宽度自己记（sidebar.width），双栏在 showWindow / 切模式时按等宽分
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
        // 标题栏透明、不画分隔线：工具栏直接浮在正文上（macOS 26 的做法）。否则标题栏是一条比正文亮的材质带，
        // 在侧栏浮板的右缘被硬生生切断，看起来像侧栏压着标题栏
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // 窗口底色 = 主题背景（标题栏 / 工具栏区透出来的就是它），主题一变就跟。放在这里而不是 showWindow：
        // 状态恢复 / 标签页合并出来的窗口不一定走 showWindow，那样窗口会一直是系统灰，切主题也不跟
        applyWindowBackground()
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyWindowBackground() }
        }
        LaunchClock.mark("  wc: toolbar")

        // 侧栏：标题 → 跳转（阅读视图 + 编辑器）；文件 → 打开
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
        sidebarViewController.onOpenFile = { [weak self] url, line in
            NavigationHistory.shared.push(current: self?.markdownDocument?.fileURL, to: url)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
                if let error { NSApp.presentError(error); return }
                guard let line, let md = doc as? MarkdownDocument, let wc = md.windowControllers.first as? DocumentWindowController else { return }
                // 打开后跳到指定行（大纲里点的是其他文件的标题）：等首次渲染到位，而不是猜一个 0.2 s
                md.session.whenRendered { ok in if ok { wc.jump(toLine: line) } }
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
        // 字数：全文统计随解析更新；选区统计随选择变化
        document.session.onStats = { [weak self] st in self?.wordCount.update(stats: st) }
        wordCount.update(stats: document.session.stats)
        wordCount.isHidden = !Preferences.shared.showWordCount
        readerViewController.attachStatusOverlay(wordCount)
        selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] n in
            nonisolated(unsafe) let obj = n.object
            MainActor.assumeIsolated {
                guard let self, let tv = obj as? NSTextView, tv.window === self.window else { return }
                let r = tv.selectedRange()
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
        sidebarViewController.currentURL = document.fileURL
        if !document.session.parsed.blocks.isEmpty { sidebarViewController.outline = document.session.parsed.outline }
        // 存储为 / 首次存储后 URL 变化 → 侧栏跟随
        fileURLObserver = document.observe(\.fileURL, options: [.new]) { [weak self] doc, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sidebarViewController.currentURL = doc.fileURL
                if self.editorAdded { self.editorViewController.documentURLDidChange(doc.fileURL) }
                // 未命名文档首次存储 / 存储为：监视新路径、相对图片按新目录解析（以前只在 showWindow 时设过一次）
                self.readerViewController.textView.baseURL = doc.fileURL
                if self.window?.isVisible == true { self.session.startWatching() }
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
        // 焦点给正文，不给侧栏筛选框（否则一打开光标就在筛选框里、方向键滚不了文档）
        if mode == .editor || mode == .split { window?.makeFirstResponder(editorViewController.textView) }
        else { window?.makeFirstResponder(readerViewController.textView) }
        restoreSidebarWidth()
        // 启动那几百毫秒里窗口还在布局（分栏 autosave 复原、inset 到位）：这期间不做滚动同步，也等它们完了再把双栏分成等宽
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.readyForScrollSync = true
            if self.mode == .split { self.equalizePanes() }
        }
    }

    private func makeEditor() -> EditorViewController {
        let vc = EditorViewController(session: session)
        vc.onScroll = { [weak self] line in self?.syncReaderToEditor(line: line) }
        return vc
    }

    /// 首次进入编辑/分栏时把编辑器插入 split view（sidebar 之后、reader 之前）
    private func ensureEditorPane() {
        guard !editorAdded else { return }
        editorAdded = true
        editorViewController.loadViewIfNeeded()   // 隐藏着插入不会触发 loadView；后面要直接碰 textView / scrollView
        paneHost.addChild(editorViewController)
        let half = max(280, (contentSplit.bounds.width / 2).rounded())
        editorViewController.view.frame = NSRect(x: 0, y: 0, width: half, height: max(100, contentSplit.bounds.height))
        editorViewController.view.autoresizingMask = [.width, .height]
        editorViewController.view.isHidden = !(mode == .editor || mode == .split)
        contentSplit.insertArrangedSubview(editorViewController.view, at: 0)
        contentSplit.adjustSubviews()
        // 编辑器可能晚于文档打开创建：同步当前源码
        if let doc = markdownDocument { editorViewController.replaceSource(doc.source) }
        editorViewController.textView.focusMode = focusMode
        editorViewController.textView.posMode = posMode
        if styleCheckOn { editorViewController.textView.styleChecker = StyleRulesStore.checker() }
    }

    func windowWillClose(_ notification: Notification) {
        markdownDocument?.session.stopWatching()
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
    }

    /// 窗口自己的背景也用主题色：macOS 26 的侧栏是一块带圆角、向内缩进的浮板，浮板外面那圈（圆角外侧、左边和底部的缝）
    /// 露的是窗口背景——不设的话是系统灰，和主题色的正文一比就是一圈灰边
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?
    private func applyWindowBackground() {
        window?.backgroundColor = ThemeManager.shared.currentStyle.background
    }

    // MARK: - 侧栏宽度（自己记：NSSplitView 的 autosave 在窗格折叠 / 展开时会把侧栏一起重新分配，每种启动模式宽度都不一样）
    private static let sidebarWidthKey = "sidebar.width"
    private var sidebarResizeObserver: NSObjectProtocol?
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
    var hasEditorPane: Bool { editorAdded && editorViewController.isViewLoaded }
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

    private struct ImmersiveSaved { var mode: Mode; var sidebarCollapsed: Bool; var toolbarVisible: Bool; var rulers: Bool; var wordCountHidden: Bool; var enteredFullScreen: Bool; var hidTabBar: Bool }
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
        let tabBarVisible = window.tabGroup?.isTabBarVisible ?? false
        immersiveSaved = ImmersiveSaved(mode: mode, sidebarCollapsed: sidebarCollapsed, toolbarVisible: window.toolbar?.isVisible ?? true,
                                        rulers: editorAdded ? editorViewController.scrollView.rulersVisible : Preferences.shared.editorLineNumbers,
                                        wordCountHidden: wordCount.isHidden, enteredFullScreen: !wasFull, hidTabBar: tabBarVisible)
        mode = .editor
        if !sidebarCollapsed { splitViewController.toggleSidebar(nil) }
        window.toolbar?.isVisible = false
        if tabBarVisible { window.toggleTabBar(nil) }
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
        if saved.hidTabBar, window.tabGroup?.isTabBarVisible == false { window.toggleTabBar(nil) }
        if !saved.sidebarCollapsed, splitViewController.splitViewItems.first?.isCollapsed == true { splitViewController.toggleSidebar(nil) }
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

    /// 跳到源码行（阅读视图按块、编辑器按行）
    func jump(toLine line: Int) {
        if let rendered = readerViewController.textView.rendered, let idx = rendered.blockIndex(forLine: line) {
            readerViewController.scroll(toBlock: idx)
        }
        if mode != .reader { editorViewController.scroll(toLine: line) }
    }

    /// 文档从磁盘（重新）读入：同步编辑器文本
    func documentDidReload(_ source: String) {
        guard hasEditorPane else { return }
        editorViewController.replaceSource(source)
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
        if editorAdded { editorViewController.view.isHidden = !showEditor }
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

    private var hybridWired = false
    /// 混合模式的回写：击键只更新文档源码（不重渲染），离开块时重解析 + 按 diff 重渲染
    private func wireHybrid() {
        guard !hybridWired, let hybrid = readerViewController.textView as? HybridTextView else { return }
        hybridWired = true
        hybrid.onSourceEdit = { [weak self, weak hybrid] _, text, lines in
            guard let self, let hybrid else { return }
            var all = self.session.source.components(separatedBy: "\n")
            // 源码末尾有换行时 components 多出一个空串；块源码自带末尾换行
            let newLines = text.hasSuffix("\n") ? String(text.dropLast()).components(separatedBy: "\n") : text.components(separatedBy: "\n")
            guard lines.lowerBound >= 1, lines.upperBound <= all.count else { return }
            all.replaceSubrange((lines.lowerBound - 1)...(lines.upperBound - 1), with: newLines)
            let joined = all.joined(separator: "\n")
            self.markdownDocument?.setSourceFromEditor(joined, tracked: false)
            self.markdownDocument?.updateChangeCount(.changeDone)
            self.session.updateSourceWithoutRendering(joined)
            hybrid.source = joined
            // 后续块的行号随之平移：由下次重解析修正；本块行范围的变化在 HybridTextView 内部按 activeLines 维护
            hybrid.activeLinesDidChange(to: lines.lowerBound...(lines.lowerBound + newLines.count - 1))
        }
        hybrid.renderPreview = { [weak self] src in
            guard let self else { return nil }
            let doc = MarkdownParser(options: Preferences.shared.parserOptions).parse(src)
            return DocumentRenderer(style: self.session.style).render(doc).attributed
        }
        hybrid.onDeactivate = { [weak self] in
            guard let self else { return }
            self.session.sourceDidChange(self.session.source, reason: .edited)
            if self.editorAdded { self.editorViewController.replaceSource(self.session.source) }
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
extension DocumentWindowController {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(proposedMinimumPosition, 280) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(proposedMaximumPosition, splitView.bounds.width - 280) }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        splitView.arrangedSubviews.contains { $0.isHidden }   // 单栏时不画分隔线
    }
}
