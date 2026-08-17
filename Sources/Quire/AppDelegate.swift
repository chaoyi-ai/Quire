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

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // 阅读器：无文档时弹开文件面板，而不是空白窗口
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if NSDocumentController.shared.documents.isEmpty, NSApp.windows.allSatisfy({ !$0.isVisible }) {
            // 首次激活且没有文档：打开文件面板（只做一次）
            if !didShowInitialOpen {
                didShowInitialOpen = true
                if CommandLine.arguments.dropFirst().filter({ !$0.hasPrefix("-") }).isEmpty {
                    NSDocumentController.shared.openDocument(nil)
                }
            }
        }
    }
    private var didShowInitialOpen = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            QuireDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }
}
