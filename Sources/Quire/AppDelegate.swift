import AppKit
import QuireCore
import QuireRender

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [String] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        // 主题：内置同步加载（< 5 ms），用户目录稍后
        _ = ThemeManager.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // 命令行参数打开（开发：swift run Quire file.md）
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in args {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            QuireDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        // 延迟做非关键初始化：用户主题目录监听
        DispatchQueue.main.async { ThemeManager.shared.startWatchingUserThemes() }
    }

    /// 阅读器：无文档启动时弹开文件面板，而不是空白窗口（系统只在没有文件参数时调用）
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // 命令行传了路径的话由 didFinishLaunching 处理
        if !CommandLine.arguments.dropFirst().filter({ !$0.hasPrefix("-") }).isEmpty { return true }
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    /// Dock 点击且无窗口：弹开文件面板
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            QuireDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }
}
