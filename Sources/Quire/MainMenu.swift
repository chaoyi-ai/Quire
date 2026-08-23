import AppKit
import QuireCore
import QuireRender

/// 主菜单（纯代码构建，无 nib）。
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        // App
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("关于 Quire"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: L("检查更新…"), action: #selector(Handler.checkForUpdates(_:)), keyEquivalent: "").target = Handler.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("设置…"), action: #selector(Handler.showPreferences(_:)), keyEquivalent: ",").target = Handler.shared
        appMenu.addItem(withTitle: L("打开主题文件夹"), action: #selector(Handler.openThemesFolder(_:)), keyEquivalent: "").target = Handler.shared
        appMenu.addItem(.separator())
        let services = NSMenu(title: L("服务"))
        appMenu.addItem(withTitle: L("服务"), action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隐藏 Quire"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L("隐藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L("全部显示"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("退出 Quire"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Quire", action: nil, keyEquivalent: "").submenu = appMenu

        // File
        let file = NSMenu(title: L("文件"))
        file.addItem(withTitle: L("新建"), action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: L("打开…"), action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let openFolder = file.addItem(withTitle: L("在侧栏打开文件夹…"), action: #selector(DocumentWindowController.chooseSidebarFolder(_:)), keyEquivalent: "O")
        openFolder.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L("快速打开…"), action: #selector(DocumentWindowController.quickOpen(_:)), keyEquivalent: "p")
        let recent = NSMenu(title: L("打开最近使用"))
        let recentItem = file.addItem(withTitle: L("打开最近使用"), action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        recent.addItem(withTitle: L("清除菜单"), action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: L("关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: L("存储…"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: L("存储为…"), action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S"); saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L("复原到已存储版本"), action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        file.addItem(.separator())
        let export = NSMenu(title: L("导出"))
        export.addItem(withTitle: "HTML…", action: #selector(Handler.exportHTML(_:)), keyEquivalent: "").target = Handler.shared
        export.addItem(withTitle: "PDF…", action: #selector(Handler.exportPDF(_:)), keyEquivalent: "").target = Handler.shared
        file.addItem(withTitle: L("导出"), action: nil, keyEquivalent: "").submenu = export
        file.addItem(.separator())
        file.addItem(withTitle: L("重新载入"), action: #selector(Handler.reload(_:)), keyEquivalent: "r").target = Handler.shared
        file.addItem(withTitle: L("在 Finder 中显示"), action: #selector(Handler.revealInFinder(_:)), keyEquivalent: "").target = Handler.shared
        file.addItem(.separator())
        let print = file.addItem(withTitle: L("打印…"), action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")
        print.keyEquivalentModifierMask = [.command, .option]   // ⌘P 让给快速打开
        main.addItem(withTitle: L("文件"), action: nil, keyEquivalent: "").submenu = file

        // Edit
        let edit = NSMenu(title: L("编辑"))
        edit.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = edit.addItem(withTitle: L("粘贴为纯文本"), action: #selector(DocumentWindowController.pasteAsPlainText(_:)), keyEquivalent: "V")
        pastePlain.keyEquivalentModifierMask = [.command, .shift]
        let copyMD = edit.addItem(withTitle: L("复制为 Markdown"), action: #selector(DocumentWindowController.copyAsMarkdown(_:)), keyEquivalent: "C")
        copyMD.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: L("复制为 HTML"), action: #selector(DocumentWindowController.copyAsHTML(_:)), keyEquivalent: "")
        edit.addItem(withTitle: L("复制为纯文本"), action: #selector(DocumentWindowController.copyAsPlainText(_:)), keyEquivalent: "")
        edit.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: L("查找"))
        let findItem = find.addItem(withTitle: L("查找…"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f"); findItem.tag = 1
        let findNext = find.addItem(withTitle: L("查找下一个"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g"); findNext.tag = 2
        let findPrev = find.addItem(withTitle: L("查找上一个"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g"); findPrev.tag = 3; findPrev.keyEquivalentModifierMask = [.command, .shift]
        let useSel = find.addItem(withTitle: L("使用所选内容查找"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "e"); useSel.tag = 7
        edit.addItem(withTitle: L("查找"), action: nil, keyEquivalent: "").submenu = find
        main.addItem(withTitle: L("编辑"), action: nil, keyEquivalent: "").submenu = edit

        // Format（编辑器）
        let format = NSMenu(title: L("格式"))
        format.addItem(withTitle: L("粗体"), action: #selector(EditorTextView.toggleBold(_:)), keyEquivalent: "b")
        format.addItem(withTitle: L("斜体"), action: #selector(EditorTextView.toggleItalic(_:)), keyEquivalent: "i")
        format.addItem(withTitle: L("行内代码"), action: #selector(EditorTextView.toggleInlineCode(_:)), keyEquivalent: "e")
        format.addItem(withTitle: L("链接"), action: #selector(EditorTextView.insertLink(_:)), keyEquivalent: "k")
        main.addItem(withTitle: L("格式"), action: nil, keyEquivalent: "").submenu = format

        // View
        let view = NSMenu(title: L("显示"))
        let sidebar = view.addItem(withTitle: L("显示/隐藏侧栏"), action: #selector(DocumentWindowController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .option]
        let reveal = view.addItem(withTitle: L("在侧栏中显示当前文件"), action: #selector(DocumentWindowController.revealInSidebar(_:)), keyEquivalent: "j")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        let gsearch = view.addItem(withTitle: L("全局搜索…"), action: #selector(DocumentWindowController.showGlobalSearch(_:)), keyEquivalent: "F")
        gsearch.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: L("阅读"), action: #selector(DocumentWindowController.setModeReader(_:)), keyEquivalent: "1")
        view.addItem(withTitle: L("编辑"), action: #selector(DocumentWindowController.setModeEditor(_:)), keyEquivalent: "2")
        view.addItem(withTitle: L("分栏"), action: #selector(DocumentWindowController.setModeSplit(_:)), keyEquivalent: "3")
        view.addItem(.separator())
        // 专注：⌘D 循环 关闭 → 句子 → 段落 → 打字机；子菜单可直选
        let focus = NSMenu(title: L("专注"))
        for (title, mode) in [(L("关闭"), EditorFocusMode.off), (L("句子"), .sentence), (L("段落"), .paragraph), (L("打字机"), .typewriter)] {
            let it = focus.addItem(withTitle: title, action: #selector(DocumentWindowController.setFocusMode(_:)), keyEquivalent: "")
            it.tag = mode.rawValue
        }
        let focusItem = view.addItem(withTitle: L("专注"), action: nil, keyEquivalent: "")
        focusItem.submenu = focus
        view.addItem(withTitle: L("切换专注模式"), action: #selector(DocumentWindowController.cycleFocusMode(_:)), keyEquivalent: "d")
        let immersive = view.addItem(withTitle: L("沉浸写作"), action: #selector(DocumentWindowController.toggleImmersive(_:)), keyEquivalent: "D")
        immersive.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: L("放大"), action: #selector(Handler.zoomIn(_:)), keyEquivalent: "+").target = Handler.shared
        view.addItem(withTitle: L("缩小"), action: #selector(Handler.zoomOut(_:)), keyEquivalent: "-").target = Handler.shared
        view.addItem(withTitle: L("实际大小"), action: #selector(Handler.zoomReset(_:)), keyEquivalent: "0").target = Handler.shared
        view.addItem(.separator())
        let appearance = NSMenu(title: L("外观"))
        for (title, mode) in [(L("跟随系统"), ThemeManager.AppearanceMode.system), (L("浅色"), .light), (L("深色"), .dark)] {
            let it = appearance.addItem(withTitle: title, action: #selector(Handler.setAppearance(_:)), keyEquivalent: "")
            it.representedObject = mode.rawValue; it.target = Handler.shared
        }
        view.addItem(withTitle: L("外观"), action: nil, keyEquivalent: "").submenu = appearance
        let themeItem = view.addItem(withTitle: L("主题"), action: nil, keyEquivalent: "")
        themeItem.submenu = NSMenu(title: L("主题"))
        themeItem.submenu?.delegate = Handler.shared
        view.addItem(.separator())
        let fullscreen = view.addItem(withTitle: L("进入全屏幕"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: L("显示"), action: nil, keyEquivalent: "").submenu = view

        // Window
        let window = NSMenu(title: L("窗口"))
        window.addItem(withTitle: L("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: L("前置全部窗口"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: L("窗口"), action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        // Help
        let help = NSMenu(title: L("帮助"))
        help.addItem(withTitle: L("Quire 项目主页"), action: #selector(Handler.openHomepage(_:)), keyEquivalent: "").target = Handler.shared
        help.addItem(withTitle: L("主题编写指南"), action: #selector(Handler.openThemeDocs(_:)), keyEquivalent: "").target = Handler.shared
        main.addItem(withTitle: L("帮助"), action: nil, keyEquivalent: "").submenu = help
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    /// 主题子菜单（工具栏弹出与显示菜单共用）
    static func buildThemeMenu() -> NSMenu {
        let menu = NSMenu(title: L("主题"))
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
        section(L("浅色"), tm.catalog.themes(for: .light))
        section(L("深色"), tm.catalog.themes(for: .dark))
        if !tm.loadErrors.isEmpty {
            menu.addItem(.separator())
            let e = menu.addItem(withTitle: "\(tm.loadErrors.count) 个主题加载失败…", action: #selector(Handler.showThemeErrors(_:)), keyEquivalent: "")
            e.target = Handler.shared
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("打开主题文件夹"), action: #selector(Handler.openThemesFolder(_:)), keyEquivalent: "").target = Handler.shared
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
            alert.messageText = L("部分主题加载失败")
            alert.informativeText = ThemeManager.shared.loadErrors.map { "\(($0.path as NSString).lastPathComponent)：\($0.error)" }.joined(separator: "\n\n")
            alert.runModal()
        }
        @objc func checkForUpdates(_ sender: Any?) { UpdateChecker.check(userInitiated: true) }
    @objc func showPreferences(_ sender: Any?) { PreferencesWindowController.shared.show() }
        @objc func exportHTML(_ sender: Any?) {
            guard let doc = NSDocumentController.shared.currentDocument as? MarkdownDocument, let w = doc.windowControllers.first?.window else { return }
            Exporter.exportHTML(document: doc, from: w)
        }
        @objc func exportPDF(_ sender: Any?) {
            guard let doc = NSDocumentController.shared.currentDocument as? MarkdownDocument, let w = doc.windowControllers.first?.window else { return }
            Exporter.exportPDF(document: doc, from: w)
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
            guard menu.title == L("主题") else { return }
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
