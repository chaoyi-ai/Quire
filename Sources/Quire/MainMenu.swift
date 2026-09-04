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
        let openFolderDoc = file.addItem(withTitle: L("打开文件夹…"), action: #selector(Handler.openFolder(_:)), keyEquivalent: "o")
        openFolderDoc.keyEquivalentModifierMask = [.command, .option]; openFolderDoc.target = Handler.shared
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
        export.addItem(withTitle: L("图片（PNG）…"), action: #selector(Handler.exportImage(_:)), keyEquivalent: "").target = Handler.shared
        if PandocBridge.isAvailable {
            export.addItem(.separator())
            for (i, f) in PandocBridge.exportFormats.enumerated() {
                let it = export.addItem(withTitle: f.title, action: #selector(Handler.exportPandoc(_:)), keyEquivalent: "")
                it.tag = i; it.target = Handler.shared
            }
            export.addItem(.separator())
            export.addItem(withTitle: L("（经 pandoc）"), action: nil, keyEquivalent: "")
        }
        file.addItem(withTitle: L("导出"), action: nil, keyEquivalent: "").submenu = export
        if PandocBridge.isAvailable {
            file.addItem(withTitle: L("导入 Word / HTML / EPUB…（经 pandoc）"), action: #selector(Handler.importPandoc(_:)), keyEquivalent: "").target = Handler.shared
        }
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
        edit.addItem(.separator())
        edit.addItem(withTitle: L("著作归属"), action: nil, keyEquivalent: "").submenu = AuthorshipMenu.build()
        main.addItem(withTitle: L("编辑"), action: nil, keyEquivalent: "").submenu = edit

        // Format（编辑器）
        let format = NSMenu(title: L("格式"))
        let fmtTable = format.addItem(withTitle: L("格式化表格"), action: #selector(EditorTextView.formatTable(_:)), keyEquivalent: "T")
        fmtTable.keyEquivalentModifierMask = [.command, .shift]
        format.addItem(.separator())
        format.addItem(withTitle: L("粗体"), action: #selector(EditorTextView.toggleBold(_:)), keyEquivalent: "b")
        format.addItem(withTitle: L("斜体"), action: #selector(EditorTextView.toggleItalic(_:)), keyEquivalent: "i")
        // 不用 ⌘E：那是系统的"使用所选内容查找"
        let code = format.addItem(withTitle: L("行内代码"), action: #selector(EditorTextView.toggleInlineCode(_:)), keyEquivalent: "`")
        code.keyEquivalentModifierMask = [.control, .shift]
        format.addItem(withTitle: L("链接"), action: #selector(EditorTextView.insertLink(_:)), keyEquivalent: "k")
        main.addItem(withTitle: L("格式"), action: nil, keyEquivalent: "").submenu = format

        // View
        let view = NSMenu(title: L("显示"))
        let sidebar = view.addItem(withTitle: L("显示/隐藏侧栏"), action: #selector(DocumentWindowController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .option]
        let reveal = view.addItem(withTitle: L("在侧栏中显示当前文件"), action: #selector(DocumentWindowController.revealInSidebar(_:)), keyEquivalent: "j")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        let backItem = view.addItem(withTitle: L("后退"), action: #selector(DocumentWindowController.navigateBack(_:)), keyEquivalent: "\u{F702}")
        backItem.keyEquivalentModifierMask = [.command, .control]
        let fwdItem = view.addItem(withTitle: L("前进"), action: #selector(DocumentWindowController.navigateForward(_:)), keyEquivalent: "\u{F703}")
        fwdItem.keyEquivalentModifierMask = [.command, .control]
        let filt = view.addItem(withTitle: L("筛选侧栏文件…"), action: #selector(DocumentWindowController.focusSidebarFilter(_:)), keyEquivalent: "f")
        filt.keyEquivalentModifierMask = [.command, .option]
        let gsearch = view.addItem(withTitle: L("全局搜索…"), action: #selector(DocumentWindowController.showGlobalSearch(_:)), keyEquivalent: "F")
        gsearch.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: L("阅读"), action: #selector(DocumentWindowController.setModeReader(_:)), keyEquivalent: "1")
        view.addItem(withTitle: L("编辑"), action: #selector(DocumentWindowController.setModeEditor(_:)), keyEquivalent: "2")
        view.addItem(withTitle: L("分栏"), action: #selector(DocumentWindowController.setModeSplit(_:)), keyEquivalent: "3")
        view.addItem(withTitle: L("混合（实验）"), action: #selector(DocumentWindowController.setModeHybrid(_:)), keyEquivalent: "4")
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
        // 词性高亮：关闭 / 全部 / 名词 / 动词 / 形容词 / 副词 / 连词
        let pos = NSMenu(title: L("词性高亮"))
        for (title, mode) in [(L("关闭"), POSMode.off), (L("全部词性"), .all), (L("只看名词"), .nouns), (L("只看动词"), .verbs), (L("只看形容词"), .adjectives), (L("只看副词"), .adverbs), (L("只看连词 / 介词"), .conjunctions)] {
            let it = pos.addItem(withTitle: title, action: #selector(DocumentWindowController.setPOSMode(_:)), keyEquivalent: "")
            it.tag = mode.rawValue
        }
        pos.addItem(.separator())
        pos.addItem(withTitle: L("（英 / 德 / 法 / 意 / 西 / 葡 / 俄 / 荷；中文暂不支持词性）"), action: nil, keyEquivalent: "")
        view.addItem(withTitle: L("词性高亮"), action: nil, keyEquivalent: "").submenu = pos
        let sc = view.addItem(withTitle: L("文风检查"), action: #selector(DocumentWindowController.toggleStyleCheck(_:)), keyEquivalent: "D")
        sc.keyEquivalentModifierMask = [.command, .shift, .option]
        view.addItem(withTitle: L("编辑文风规则…"), action: #selector(Handler.openStyleRules(_:)), keyEquivalent: "").target = Handler.shared
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
            let e = menu.addItem(withTitle: String(format: L("%d 个主题加载失败…"), tm.loadErrors.count), action: #selector(Handler.showThemeErrors(_:)), keyEquivalent: "")
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
    @objc func openStyleRules(_ sender: Any?) {
        let url = StyleRulesStore.url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? StyleRulesStore.template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("打开"); panel.message = L("选择一个文件夹：打开其中的 README / 第一篇 Markdown，并在侧栏显示整个目录")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        (NSDocumentController.shared as? QuireDocumentController)?.openFolder(url)
    }
    @objc func showPreferences(_ sender: Any?) { PreferencesWindowController.shared.show() }
        @objc func exportHTML(_ sender: Any?) {
            guard let doc = NSDocumentController.shared.currentDocument as? MarkdownDocument, let w = doc.windowControllers.first?.window else { return }
            Exporter.exportHTML(document: doc, from: w)
        }
        @objc func exportImage(_ sender: Any?) {
            guard let doc = NSDocumentController.shared.currentDocument as? MarkdownDocument, let w = doc.windowForSheet else { return }
            Exporter.exportImage(document: doc, from: w)
        }
        @objc func exportPandoc(_ sender: NSMenuItem) {
            guard let doc = NSDocumentController.shared.currentDocument as? MarkdownDocument, let w = doc.windowForSheet, sender.tag < PandocBridge.exportFormats.count else { return }
            PandocBridge.export(document: doc, format: PandocBridge.exportFormats[sender.tag], from: w)
        }
        @objc func importPandoc(_ sender: Any?) { PandocBridge.importDocument() }
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
            // 导出 / 复制类动作没有文档时灰掉（以前启用着、点了没反应）
            let needsDocument: [Selector] = [#selector(Handler.exportHTML(_:)), #selector(Handler.exportPDF(_:)), #selector(Handler.exportImage(_:)), #selector(Handler.exportPandoc(_:))]
            if let a = item.action, needsDocument.contains(a) { return NSDocumentController.shared.currentDocument is MarkdownDocument }
            return true
        }
    }
}
