import AppKit

/// 更新检查：比对 GitHub Releases 最新 tag（不用 Sparkle，无第三方依赖）。每天最多一次，启动 8 s 后在后台做；可在设置里关闭。
/// 只读 GitHub API，不上传任何信息；失败静默。
@MainActor
enum UpdateChecker {
    static let releasesAPI = URL(string: "https://api.github.com/repos/chaoyi-ai/Quire/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/chaoyi-ai/Quire/releases/latest")!
    private static let lastCheckKey = "update.lastCheck"
    private static let skipKey = "update.skipVersion"

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// 启动时调用：满足条件才真正发请求
    static func checkOnLaunchIfDue() {
        guard Preferences.shared.checkForUpdates else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { check(userInitiated: false) }
    }

    /// 菜单「检查更新…」：立刻查，没更新也提示
    static func check(userInitiated: Bool) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        var req = URLRequest(url: releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        Task {
            guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = obj["tag_name"] as? String else {
                if userInitiated { alert(L("无法检查更新"), L("请检查网络，或直接访问 GitHub Releases 页面。"), showPage: true) }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if isNewer(latest, than: currentVersion) {
                if !userInitiated, UserDefaults.standard.string(forKey: skipKey) == latest { return }
                let a = NSAlert()
                a.messageText = String(format: L("Quire %@ 可用"), latest)
                a.informativeText = String(format: L("当前版本 %@。更新说明与下载见 GitHub Releases。"), currentVersion)
                a.addButton(withTitle: L("前往下载"))
                a.addButton(withTitle: L("跳过此版本"))
                a.addButton(withTitle: L("以后再说"))
                switch a.runModal() {
                case .alertFirstButtonReturn: NSWorkspace.shared.open(releasesPage)
                case .alertSecondButtonReturn: UserDefaults.standard.set(latest, forKey: skipKey)
                default: break
                }
            } else if userInitiated {
                alert(L("已是最新版本"), String(format: L("Quire %@ 是最新版本。"), currentVersion), showPage: false)
            }
        }
    }

    private static func alert(_ title: String, _ info: String, showPage: Bool) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        a.addButton(withTitle: L("好"))
        if showPage { a.addButton(withTitle: L("打开 Releases 页面")) }
        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(releasesPage) }
    }

    /// 语义版本比较（只看数字段）
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
