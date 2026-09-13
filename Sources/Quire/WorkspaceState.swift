import AppKit

/// 工作区状态恢复：退出时记下每个工作区（根目录、标签、当前标签、窗口位置、侧栏折叠），下次无文档启动时按窗口恢复。
/// 不用系统的文档恢复——它按"一份文档一个窗口"恢复，会把标签拆成一窗一窗
enum WorkspaceState {
    private static let key = "workspaces.restore"

    struct Tab: Codable { var path: String; var ephemeral: Bool; var mode: Int }
    struct Workspace: Codable { var root: String?; var tabs: [Tab]; var current: Int; var frame: String; var sidebarCollapsed: Bool }

    @MainActor static func save() {
        let all = WorkspaceWindowController.all.reversed().compactMap { ws -> Workspace? in   // orderedWindows 前在前：存成后开的在后
            guard let window = ws.window else { return nil }
            let tabs = ws.tabs.compactMap { t -> Tab? in
                guard let p = t.document.fileURL?.path else { return nil }   // 未命名文档不恢复（自动存储的草稿由系统管）
                return Tab(path: p, ephemeral: t.isEphemeral, mode: t.mode.rawValue)
            }
            guard !tabs.isEmpty else { return nil }
            let cur = ws.tabs.firstIndex { $0 === ws.current }.map { i in ws.tabs[..<i].filter { $0.document.fileURL != nil }.count } ?? 0
            return Workspace(root: ws.rootURL?.path, tabs: tabs, current: min(cur, tabs.count - 1), frame: NSStringFromRect(window.frame), sidebarCollapsed: ws.isSidebarCollapsed)
        }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 有记录且系统"退出时关闭窗口"没勾、没有 -ApplePersistenceIgnoreState → 逐个恢复；返回是否恢复了什么
    @MainActor static func restoreIfNeeded() -> Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: "ApplePersistenceIgnoreState") { return false }
        if let keep = d.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool, !keep { return false }
        guard let data = d.data(forKey: key), let saved = try? JSONDecoder().decode([Workspace].self, from: data) else { return false }
        let fm = FileManager.default
        let usable = saved.compactMap { ws -> Workspace? in
            var w = ws; w.tabs = ws.tabs.filter { fm.fileExists(atPath: $0.path) }
            return w.tabs.isEmpty ? nil : w
        }
        guard !usable.isEmpty else { return false }
        restore(usable)
        return true
    }

    @MainActor private static func restore(_ list: [Workspace]) {
        guard let ws = list.first else { return }
        let rest = Array(list.dropFirst())
        let dc = QuireDocumentController.shared as! QuireDocumentController
        let root = ws.root.map { URL(fileURLWithPath: $0) }
        func openTabs(_ i: Int, into target: WorkspaceWindowController?) {
            guard i < ws.tabs.count else {
                // 全开完：选当前标签、恢复窗口位置 / 侧栏
                if let target {
                    if let t = target.tabs[safe: ws.current] { target.select(t) }
                    if let f = Optional(NSRectFromString(ws.frame)), f.width > 0 { target.window?.setFrame(f, display: true) }
                    target.setSidebarCollapsed(ws.sidebarCollapsed, animated: false)
                }
                restore(rest)
                return
            }
            let t = ws.tabs[i]
            dc.open(URL(fileURLWithPath: t.path), in: target, ephemeral: t.ephemeral, newWindowRoot: target == nil ? root : nil) { doc in
                let target = target ?? doc?.workspace
                if let doc, let tab = target?.tab(for: doc), let m = WorkspaceWindowController.Mode(rawValue: t.mode) { target?.setMode(m, of: tab) }
                openTabs(i + 1, into: target)
            }
        }
        openTabs(0, into: nil)
    }
}
