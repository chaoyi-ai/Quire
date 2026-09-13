import AppKit
import QuireCore
import QuireRender

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchClock.mark("willFinishLaunching")
        MainMenu.install()
        LaunchClock.mark("menu installed")
        // 主题：内置同步加载（< 5 ms），用户目录稍后
        _ = ThemeManager.shared
        LaunchClock.mark("theme manager ready")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchClock.mark("didFinishLaunching")
        NSApp.activate(ignoringOtherApps: true)
        // 命令行里的文件路径由 AppKit 自动转成 open 事件（application(_:open:)），这里不再重复打开
        // 延迟做非关键初始化：用户主题目录监听（首帧之后）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ThemeManager.shared.startWatchingUserThemes() }
        UpdateChecker.checkOnLaunchIfDue()
        NSApp.servicesProvider = ServicesProvider.shared
        if let path = ProcessInfo.processInfo.environment["QUIRE_EXPORT_PNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Task { @MainActor in
                    if let doc = NSDocumentController.shared.documents.first as? MarkdownDocument {
                        let ok = await Exporter.writeImage(document: doc, to: URL(fileURLWithPath: path))
                        FileHandle.standardError.write("QUIRE_EXPORT_PNG=\(ok ? "ok" : "failed")\n".data(using: .utf8)!)
                    }
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["QUIRE_EXPORT_PDF"] {
            // 调试 / 脚本（含 scripts/smoke_app.sh）：首个文档渲染后导出 PDF 并退出
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Task { @MainActor in
                    if let doc = NSDocumentController.shared.documents.first as? MarkdownDocument {
                        let ok = await Exporter.writePDF(document: doc, to: URL(fileURLWithPath: path))
                        FileHandle.standardError.write("QUIRE_EXPORT_PDF=\(ok ? "ok" : "failed")\n".data(using: .utf8)!)
                    } else {
                        FileHandle.standardError.write("QUIRE_EXPORT_PDF=failed (no document)\n".data(using: .utf8)!)
                    }
                    exit(0)
                }
            }
        }

        if ProcessInfo.processInfo.environment["QUIRE_OPEN_PREFS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { PreferencesWindowController.shared.show() }
        }
    }

    /// 无文档启动：先恢复上次的工作区窗口；没有可恢复的就弹开文件面板（⌘N 仍可新建）。命令行带文件时 AppKit 会走 open 事件而不调用这里。
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if WorkspaceState.restoreIfNeeded() { return true }
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    /// 退出前记下所有工作区（此时文档还没开始关）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WorkspaceState.save()
        return .terminateNow
    }

    /// Dock 点击且无窗口：弹开文件面板
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        LaunchClock.mark("application(open:)")
        for url in urls {
            if URLScheme.isSchemeURL(url) { URLScheme.handle(url); continue }
            QuireDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }
}
