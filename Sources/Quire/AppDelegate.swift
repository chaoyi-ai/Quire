import AppKit
import QuireCore
import QuireRender

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFiles: [String] = []

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
    }

    /// 无文档启动：弹开文件面板（⌘N 仍可新建）
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
        LaunchClock.mark("application(open:)")
        for url in urls {
            QuireDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }
}
