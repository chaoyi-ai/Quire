import Foundation

/// 多订阅者的"变了"通知。以前 FileIndex / TagIndexStore 只有一个 `onChange` 闭包，
/// 快速打开面板一赋值就把标签索引接上去的链挤掉，之后标签分组永远不再重扫；多窗口侧栏也互相覆盖。
@MainActor
final class ChangeObservers {
    final class Token {
        fileprivate let id = UUID()
        fileprivate weak var owner: ChangeObservers?
        deinit { let id = self.id; let owner = self.owner; Task { @MainActor in owner?.handlers[id] = nil } }
    }
    private var handlers: [UUID: () -> Void] = [:]

    /// 返回的 token 释放即取消订阅
    func add(_ handler: @escaping () -> Void) -> Token {
        let t = Token(); t.owner = self
        handlers[t.id] = handler
        return t
    }
    func notify() { for h in handlers.values { h() } }
    var isEmpty: Bool { handlers.isEmpty }
}
