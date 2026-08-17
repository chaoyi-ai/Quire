import AppKit
import QuireCore

/// 主菜单（纯代码构建，无 nib）。
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        // App
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Quire", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "打开主题文件夹", action: #selector(Handler.openThemesFolder(_:)), keyEquivalent: "").target = Handler.shared
        appMenu.addItem(.separator())
        let services = NSMenu(title: "服务")
        appMenu.addItem(withTitle: "服务", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Quire", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Quire", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Quire", action: nil, keyEquivalent: "").submenu = appMenu

        // File
        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "打开…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: "打开最近使用")
        let recentItem = file.addItem(withTitle: "打开最近使用", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        recent.addItem(withTitle: "清除菜单", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "重新载入", action: #selector(Handler.reload(_:)), keyEquivalent: "r").target = Handler.shared
        file.addItem(withTitle: "在 Finder 中显示", action: #selector(Handler.revealInFinder(_:)), keyEquivalent: "").target = Handler.shared
        file.addItem(.separator())
        file.addItem(withTitle: "打印…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")
        main.addItem(withTitle: "文件", action: nil, keyEquivalent: "").submenu = file

        // Edit
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "查找")
        let findItem = find.addItem(withTitle: "查找…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f"); findItem.tag = 1
        let findNext = find.addItem(withTitle: "查找下一个", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g"); findNext.tag = 2
        let findPrev = find.addItem(withTitle: "查找上一个", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g"); findPrev.tag = 3; findPrev.keyEquivalentModifierMask = [.command, .shift]
        let useSel = find.addItem(withTitle: "使用所选内容查找", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "e"); useSel.tag = 7
        edit.addItem(withTitle: "查找", action: nil, keyEquivalent: "").submenu = find
        main.addItem(withTitle: "编辑", action: nil, keyEquivalent: "").submenu = edit

        // View
        let view = NSMenu(title: "显示")
        let sidebar = view.addItem(withTitle: "显示/隐藏目录", action: #selector(DocumentWindowController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        view.addItem(withTitle: "放大", action: #selector(Handler.zoomIn(_:)), keyEquivalent: "+").target = Handler.shared
        view.addItem(withTitle: "缩小", action: #selector(Handler.zoomOut(_:)), keyEquivalent: "-").target = Handler.shared
        view.addItem(withTitle: "实际大小", action: #selector(Handler.zoomReset(_:)), keyEquivalent: "0").target = Handler.shared
        view.addItem(.separator())
        let appearance = NSMenu(title: "外观")
        for (title, mode) in [("跟随系统", ThemeManager.AppearanceMode.system), ("浅色", .light), ("深色", .dark)] {
            let it = appearance.addItem(withTitle: title, action: #selector(Handler.setAppearance(_:)), keyEquivalent: "")
            it.representedObject = mode.rawValue; it.target = Handler.shared
        }
        view.addItem(withTitle: "外观", action: nil, keyEquivalent: "").submenu = appearance
        let themeItem = view.addItem(withTitle: "主题", action: nil, keyEquivalent: "")
        themeItem.submenu = NSMenu(title: "主题")
        themeItem.submenu?.delegate = Handler.shared
        view.addItem(.separator())
        let fullscreen = view.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "显示", action: nil, keyEquivalent: "").submenu = view

        // Window
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "窗口", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        // Help
        let help = NSMenu(title: "帮助")
        help.addItem(withTitle: "Quire 项目主页", action: #selector(Handler.openHomepage(_:)), keyEquivalent: "").target = Handler.shared
        help.addItem(withTitle: "主题编写指南", action: #selector(Handler.openThemeDocs(_:)), keyEquivalent: "").target = Handler.shared
        main.addItem(withTitle: "帮助", action: nil, keyEquivalent: "").submenu = help
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    /// 主题子菜单（工具栏弹出与显示菜单共用）
    static func buildThemeMenu() -> NSMenu {
        let menu = NSMenu(title: "主题")
        let tm = ThemeManager.shared
        let current = tm.currentTheme.id
        func section(_ title: String, _ themes: [Theme]) {
            guard !themes.isEmpty else { return }
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for t in themes {
                let it = menu.addItem(withTitle: t.name, action: #selector(Handler.selectTheme(_:)), keyEquivalent: "")
                it.representedObject = t.id
                it.target = Handler.shared
                it.state = t.id == current ? .on : .off
                it.indentationLevel = 1
                if t.sourcePath?.contains("Application Support") == true { it.toolTip = t.sourcePath }
            }
        }
        section("浅色", tm.catalog.themes(for: .light))
        section("深色", tm.catalog.themes(for: .dark))
        if !tm.loadErrors.isEmpty {
            menu.addItem(.separator())
            let e = menu.addItem(withTitle: "\(tm.loadErrors.count) 个主题加载失败…", action: #selector(Handler.showThemeErrors(_:)), keyEquivalent: "")
            e.target = Handler.shared
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开主题文件夹", action: #selector(Handler.openThemesFolder(_:)), keyEquivalent: "").target = Handler.shared
        return menu
    }


    /// 菜单动作接收者
    @MainActor
    final class Handler: NSObject, NSMenuDelegate, NSMenuItemValidation {
        static let shared = Handler()

        @objc func selectTheme(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            ThemeManager.shared.select(themeID: id)
        }
        @objc func setAppearance(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let m = ThemeManager.AppearanceMode(rawValue: raw) else { return }
            ThemeManager.shared.mode = m
        }
        @objc func toggleAppearance(_ sender: Any?) {
            let tm = ThemeManager.shared
            tm.mode = tm.effectiveAppearance == .dark ? .light : .dark
        }
        @objc func zoomIn(_ sender: Any?) { ThemeManager.shared.zoomIn() }
        @objc func zoomOut(_ sender: Any?) { ThemeManager.shared.zoomOut() }
        @objc func zoomReset(_ sender: Any?) { ThemeManager.shared.zoomReset() }
        @objc func openThemesFolder(_ sender: Any?) {
            let dir = ThemeStore.userThemesDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        }
        @objc func showThemeErrors(_ sender: Any?) {
            let alert = NSAlert()
            alert.messageText = "部分主题加载失败"
            alert.informativeText = ThemeManager.shared.loadErrors.map { "\(($0.path as NSString).lastPathComponent)：\($0.error)" }.joined(separator: "\n\n")
            alert.runModal()
        }
        @objc func openHomepage(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://github.com/chaoyi-ai/Quire")!) }
        @objc func openThemeDocs(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://github.com/chaoyi-ai/Quire/blob/main/docs/THEMES.md")!) }
        @objc func reload(_ sender: Any?) {
            (NSDocumentController.shared.currentDocument as? MarkdownDocument)?.reloadFromDisk()
        }
        @objc func revealInFinder(_ sender: Any?) {
            guard let url = NSDocumentController.shared.currentDocument?.fileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard menu.title == "主题" else { return }
            menu.removeAllItems()
            for item in MainMenu.buildThemeMenu().items { menu.addItem(item.copy() as! NSMenuItem) }
        }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            if item.action == #selector(Handler.setAppearance(_:)) {
                item.state = (item.representedObject as? String) == ThemeManager.shared.mode.rawValue ? .on : .off
            }
            if item.action == #selector(Handler.reload(_:)) || item.action == #selector(Handler.revealInFinder(_:)) {
                return NSDocumentController.shared.currentDocument?.fileURL != nil
            }
            return true
        }
    }
}
