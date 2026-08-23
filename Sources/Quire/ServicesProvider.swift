import AppKit

/// macOS 服务菜单「Open in Quire」（Info.plist NSServices）：Finder 选中文件 → 右键 → 服务
@MainActor
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    @objc func openInQuire(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { error.pointee = "No file URLs on the pasteboard"; return }
        FileOpener.open(urls)
    }
}

/// 命令行工具安装：把 App 里附带的 `quire` 脚本软链到 /usr/local/bin
enum CLIInstaller {
    static let target = URL(fileURLWithPath: "/usr/local/bin/quire")
    static var bundled: URL? { Bundle.main.url(forResource: "quire", withExtension: nil) }
    /// 已装好 = /usr/local/bin/quire 指向**当前这个 App** 里的脚本（指向别的副本 / 悬空的链接都要能重装）
    static var isInstalled: Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) else { return false }
        guard let bundled else { return false }
        return URL(fileURLWithPath: dest).resolvingSymlinksInPath().path == bundled.resolvingSymlinksInPath().path && FileManager.default.fileExists(atPath: dest)
    }
    /// 返回错误说明（nil = 成功）
    static func install() -> String? {
        guard let src = bundled else { return "bundled script missing" }
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: target)
            if !fm.fileExists(atPath: "/usr/local/bin") { try fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true) }
            try fm.createSymbolicLink(at: target, withDestinationURL: src)
            return nil
        } catch {
            return "\(error.localizedDescription)\n" + String(format: L("手动安装：sudo ln -sf \"%@\" /usr/local/bin/quire"), src.path)
        }
    }
}
