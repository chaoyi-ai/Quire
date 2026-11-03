import XCTest
import os
@testable import Quire

/// FolderWatcher 销毁时正好有 FSEvents 回调。FSEventStreamStop 不等正在跑的回调，回调还摸得到正在析构的对象时，
/// 运行时 abort（"deallocated with non-zero retain count 2"）或者段错误。真实路径：关窗口时自动存盘，事件就落在监听的文件夹里。
@MainActor
final class FolderWatcherTests: XCTestCase {
    private final class Sentinel: Sendable {}
    private var tmp: URL!

    override func setUp() async throws {
        WorkspaceTests.bootApp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quire-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// 压力：竞争窗口很窄，这里靠撞（没修时本机 55 次崩 53 次，崩溃就是失败），绿了不等于证明没有竞争。
    /// 回调比事件节奏慢，消息在流的端口上排队，上一个回调结束约 30 µs 下一个就开始；回调结束时放掉 watcher，正好撞上下一个回调开始。
    func testDestroyingWhileFilesChange() {
        let file = tmp.appendingPathComponent("churn.md")
        let dir = tmp!
        let end = DispatchTime.now() + 3
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            while DispatchTime.now() < end { try? Data("x".utf8).write(to: file) }
        }
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                while DispatchTime.now() < end {
                    let called = DispatchSemaphore(value: 0)
                    let watcher = FolderWatcher(url: dir, latency: 0) { _ in
                        usleep(500)
                        called.signal()
                    }
                    withExtendedLifetime(watcher) {
                        if called.wait(timeout: end) == .success { delivered.withLock { $0 += 1 } }
                    }
                    // 最后一个引用在这里放掉
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, "销毁卡住了")
        XCTAssertGreaterThan(delivered.withLock { $0 }, 0, "一个回调都没等到，这一轮什么都没测")
    }

    /// 回调还在跑时放掉 watcher：FolderWatcher 立刻析构（回调不撑着它，否则析构会跑到回调的队列上；析构也不等回调），回调跑完之后 handler 放掉（不泄漏）。
    func testDestroyingDuringCallback() {
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchGroup()
        gate.enter()
        var sentinel: Sentinel? = Sentinel()
        var watcher = FolderWatcher(url: tmp, latency: 0) { [sentinel] _ in
            withExtendedLifetime(sentinel) {
                entered.signal()
                _ = gate.wait(timeout: .now() + 10)
            }
        }
        XCTAssertNotNil(watcher)
        weak var weakWatcher: FolderWatcher?
        weak var weakSentinel: Sentinel?
        weakWatcher = watcher
        weakSentinel = sentinel
        sentinel = nil

        let file = tmp.appendingPathComponent("a.md")
        var inCallback = false
        for _ in 0..<100 where !inCallback {
            try? Data("x".utf8).write(to: file)
            inCallback = entered.wait(timeout: .now() + 0.1) == .success
        }
        XCTAssertTrue(inCallback, "没等到回调")

        watcher = nil
        XCTAssertNil(weakWatcher, "回调撑着 FolderWatcher")
        XCTAssertNotNil(weakSentinel, "回调还在跑，handler 不能放掉")

        gate.leave()
        for _ in 0..<1000 where weakSentinel != nil { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertNil(weakSentinel, "拆完流要放掉 handler")
    }
}
