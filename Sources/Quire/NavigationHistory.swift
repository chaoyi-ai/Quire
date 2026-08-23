import AppKit

/// 链接跳转历史（wikilink / 相对链接 / 侧栏打开其他文件）：⌃⌘← 后退、⌃⌘→ 前进。全局一条栈（文档是标签页打开的）。
@MainActor
final class NavigationHistory {
    static let shared = NavigationHistory()
    private var back: [URL] = []
    private var forward: [URL] = []
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// 即将离开 `current` 去别处
    func push(current: URL?) {
        guard let current else { return }
        if back.last != current { back.append(current) }
        forward.removeAll()
        if back.count > 100 { back.removeFirst() }
    }
    func back(from current: URL?) {
        guard let target = back.popLast() else { return }
        if let current { forward.append(current) }
        FileOpener.open([target])
    }
    func forward(from current: URL?) {
        guard let target = forward.popLast() else { return }
        if let current { back.append(current) }
        FileOpener.open([target])
    }
}
