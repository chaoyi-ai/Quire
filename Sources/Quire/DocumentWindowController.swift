import AppKit
import QuireCore
import QuireRender

/// 文档窗口：侧栏（目录）+ 阅读视图，工具栏。
@MainActor
final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let readerViewController: ReaderViewController
    let outlineViewController: OutlineViewController
    private let splitViewController = NSSplitViewController()

    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

    init(document: MarkdownDocument) {
        readerViewController = ReaderViewController(session: document.session)
        outlineViewController = OutlineViewController()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 320)
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("QuireDocumentWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        // 注意：不要在这里 self.document = document —— NSDocument.addWindowController 会因"已关联"而跳过登记
        window.delegate = self

        // 侧栏 + 内容
        let sidebar = NSSplitViewItem(sidebarWithViewController: outlineViewController)
        sidebar.minimumThickness = 160
        sidebar.maximumThickness = 360
        sidebar.canCollapse = true
        sidebar.isCollapsed = UserDefaults.standard.bool(forKey: "sidebar.collapsed")
        let content = NSSplitViewItem(viewController: readerViewController)
        content.minimumThickness = 320
        splitViewController.addSplitViewItem(sidebar)
        splitViewController.addSplitViewItem(content)
        splitViewController.splitView.autosaveName = "QuireSplit"
        window.contentViewController = splitViewController

        // 工具栏
        let toolbar = NSToolbar(identifier: "QuireToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // 目录 → 跳转
        outlineViewController.onSelect = { [weak self] entry in
            self?.readerViewController.scroll(toBlock: entry.blockIndex)
        }
        // 阅读视图滚动 → 目录高亮
        readerViewController.onTopBlockChanged = { [weak self] index in
            self?.outlineViewController.highlight(blockIndex: index)
        }
        document.session.onOutline = { [weak self] outline in
            self?.outlineViewController.outline = outline
        }
        if !document.session.parsed.blocks.isEmpty { outlineViewController.outline = document.session.parsed.outline }

        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func windowDidLoad() { super.windowDidLoad() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        markdownDocument?.session.startWatching()
    }

    func windowWillClose(_ notification: Notification) {
        markdownDocument?.session.stopWatching()
    }

    // MARK: - 动作

    @objc func toggleSidebar(_ sender: Any?) {
        splitViewController.toggleSidebar(sender)
        UserDefaults.standard.set(splitViewController.splitViewItems.first?.isCollapsed ?? false, forKey: "sidebar.collapsed")
    }

    @objc func showThemeMenu(_ sender: Any?) {
        guard let button = sender as? NSView else { return }
        let menu = MainMenu.buildThemeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: - NSToolbarDelegate

    private enum Item {
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        static let theme = NSToolbarItem.Identifier("theme")
        static let appearance = NSToolbarItem.Identifier("appearance")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.sidebar, .sidebarTrackingSeparator, .flexibleSpace, Item.appearance, Item.theme]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Item.sidebar:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "目录"; item.toolTip = "显示/隐藏目录（⌘⌥S）"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "目录")
            item.target = self; item.action = #selector(toggleSidebar(_:))
            item.isNavigational = true
            return item
        case Item.theme:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "主题"; item.toolTip = "选择主题"
            item.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "主题")
            item.target = self; item.action = #selector(showThemeMenu(_:))
            return item
        case Item.appearance:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "外观"; item.toolTip = "切换亮 / 暗"
            item.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "外观")
            item.target = MainMenu.Handler.shared; item.action = #selector(MainMenu.Handler.toggleAppearance(_:))
            return item
        default: return nil
        }
    }
}
