import XCTest
import AppKit
@testable import Quire
import QuireCore
import QuireRender

/// CI 把所有测试目标合成一个测试包，NSApp 在前面的用例里就建好了。之后 XCTWaiter 等 async 用例时跑事件循环，AppKit 随时可能走启动收尾
/// （_DPSNextEvent → _sendFinishLaunchingNotification → _reopenWindowsAsNecessary…），那里读共享控制器，没有就建默认的。
/// 所以要赶在所有用例之前建：XCTest 枚举测试类时（任何用例开始之前）读 defaultTestSuite，这个类没有用例，只借这个时机。
/// 不能写在 WorkspaceTests 上：覆写了它的类，swift test --filter / --skip 会选中 0 个用例，还是绿的
final class AppBootSentinel: XCTestCase {
    override class var defaultTestSuite: XCTestSuite {
        MainActor.assumeIsolated { WorkspaceTests.bootController() }
        return XCTestSuite(name: "AppBootSentinel")
    }
}

/// 工作区窗口模型（ADR-18）：标签的增删选、临时标签替换 / 固定、document 换挂、文档控制器的去向判断、状态存取。
/// 在 xctest 进程里真建窗口（不显示到屏幕的也能建），不弹任何 sheet（只用没改过的文档，或改过但有文件、就地自动保存的文档；要取消就用 ScriptedDocument 替面板回答）。
@MainActor
final class WorkspaceTests: XCTestCase {
    private var tmp: URL!
    private var hangWatchdog: DispatchWorkItem?
    nonisolated(unsafe) private static var booted = false
    /// 共享控制器建好时的类型：断言失败时分得清是一开始就输了，还是建好之后被换掉
    nonisolated(unsafe) private static var sharedAtBoot = "未建"

    /// 所有测试类都走这里。共享控制器先到先得：已经有默认的，QuireDocumentController() 拿到的还是默认的。所以要赶在所有用例之前（AppBootSentinel）
    static func bootController() {
        guard !booted else { return }
        booted = true
        _ = QuireDocumentController()
        sharedAtBoot = "\(Swift.type(of: NSDocumentController.shared))"
    }

    static func bootApp() {
        bootController()
        _ = NSApplication.shared
    }

    override func setUp() async throws {
        // 主线程挂住时（死锁，或者弹了没人点的模态窗口）XCTest 的超时也等不到，整轮测试永远挂着：只能从后台让进程带着说明崩掉
        let watchdog = DispatchWorkItem { @Sendable in fatalError("测试 120 s 没结束：主线程死锁，或者弹了没人点的模态窗口") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
        hangWatchdog = watchdog
        Self.bootApp()
        XCTAssertTrue(NSDocumentController.shared is QuireDocumentController, "QuireDocumentController 必须是共享控制器：建好时是 \(Self.sharedAtBoot)，现在是 \(Swift.type(of: NSDocumentController.shared))")
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quire-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for n in ["a", "b", "c"] { try "# \(n)\n\ntext\n".write(to: tmp.appendingPathComponent("\(n).md"), atomically: true, encoding: .utf8) }
    }

    override func tearDown() async throws {
        defer { hangWatchdog?.cancel() }
        // 关掉本测试开的所有文档（文档 close 不问；最后一个文档带走窗口）。不能先直接关多标签的窗口：
        // AppKit 会把窗口挂着的文档关掉，标签换挂到下一个，留下一个没窗口的工作区，下一个测试的文件会被路由进去
        for doc in NSDocumentController.shared.documents { doc.close() }
        for ws in WorkspaceWindowController.all { ws.window?.close() }
        // 关掉的窗口要等这一轮 autorelease 池放掉才从 NSApp 的窗口表里消失
        for _ in 0..<50 where !WorkspaceWindowController.all.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(WorkspaceWindowController.all.isEmpty, "本测试留下了工作区")
        try? FileManager.default.removeItem(at: tmp)
    }

    private func untitled() -> MarkdownDocument {
        let d = MarkdownDocument()
        NSDocumentController.shared.addDocument(d)
        return d
    }

    /// 打开文件并等完成（回调在主线程；文档不是 Sendable，不能穿 continuation）
    private func open(_ url: URL, in ws: WorkspaceWindowController?, ephemeral: Bool) async -> MarkdownDocument? {
        let dc = NSDocumentController.shared as! QuireDocumentController
        var result: MarkdownDocument?
        let done = expectation(description: "open \(url.lastPathComponent)")
        dc.open(url, in: ws, ephemeral: ephemeral) { result = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
        return result
    }

    private func makeWorkspace(root: URL? = nil) -> (WorkspaceWindowController, MarkdownDocument) {
        let d = untitled()
        let ws = WorkspaceWindowController(document: d, root: root)
        return (ws, d)
    }

    // MARK: 标签

    func testAddSelectRehangsDocument() {
        let (ws, a) = makeWorkspace()
        let b = untitled()
        XCTAssertTrue(ws.document === a)
        ws.addTab(b, ephemeral: false)
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertTrue(ws.current.document === b)
        XCTAssertTrue(ws.document === b, "窗口控制器的 document 跟当前标签")
        XCTAssertEqual(a.windowControllers.count, 0, "非当前标签的文档不挂窗口控制器")
        XCTAssertEqual(b.windowControllers.count, 1)
        XCTAssertTrue(a.workspace === ws && b.workspace === ws)
        ws.select(ws.tabs[0])
        XCTAssertTrue(ws.document === a)
        XCTAssertEqual(b.windowControllers.count, 0)
        XCTAssertEqual(a.windowControllers.count, 1)
    }

    func testEphemeralTabIsReplacedByNextEphemeral() {
        let (ws, a) = makeWorkspace()
        let b = untitled(), c = untitled()
        ws.addTab(b, ephemeral: true)
        ws.addTab(c, ephemeral: true)
        XCTAssertEqual(ws.tabs.map { $0.document === a ? "a" : $0.document === b ? "b" : "c" }, ["a", "c"], "临时标签被下一个临时标签替换，位置不变")
        XCTAssertTrue(ws.current.document === c)
        XCTAssertTrue(ws.tabs[1].isEphemeral)
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === b }, "被替换的临时标签的文档已关闭")
        XCTAssertNil(b.workspace)
    }

    func testEditedEphemeralTabBecomesPinnedAndIsNotReplaced() {
        let (ws, _) = makeWorkspace()
        let b = untitled(), c = untitled()
        ws.addTab(b, ephemeral: true)
        b.updateChangeCount(.changeDone)
        XCTAssertFalse(ws.tab(for: b)!.isEphemeral, "改过的标签不再是临时的")
        ws.addTab(c, ephemeral: true)
        XCTAssertEqual(ws.tabs.count, 3, "固定标签不会被替换")
        b.updateChangeCount(.changeUndone)   // 清干净，tearDown 关闭时不问
    }

    func testPinAndMove() {
        let (ws, _) = makeWorkspace()
        let b = untitled()
        ws.addTab(b, ephemeral: true)
        ws.pin(ws.tab(for: b)!)
        XCTAssertFalse(ws.tab(for: b)!.isEphemeral)
        ws.moveTab(from: 1, to: 0)
        XCTAssertTrue(ws.tabs[0].document === b)
    }

    func testDocumentCloseDetachesTabAndKeepsWindow() {
        let (ws, a) = makeWorkspace()
        let b = untitled()
        ws.addTab(b, ephemeral: false)
        b.close()
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertTrue(ws.current.document === a)
        XCTAssertTrue(ws.document === a)
        XCTAssertNil(b.workspace)
        XCTAssertNotNil(ws.window, "不是最后一个标签：窗口还在")
    }

    func testCloseTabSelectsNeighbour() {
        let (ws, a) = makeWorkspace()
        let b = untitled(), c = untitled()
        ws.addTab(b, ephemeral: false)
        ws.addTab(c, ephemeral: false)
        ws.select(ws.tab(for: b)!)
        ws.closeTab(ws.tab(for: b)!)
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertTrue(ws.current.document === c, "关掉中间的标签，选中右边的邻居")
        _ = a
    }

    // MARK: 关闭（走 performClose 的真路径：AppKit 先问当前文档，tearDown 的 window.close() 碰不到这里）

    /// 主线程死锁时 XCTest 的超时也等不到（它同样在主线程上），只能从后台让进程带着说明崩掉，否则整轮测试永远挂着
    private func failingOnDeadlock(_ body: () async throws -> Void) async rethrows {
        let watchdog = DispatchWorkItem { @Sendable in fatalError("主线程 30 s 没回来：死锁，或者弹了没人点的模态窗口") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        try await body()
    }

    private func waitForWindowClose(of ws: WorkspaceWindowController, _ close: () -> Void) async {
        await failingOnDeadlock {
            let closed = expectation(forNotification: NSWindow.willCloseNotification, object: ws.window)
            close()
            await fulfillment(of: [closed], timeout: 20)
        }
    }

    private func openFile(_ name: String, in ws: WorkspaceWindowController? = nil) async throws -> (doc: MarkdownDocument, ws: WorkspaceWindowController, url: URL) {
        let url = tmp.appendingPathComponent(name)
        let opened = await open(url, in: ws, ephemeral: false)
        let doc = try XCTUnwrap(opened)
        return (doc, try XCTUnwrap(doc.workspace), url)
    }

    private func isOpen(_ doc: NSDocument) -> Bool { NSDocumentController.shared.documents.contains(doc) }
    private func disk(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testCloseLastTabOfCleanFileClosesWindow() async throws {
        let a = try await openFile("a.md")
        await waitForWindowClose(of: a.ws) { a.ws.closeCurrentTab(nil) }
        XCTAssertFalse(isOpen(a.doc))
    }

    func testCloseLastTabOfUntouchedNewDocumentClosesWindow() async {
        let (ws, doc) = makeWorkspace()
        await waitForWindowClose(of: ws) { ws.closeCurrentTab(nil) }
        XCTAssertFalse(isOpen(doc))
    }

    func testCloseLastTabOfEditedFileSavesItAndClosesWindow() async throws {
        let a = try await openFile("a.md")
        a.doc.replaceContents("# edited a\n")
        await waitForWindowClose(of: a.ws) { a.ws.closeCurrentTab(nil) }
        XCTAssertFalse(isOpen(a.doc))
        XCTAssertEqual(try disk(a.url), "# edited a\n", "关之前改动要落盘")
    }

    func testCloseWindowWithSeveralTabsSavesEveryEditedOne() async throws {
        let a = try await openFile("a.md")
        let b = try await openFile("b.md", in: a.ws)
        let c = try await openFile("c.md", in: a.ws)
        a.doc.replaceContents("# edited a\n")
        b.doc.replaceContents("# edited b\n")
        a.ws.select(try XCTUnwrap(a.ws.tab(for: b.doc)))
        await waitForWindowClose(of: a.ws) { a.ws.window?.performClose(nil) }
        for d in [a.doc, b.doc, c.doc] { XCTAssertFalse(isOpen(d)) }
        XCTAssertEqual(try disk(a.url), "# edited a\n", "后台标签的改动也要落盘")
        XCTAssertEqual(try disk(b.url), "# edited b\n", "当前标签的改动要落盘")
    }

    func testCloseRequestedTwiceInARowStillClosesOnce() async throws {
        let a = try await openFile("a.md")
        a.doc.replaceContents("# edited a\n")
        await waitForWindowClose(of: a.ws) {
            a.ws.closeCurrentTab(nil)
            a.ws.closeCurrentTab(nil)
        }
        XCTAssertFalse(isOpen(a.doc))
        XCTAssertEqual(try disk(a.url), "# edited a\n")
    }

    func testCloseEditedTabAmongSeveralSavesItAndKeepsWindow() async throws {
        let a = try await openFile("a.md")
        let b = try await openFile("b.md", in: a.ws)
        a.doc.replaceContents("# edited a\n")
        let tab = try XCTUnwrap(a.ws.tab(for: a.doc))
        try await failingOnDeadlock {
            a.ws.closeTab(tab)
            while a.ws.tabs.count > 1 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(a.ws.current.document === b.doc)
        XCTAssertFalse(isOpen(a.doc))
        XCTAssertEqual(try disk(a.url), "# edited a\n")
    }

    // MARK: 取消（未存储面板在 xctest 进程里点不了：只替换回答这一步，标签、窗口、关闭都走真路径）

    /// later = 先不回答，等测试调 reply（相当于面板开着）
    private final class ScriptedDocument: MarkdownDocument {
        enum Answer { case yes, no, later }
        nonisolated(unsafe) var answer = Answer.yes
        nonisolated(unsafe) var asked = 0
        nonisolated(unsafe) var reply: ((Bool) -> Void)?

        override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
            asked += 1
            let target = delegate as! NSObject, selector = shouldCloseSelector!
            typealias Reply = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
            let send: (Bool) -> Void = { [unowned self] ok in unsafeBitCast(target.method(for: selector), to: Reply.self)(target, selector, self, ok, contextInfo) }
            switch answer {
            case .yes: send(true)
            case .no: send(false)
            case .later: reply = send
            }
        }
    }

    private func scripted(in ws: WorkspaceWindowController, _ answer: ScriptedDocument.Answer = .yes) -> ScriptedDocument {
        let d = ScriptedDocument()
        d.answer = answer
        NSDocumentController.shared.addDocument(d)
        ws.addTab(d, ephemeral: false)
        return d
    }

    /// 有文件的文档要等自动保存完才答复，轮到下一个标签之前要等
    private func waitUntilAsked(_ doc: ScriptedDocument) async throws {
        try await failingOnDeadlock { while doc.asked == 0 { try await Task.sleep(for: .milliseconds(20)) } }
    }

    func testCancelWhileClosingWindowKeepsEveryTab() async throws {
        let a = try await openFile("a.md")
        a.doc.replaceContents("# edited a\n")
        let cancels = scripted(in: a.ws, .no)
        let after = scripted(in: a.ws)
        a.ws.window?.performClose(nil)
        try await waitUntilAsked(cancels)
        XCTAssertEqual(after.asked, 0, "取消之后不再往下问")
        XCTAssertEqual(a.ws.tabs.count, 3, "先问过的标签也留着")
        for d in [a.doc, cancels, after] as [MarkdownDocument] { XCTAssertTrue(isOpen(d)) }
        XCTAssertEqual(a.ws.window?.isVisible, true)
        XCTAssertTrue(a.ws.current.document === cancels, "停在取消的那个标签上")
        XCTAssertEqual(try disk(a.url), "# edited a\n", "问的时候有文件的改动已经存了")

        // 再关一次：从头问，这次都同意就真关
        cancels.answer = .yes
        await waitForWindowClose(of: a.ws) { a.ws.window?.performClose(nil) }
        XCTAssertEqual(cancels.asked, 2)
        XCTAssertEqual(after.asked, 1)
        for d in [a.doc, cancels, after] as [MarkdownDocument] { XCTAssertFalse(isOpen(d)) }
    }

    func testCancelWhileClosingOtherTabsKeepsEveryTab() {
        let (ws, keep) = makeWorkspace()
        let agrees = scripted(in: ws)
        let cancels = scripted(in: ws, .no)
        let keepTab = ws.tab(for: keep)!
        ws.closeOtherTabs(keeping: keepTab)
        XCTAssertEqual(agrees.asked, 1)
        XCTAssertEqual(cancels.asked, 1)
        XCTAssertEqual(ws.tabs.count, 3, "先同意的标签也留着")
        XCTAssertTrue(isOpen(agrees))
        XCTAssertTrue(ws.current === keepTab)

        cancels.answer = .yes
        ws.closeOtherTabs(keeping: keepTab)
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertFalse(isOpen(agrees))
        XCTAssertFalse(isOpen(cancels))
        XCTAssertTrue(ws.current === keepTab)
    }

    func testCancelClosingOneOfSeveralTabsKeepsIt() {
        let (ws, _) = makeWorkspace()
        let cancels = scripted(in: ws, .no)
        ws.closeTab(ws.tab(for: cancels)!)
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertTrue(isOpen(cancels))
        XCTAssertTrue(ws.current.document === cancels)
    }

   /// 回调只有一格：面板开着时再来一轮询问，会把这个面板的答案交给下一个还没回答的文档
    func testCloseRequestedWhileAPanelIsUpIsIgnored() async throws {
        let (ws, first) = makeWorkspace()
        let panelUp = scripted(in: ws, .later)
        let next = scripted(in: ws)
        let firstTab = ws.tab(for: first)!, nextTab = ws.tab(for: next)!
        ws.window?.performClose(nil)
        try await waitUntilAsked(panelUp)

        ws.window?.performClose(nil)
        ws.closeTab(nextTab)
        ws.closeOtherTabs(keeping: firstTab)
        XCTAssertEqual(panelUp.asked, 1, "同一份文档不问第二遍")
        XCTAssertEqual(next.asked, 0, "面板还没回答，不往下问")
        XCTAssertTrue(ws.current.document === panelUp, "面板挂着的标签不能被切走")
        XCTAssertEqual(ws.tabs.count, 3)

        await waitForWindowClose(of: ws) { panelUp.reply?(true) }
        XCTAssertEqual(panelUp.asked, 1)
        XCTAssertEqual(next.asked, 1)
        for d in [first, panelUp, next] as [MarkdownDocument] { XCTAssertFalse(isOpen(d)) }
    }

    func testTabOpenedWhileAPanelIsUpSurvivesWindowClose() async throws {
        let (ws, first) = makeWorkspace()
        let panelUp = scripted(in: ws, .later)
        ws.window?.performClose(nil)
        try await waitUntilAsked(panelUp)
        let newcomer = scripted(in: ws)
        panelUp.reply?(true)
        XCTAssertFalse(isOpen(first))
        XCTAssertFalse(isOpen(panelUp))
        XCTAssertTrue(isOpen(newcomer), "没问过的标签不能跟着关")
        XCTAssertEqual(newcomer.asked, 0)
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertTrue(ws.current.document === newcomer)
        XCTAssertNotNil(ws.window)
    }

    func testTabMovedAwayWhileAPanelIsUpIsNotClosed() async throws {
        let (ws, keep) = makeWorkspace()
        let panelUp = scripted(in: ws, .later)
        let moved = untitled()
        let movedTab = ws.addTab(moved, ephemeral: false)
        let keepTab = ws.tab(for: keep)!
        ws.closeOtherTabs(keeping: keepTab)
        try await waitUntilAsked(panelUp)
        ws.detach(movedTab)
        let other = WorkspaceWindowController(document: moved, root: nil)
        panelUp.reply?(true)
        XCTAssertFalse(isOpen(panelUp))
        XCTAssertTrue(isOpen(moved), "询问期间移走的标签已经不归这个窗口关")
        XCTAssertTrue(moved.workspace === other)
    }

    func testMergeAllWindowsWaitsForAnAskInAnotherWindow() async throws {
        let a = try await openFile("a.md")
        let panelUp = scripted(in: a.ws, .later)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quire-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = dir.appendingPathComponent("x.md")
        try "# x\n".write(to: x, atomically: true, encoding: .utf8)
        let opened = await open(x, in: nil, ephemeral: false)
        let other = try XCTUnwrap(opened?.workspace)
        XCTAssertFalse(other === a.ws)

        a.ws.window?.performClose(nil)
        try await waitUntilAsked(panelUp)
        other.mergeAllWindows(nil)
        XCTAssertEqual(a.ws.tabs.count, 2, "面板开着，不能把它的标签搬走")
        XCTAssertEqual(other.tabs.count, 1)

        panelUp.reply?(false)
        other.mergeAllWindows(nil)
        XCTAssertEqual(other.tabs.count, 3, "问完了就能合并")
    }

    // MARK: 关后台标签：选中不动（点 ×、中键、右键菜单都走 closeTab）

    func testClosingABackgroundTabKeepsTheSelection() {
        let (ws, a) = makeWorkspace()
        let b = untitled(), c = untitled()
        ws.addTab(b, ephemeral: false)
        ws.addTab(c, ephemeral: false)
        let currentTab = ws.tab(for: a)!
        ws.select(currentTab)
        ws.closeTab(ws.tab(for: c)!)
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertTrue(ws.current === currentTab, "关的是后台标签，选中不动（以前跳到被关标签的邻居）")
        XCTAssertTrue(ws.document === a)
    }

    func testClosingAnEditedBackgroundTabSavesItAndKeepsTheSelection() async throws {
        let a = try await openFile("a.md")
        _ = try await openFile("b.md", in: a.ws)
        let c = try await openFile("c.md", in: a.ws)
        c.doc.replaceContents("# edited c\n")
        let currentTab = try XCTUnwrap(a.ws.tab(for: a.doc))
        a.ws.select(currentTab)
        let closing = try XCTUnwrap(a.ws.tab(for: c.doc))
        try await failingOnDeadlock {
            a.ws.closeTab(closing)
            while a.ws.tabs.count > 2 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(a.ws.current === currentTab)
        XCTAssertFalse(isOpen(c.doc))
        XCTAssertEqual(try disk(c.url), "# edited c\n")
    }

    /// 要问的后台标签：问的时候切过去（面板要挂在它上面），答完回到原来的标签；取消也回去
    func testAskingAboutABackgroundTabShowsItThenGoesBack() async throws {
        let (ws, a) = makeWorkspace()
        let asked = scripted(in: ws, .later)
        _ = scripted(in: ws)
        let currentTab = ws.tab(for: a)!
        ws.select(currentTab)
        ws.closeTab(ws.tab(for: asked)!)
        try await waitUntilAsked(asked)
        XCTAssertTrue(ws.current.document === asked, "面板挂在要关的标签上")
        asked.reply?(false)
        XCTAssertEqual(ws.tabs.count, 3)
        XCTAssertTrue(ws.current === currentTab, "取消：回到原来的标签")

        asked.reply = nil
        asked.answer = .yes
        ws.closeTab(ws.tab(for: asked)!)
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertFalse(isOpen(asked))
        XCTAssertTrue(ws.current === currentTab, "同意：同样回到原来的标签")
    }

    // MARK: 恢复途中关窗口

    private func withSavedWorkspaces(_ list: [WorkspaceState.Workspace], _ body: () async throws -> Void) async throws {
        let d = UserDefaults.standard
        d.set(try JSONEncoder().encode(list), forKey: "workspaces.restore")
        d.set(true, forKey: "NSQuitAlwaysKeepsWindows")   // 用户把"退出时关闭窗口"打开的机器上也要恢复
        defer { d.removeObject(forKey: "workspaces.restore"); d.removeObject(forKey: "NSQuitAlwaysKeepsWindows") }
        try await body()
    }

    /// 恢复是一个标签一个标签异步开的，第一个标签一开窗口就出来了，这时用户可以关它。
    /// 以前后面的标签还往这个窗口里加：它自己又显示出来，再关的时候也不问了
    func testWindowClosedDuringRestoreStaysClosed() async throws {
        let names = (0..<40).map { "t\($0).md" }   // 够多才赶得上"恢复途中"（CI 上窗口出来得慢）；一关恢复就停手，不会真的开这么多
        for n in names { try "# \(n)\n".write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quire-next-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let next = dir.appendingPathComponent("next.md")
        try "# next\n".write(to: next, atomically: true, encoding: .utf8)
        let first = WorkspaceState.Workspace(root: tmp.path, tabs: names.map { .init(path: tmp.appendingPathComponent($0).path, ephemeral: false, mode: 0) }, current: 0, frame: "0 0 800 600", sidebarCollapsed: false)
        let second = WorkspaceState.Workspace(root: dir.path, tabs: [.init(path: next.path, ephemeral: false, mode: 0)], current: 0, frame: "0 0 800 600", sidebarCollapsed: false)
        try await withSavedWorkspaces([first, second]) {
            XCTAssertTrue(WorkspaceState.restoreIfNeeded())
            var restoring: WorkspaceWindowController?
            try await failingOnDeadlock {
                // 从文档拿：文档一开窗口控制器就建好了，orderedWindows 要等窗口真的摆上去（macOS 26 的 CI 上那时候标签已经全开完了）
                while restoring == nil { restoring = NSDocumentController.shared.documents.lazy.compactMap { ($0 as? MarkdownDocument)?.workspace }.first; await Task.yield() }
            }
            let ws = try XCTUnwrap(restoring)
            XCTAssertLessThan(ws.tabs.count, names.count, "要在恢复途中关")
            await waitForWindowClose(of: ws) { ws.window?.performClose(nil) }
            // 等下一个工作区恢复出来：说明这个工作区的步骤都走完了
            try await failingOnDeadlock {
                while !NSDocumentController.shared.documents.contains(where: { $0.fileURL?.lastPathComponent == "next.md" }) { try await Task.sleep(for: .milliseconds(20)) }
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(ws.window?.isVisible, false, "关掉的窗口不能自己再出来")
            XCTAssertEqual(NSDocumentController.shared.documents.map { $0.fileURL?.lastPathComponent }, ["next.md"], "这个窗口剩下的标签不再打开，也不留没有窗口的文档")
            XCTAssertEqual(WorkspaceWindowController.all.count, 1, "下一个工作区照常恢复")
        }
    }

    /// 读文件期间目标窗口被关掉（恢复、侧栏单击之后马上关）：不能把关掉的窗口重新显示出来，也不另开窗口
    func testFileArrivingAfterItsWorkspaceClosedDoesNotReopenIt() async throws {
        let a = try await openFile("a.md")
        await waitForWindowClose(of: a.ws) { a.ws.window?.performClose(nil) }
        _ = await open(tmp.appendingPathComponent("b.md"), in: a.ws, ephemeral: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(a.ws.window?.isVisible, false)
        XCTAssertTrue(WorkspaceWindowController.all.isEmpty)
        XCTAssertTrue(NSDocumentController.shared.documents.isEmpty, "没有窗口的文档也不留")
    }

    // MARK: 存储与撤销

    /// 脏标记靠撤销组关闭驱动，打字又合并在同一个撤销组里：存储之后接着打的字要重新标脏，否则不再自动保存、关闭时直接丢
    func testTypingAfterAutosaveMarksEditedAndIsSavedOnClose() async throws {
        let a = try await openFile("a.md")
        a.ws.setModeEditor(nil)
        let tv = try XCTUnwrap(a.ws.editorViewController.textView)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        /// 和输入法打字一样的调用；撤销组在 run loop 转一圈之后才关
        func type(_ text: String) async throws {
            tv.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(50))
        }
        try await type("one ")
        XCTAssertTrue(a.doc.isDocumentEdited)
        a.doc.autosave(withImplicitCancellability: false) { _ in }
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(try disk(a.url), "# a\n\ntext\none ")

        try await type("two")
        XCTAssertTrue(a.doc.isDocumentEdited, "存储之后接着打的字要重新标脏")
        await waitForWindowClose(of: a.ws) { a.ws.closeCurrentTab(nil) }
        XCTAssertEqual(try disk(a.url), "# a\n\ntext\none two", "关闭时写盘")
    }

    /// 撤销不走 didChangeText：文档源码要跟上屏幕，否则全选删除、⌘Z、关闭写进磁盘的是空文件
    func testUndoOfADeleteIsWhatGetsSaved() async throws {
        let a = try await openFile("a.md")
        a.ws.setModeEditor(nil)
        let tv = try XCTUnwrap(a.ws.editorViewController.textView)
        let undo = try XCTUnwrap(a.doc.undoManager)
        tv.selectAll(nil)
        tv.delete(nil)
        try await Task.sleep(for: .milliseconds(50))   // 撤销组在 run loop 转一圈之后才关
        XCTAssertEqual(a.doc.source, "")
        a.doc.autosave(withImplicitCancellability: false) { _ in }
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(try disk(a.url), "")

        undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tv.string, "# a\n\ntext\n")
        XCTAssertEqual(a.doc.source, tv.string, "撤销后文档源码要跟上")
        undo.redo()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(a.doc.source, "", "重做同样")
        undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        await waitForWindowClose(of: a.ws) { a.ws.closeCurrentTab(nil) }
        XCTAssertEqual(try disk(a.url), "# a\n\ntext\n", "写进磁盘的是屏幕上的内容")
    }

    /// 打开 a.md，在编辑模式打几个字（撤销栈上有东西），切到混合模式并激活第一块，在块里打字
    private func editInHybridAfterEditor() async throws -> (a: (doc: MarkdownDocument, ws: WorkspaceWindowController, url: URL), editor: NSTextView, hybrid: HybridTextView) {
        let a = try await openFile("a.md")
        a.ws.setModeEditor(nil)
        let tv: NSTextView = try XCTUnwrap(a.ws.editorViewController.textView)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(a.doc.undoManager?.canUndo, true)
        a.ws.setModeHybrid(nil)
        let hybrid = try XCTUnwrap(a.ws.readerViewController.textView as? HybridTextView)
        try await failingOnDeadlock { while !hybrid.activate(block: 0) { try await Task.sleep(for: .milliseconds(20)) } }
        hybrid.insertText("XYZ", replacementRange: NSRange(location: hybrid.activeRange.location + 3, length: 0))
        XCTAssertTrue(a.doc.source.contains("XYZ"))
        return (a, tv, hybrid)
    }

    /// 混合模式没有自己的撤销，⌘Z 走文档的 undoManager：不能让它改隐藏的编辑器、再把编辑器的旧文本同步回文档
    func testUndoCannotDropHybridEdits() async throws {
        let (a, _, _) = try await editInHybridAfterEditor()
        XCTAssertEqual(a.doc.undoManager?.canUndo, false, "编辑器落后于文档之后，它的撤销作废")
        a.doc.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(a.doc.source.contains("XYZ"))
        XCTAssertTrue(a.doc.source.contains("typed"))
    }

    /// 在编辑器里打一段字：撤销记录在文档的 undoManager 上，目标是这个编辑器的文本
    private func typeInEditor(_ doc: MarkdownDocument, _ text: String) async throws {
        let ws = try XCTUnwrap(doc.workspace)
        ws.select(try XCTUnwrap(ws.tab(for: doc)))
        ws.setModeEditor(nil)
        let tv: NSTextView = try XCTUnwrap(ws.editorViewController.textView)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
    }

    /// 移走之后旧编辑器没了，它留下的撤销不能再用（⌘Z 崩溃，或者文档变干净、内容没存）：文档还是脏的、内容还在，新编辑器的撤销照常
    private func assertUndoStartsOverAfterMove(_ doc: MarkdownDocument, keeps text: String) async throws {
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(doc.undoManager?.canUndo, false, "旧编辑器的撤销要作废")
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertTrue(doc.source.contains(text))
        guard doc.undoManager?.canUndo == false else { return }   // 不清就别按：会把整轮测试崩掉
        try await typeInEditor(doc, "after")
        XCTAssertEqual(doc.undoManager?.canUndo, true)
        doc.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(doc.source.contains("after"))
        XCTAssertTrue(doc.source.contains(text))
        XCTAssertTrue(doc.isDocumentEdited, "撤销的只是移动之后打的字，移动之前打的还没存")
    }

    func testUndoStartsOverAfterMovingATabToANewWindow() async throws {
        let a = try await openFile("a.md")
        _ = try await openFile("b.md", in: a.ws)
        try await typeInEditor(a.doc, "typed")
        XCTAssertEqual(a.doc.undoManager?.canUndo, true)
        a.ws.select(try XCTUnwrap(a.ws.tab(for: a.doc)))
        a.ws.moveTabToNewWindow(nil)
        XCTAssertFalse(a.doc.workspace === a.ws)
        try await assertUndoStartsOverAfterMove(a.doc, keeps: "typed")
    }

    func testUndoStartsOverAfterMergingWindows() async throws {
        let a = try await openFile("a.md")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quire-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = dir.appendingPathComponent("x.md")
        try external("# x\n", to: x)
        let opened = await open(x, in: nil, ephemeral: false)
        let docX = try XCTUnwrap(opened)
        XCTAssertFalse(docX.workspace === a.ws)
        try await typeInEditor(docX, "typed")
        XCTAssertEqual(docX.undoManager?.canUndo, true)
        a.ws.mergeAllWindows(nil)
        XCTAssertTrue(docX.workspace === a.ws)
        try await assertUndoStartsOverAfterMove(docX, keeps: "typed")
    }

    /// 块没走 onDeactivate 就被收起（主题变化等）之后切回编辑器：编辑器要跟上文档，否则接着打字会盖掉混合模式的改动
    func testEditorCatchesUpWhenHybridBlockWasDroppedWithoutCommit() async throws {
        let (a, tv, hybrid) = try await editInHybridAfterEditor()
        hybrid.setRendered(try XCTUnwrap(hybrid.rendered), style: hybrid.style)   // 主题变化时走的就是这条路
        XCTAssertNil(hybrid.activeBlock)
        a.ws.setModeEditor(nil)
        XCTAssertEqual(tv.string, a.doc.source)
        tv.insertText("more", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(a.doc.source.contains("XYZ"), "混合模式的改动不能被盖掉")
        XCTAssertTrue(a.doc.source.contains("more"))
    }

    /// 沉浸写作里关掉当前标签：换上来的标签可能还没有编辑器，退出沉浸不能碰它
    func testExitingImmersiveAfterClosingCurrentTabWithoutEditor() async throws {
        let toggle = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, #selector(NSWindow.toggleFullScreen(_:))))
        let original = method_getImplementation(toggle)
        method_setImplementation(toggle, imp_implementationWithBlock({ (_: NSWindow, _: Any?) in } as @convention(block) (NSWindow, Any?) -> Void))   // 测试里不真的进全屏
        defer { method_setImplementation(toggle, original) }
        let savedMode = UserDefaults.standard.object(forKey: "view.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "view.mode") }
        UserDefaults.standard.set(WorkspaceWindowController.Mode.reader.rawValue, forKey: "view.mode")   // 新标签没有编辑器
        let a = try await openFile("a.md")
        let b = try await openFile("b.md", in: a.ws)
        a.ws.select(try XCTUnwrap(a.ws.tab(for: a.doc)))
        a.ws.toggleImmersive(nil)
        XCTAssertTrue(a.ws.isImmersive)
        let closing = try XCTUnwrap(a.ws.tab(for: a.doc))
        try await failingOnDeadlock {
            a.ws.closeTab(closing)
            while a.ws.tabs.count > 1 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(a.ws.current.document === b.doc)
        XCTAssertFalse(a.ws.hasEditorPane)
        a.ws.toggleImmersive(nil)
        XCTAssertFalse(a.ws.isImmersive)
    }

    // MARK: 混合模式：离开块之后的重解析是异步的，这段时间里块表还是旧的

    private struct HybridDoc { let doc: MarkdownDocument; let ws: WorkspaceWindowController; let url: URL; let view: HybridTextView }

    private func openHybrid(_ text: String) async throws -> HybridDoc {
        try text.write(to: tmp.appendingPathComponent("hybrid.md"), atomically: true, encoding: .utf8)
        let a = try await openFile("hybrid.md")
        a.ws.setModeHybrid(nil)
        let view = try XCTUnwrap(a.ws.readerViewController.textView as? HybridTextView)
        try await failingOnDeadlock { while view.rendered == nil { try await Task.sleep(for: .milliseconds(10)) } }
        return HybridDoc(doc: a.doc, ws: a.ws, url: a.url, view: view)
    }

    /// 在激活块末尾（块尾换行之前）打字，走和键盘一样的路
    private func type(_ text: String, in v: HybridTextView) {
        v.setSelectedRange(NSRange(location: v.activeRange.location + v.activeRange.length - 1, length: 0))
        v.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 从提交到这里都没让出主线程，所以重渲染一定还没到；这里才等它到
    private func waitForRerender(of h: HybridDoc, containing text: String) async throws {
        try await failingOnDeadlock { while !h.doc.session.parsedSource.contains(text) { try await Task.sleep(for: .milliseconds(5)) } }
    }

    /// 块里打了字、还没离开块：导出 / 打印要有这些字（击键只更新源码，不重解析）
    func testExportAndPrintWhileABlockIsActiveHaveTheTypedText() async throws {
        let h = try await openHybrid("# T\n\nbody\n")
        XCTAssertTrue(h.view.activate(block: 1))
        type("XYZ", in: h.view)
        XCTAssertEqual(h.doc.source, "# T\n\nbodyXYZ\n")
        XCTAssertTrue(Exporter.html(for: h.doc).contains("bodyXYZ"), "HTML 导出")
        let reader = try XCTUnwrap(h.doc.readerViewController)
        let forPDF = await reader.printableView(width: 400, layout: PDFLayout.load(), document: h.doc)
        XCTAssertTrue(forPDF.string.contains("bodyXYZ"), "PDF / 打印")
        let forImage = await reader.printableView(width: 400)
        XCTAssertTrue(forImage.string.contains("bodyXYZ"), "图片")
        XCTAssertEqual(h.view.activeBlock, 1, "导出不把人从块里踢出来")
        XCTAssertEqual(h.view.activeSource, "bodyXYZ\n")
    }

    /// quire://export、快捷指令先等渲染：块里打过字时不会有新的发布，等也等不到，15 s 后报导出失败
    func testWaitingForARenderDoesNotHangWhileABlockHasEdits() async throws {
        let h = try await openHybrid("# T\n\nbody\n")
        XCTAssertTrue(h.view.activate(block: 1))
        type("XYZ", in: h.view)
        nonisolated(unsafe) var answer: Bool?
        h.doc.session.whenRendered(timeout: 0.3) { answer = $0 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(answer, true)
    }

    /// 改了块 B、点回前面的块 A：B 的重渲染还在路上，这时在 A 里加一行。
    /// 重渲染到达后这一行还在块里，下一击也不能把它从源码里抹掉（以前都丢）
    func testLineAddedBeforeTheRerenderSurvivesInAnEarlierBlock() async throws {
        let h = try await openHybrid("A\n\nB\n\nC\n")
        XCTAssertTrue(h.view.activate(block: 1))
        type("b", in: h.view)
        XCTAssertTrue(h.view.activate(block: 0))
        type("\nsecond", in: h.view)
        XCTAssertEqual(h.doc.source, "A\nsecond\n\nBb\n\nC\n")
        try await waitForRerender(of: h, containing: "Bb")
        XCTAssertEqual(h.view.activeBlock, 0)
        XCTAssertEqual(h.view.activeSource, "A\nsecond\n", "打的字还在块里")
        type("!", in: h.view)
        XCTAssertEqual(h.doc.source, "A\nsecond!\n\nBb\n\nC\n", "下一击不能把它从源码里抹掉")
    }

    /// 同上，块在改动区之后（以前行号取新块表的，缓存的区间却还是两行，下一击把第二行吃掉）
    func testLineAddedBeforeTheRerenderSurvivesInALaterBlock() async throws {
        let h = try await openHybrid("A\n\nB\n\nC\n")
        XCTAssertTrue(h.view.activate(block: 0))
        type("a", in: h.view)
        XCTAssertTrue(h.view.activate(block: 1))
        type("\nsecond", in: h.view)
        XCTAssertEqual(h.doc.source, "Aa\n\nB\nsecond\n\nC\n")
        try await waitForRerender(of: h, containing: "Aa")
        XCTAssertEqual(h.view.activeBlock, 1)
        XCTAssertEqual(h.view.activeSource, "B\nsecond\n")
        type("!", in: h.view)
        XCTAssertEqual(h.doc.source, "Aa\n\nB\nsecond!\n\nC\n")
    }

    /// 提交之后马上回到同一块接着打字：它在改动区里，以前重渲染一到就被踢出源码态，后面的字没处去，显示也停在旧的
    func testTypingInTheJustCommittedBlockBeforeItsRerenderKeepsTheBlock() async throws {
        let h = try await openHybrid("A\n\nB\n")
        XCTAssertTrue(h.view.activate(block: 0))
        type("1", in: h.view)
        h.view.deactivate(commit: true)
        XCTAssertTrue(h.view.activate(block: 0))
        type("2", in: h.view)
        try await waitForRerender(of: h, containing: "A1")
        XCTAssertEqual(h.view.activeBlock, 0, "还在块里")
        XCTAssertEqual(h.view.activeSource, "A12\n")
        type("3", in: h.view)
        XCTAssertEqual(h.doc.source, "A123\n\nB\n")
    }

    /// 回车加一个空行：块内容没变，diff 为空（走 updateRendered），只有后面的块行号变了。
    /// 重渲染到之前点到后面的块：显示的要是它自己的源码，打字要写到它自己的行上
    func testBlockActivatedAfterAnEmptyDiffCommitWritesToItsOwnLine() async throws {
        let h = try await openHybrid("A\n\nB\n")
        XCTAssertTrue(h.view.activate(block: 0))
        type("\n", in: h.view)
        XCTAssertEqual(h.doc.source, "A\n\n\nB\n")
        XCTAssertTrue(h.view.activate(block: 1))
        XCTAssertEqual(h.view.activeSource, "B\n", "块表还没换，行号要算上刚才加的行")
        type("x", in: h.view)
        XCTAssertEqual(h.doc.source, "A\n\n\nBx\n")
        try await waitForRerender(of: h, containing: "A\n\n\nB")
        XCTAssertEqual(h.view.activeBlock, 1)
        type("y", in: h.view)
        XCTAssertEqual(h.doc.source, "A\n\n\nBxy\n", "diff 为空时行号同样要对")
        h.view.deactivate(commit: true)
        XCTAssertEqual(h.doc.source, "A\n\n\nBxy\n")
    }

    /// 删掉几行再点后面的块，走真实的编辑路径（块数不变）：重渲染到之前打字不能写到别的块上（"End" 被盖掉）
    func testBlockActivatedBeforeTheRerenderOfALineDeletionWritesToItsOwnLine() async throws {
        let h = try await openHybrid("- a\n- b\n- c\n\nPara\n\nEnd\n")
        XCTAssertTrue(h.view.activate(block: 0))
        let start = h.view.activeRange.location
        h.view.insertText("- a\n", replacementRange: NSRange(location: start, length: ("- a\n- b\n- c" as NSString).length))
        XCTAssertEqual(h.doc.source, "- a\n\n\nPara\n\nEnd\n")
        XCTAssertTrue(h.view.activate(block: 1))
        XCTAssertEqual(h.view.activeSource, "Para\n")
        type("!", in: h.view)
        XCTAssertEqual(h.doc.source, "- a\n\n\nPara!\n\nEnd\n")
    }

    /// 一个块里的多行被重新激活成一行时，缓存的区间不能还盖着两行（重渲染换块表之后，回写把下一行吃掉）
    func testSplicerDoesNotReuseARegionForDifferentLines() {
        let sp = SourceLineSplicer()
        var cur = "a\nb\nc\n"
        cur = sp.replace(lines: 1...2, in: cur, with: "a\nb!\n")!.0
        XCTAssertEqual(cur, "a\nb!\nc\n")
        cur = sp.replace(lines: 1...1, in: cur, with: "A\n")!.0
        XCTAssertEqual(cur, "A\nb!\nc\n")
    }

    /// 外部修改 / quire://append 把源码整体换掉：块表要等重渲染。这段时间激活着的块、或者刚点进去的块打字，都会按旧行号写进新内容
    func testTypingBetweenAReplaceAndItsRerenderDoesNotWriteToStaleLines() async throws {
        let h = try await openHybrid("A\n\nB\n")
        XCTAssertTrue(h.view.activate(block: 1))
        let replaced = "X\nX\nX\nX\n\nA\n\nB\n"
        h.doc.replaceContents(replaced)
        h.view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(h.doc.source, replaced, "激活着的块")
        h.view.activate(block: 0)
        h.view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(h.doc.source, replaced, "刚点进去的块")
        try await waitForRerender(of: h, containing: "X\nX")
        XCTAssertTrue(h.view.activate(block: 0), "重渲染到了就能进了")
        XCTAssertEqual(h.view.activeSource, "X\nX\nX\nX\n")
    }

    /// 块没走提交就被收起（换主题的结果到了，它基于打字之前的解析）：显示要追上源码，否则一直停在旧的，直到下一次提交
    func testDisplayCatchesUpWhenABlockWithEditsIsDroppedByAFullRender() async throws {
        let h = try await openHybrid("A\n\nB\n")
        XCTAssertTrue(h.view.activate(block: 1))
        type("typed", in: h.view)
        h.view.setRendered(try XCTUnwrap(h.view.rendered), style: h.view.style)
        XCTAssertNil(h.view.activeBlock)
        try await waitForRerender(of: h, containing: "Btyped")
        XCTAssertTrue(h.view.string.contains("Btyped"))
    }

    /// 块 A 里加了一行、没离开块就把标签搬走：新窗口要有这一行，点 B 打开的要是 B 自己的源码、打的字写在 B 上。
    /// 以前搬走不提交：新窗口的阅读视图拿到的是打字之前的渲染，没跟上的行数变化留在旧视图里，B 打开的是空行
    private func assertLineAddedInABlockFollowsTheTab(_ doc: MarkdownDocument, from old: WorkspaceWindowController) async throws {
        let ws = try XCTUnwrap(doc.workspace)
        XCTAssertFalse(ws === old)
        ws.select(try XCTUnwrap(ws.tab(for: doc)))
        let view = try XCTUnwrap(ws.readerViewController.textView as? HybridTextView)
        XCTAssertEqual(doc.source, "A\nsecond\n\nB\n")
        // 重渲染还没到：块表是旧的，进得去的话也要是 B 自己的行
        if view.activate(block: 1) { XCTAssertEqual(view.activeSource, "B\n", "重渲染到之前"); view.deactivate(commit: false) }
        for _ in 0..<100 where !view.string.contains("second") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(view.string.contains("second"), "新窗口要显示加的那一行")
        XCTAssertTrue(view.activate(block: 1))
        XCTAssertEqual(view.activeSource, "B\n")
        type("!", in: view)
        XCTAssertEqual(doc.source, "A\nsecond\n\nB!\n")
    }

    func testLineAddedInABlockSurvivesMovingTheTabToANewWindow() async throws {
        let h = try await openHybrid("A\n\nB\n")
        _ = try await openFile("b.md", in: h.ws)
        h.ws.select(try XCTUnwrap(h.ws.tab(for: h.doc)))
        XCTAssertTrue(h.view.activate(block: 0))
        type("\nsecond", in: h.view)
        h.ws.moveTabToNewWindow(nil)
        try await assertLineAddedInABlockFollowsTheTab(h.doc, from: h.ws)
    }

    func testLineAddedInABlockSurvivesMergingWindows() async throws {
        let h = try await openHybrid("A\n\nB\n")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quire-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = dir.appendingPathComponent("x.md")
        try external("# x\n", to: x)
        let opened = await open(x, in: nil, ephemeral: false)
        let other = try XCTUnwrap(opened?.workspace)
        XCTAssertFalse(other === h.ws)
        XCTAssertTrue(h.view.activate(block: 0))
        type("\nsecond", in: h.view)
        other.mergeAllWindows(nil)
        try await assertLineAddedInABlockFollowsTheTab(h.doc, from: h.ws)
    }

    // MARK: 外部修改

    /// touch、Finder 标签、备份工具只动属性，监视器同样会响：内容没变就不是外部修改，不能问"已被其他程序修改，要不要丢弃改动"
    func testAttributeOnlyChangeWithUnsavedEditsIsNotAConflict() async throws {
        let a = try await openFile("a.md")
        a.doc.replaceContents("# edited a\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: a.url.path)
        a.doc.reloadFromDisk()   // 监视器响了走的就是这里
        XCTAssertNil(a.ws.window?.attachedSheet, "内容没变，不该问")
        // 修改时间也要跟上：否则 NSDocument 按自己记的时间认为文件被改了，改动存不下去
        a.doc.autosave(withImplicitCancellability: false) { _ in }
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertNil(a.ws.window?.attachedSheet, "存储也不该问")
        XCTAssertEqual(try disk(a.url), "# edited a\n")
    }

    /// 内容真的变了、又有未保存改动：不打断、不写盘、编辑器不动，只是知道有冲突；磁盘回到打开时的版本就没事了，之后照常存储
    func testExternalChangeWithUnsavedEditsWaitsForTheNextSave() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()   // 只看这里调的：监视器晚到的事件会替没写对的地方补救
        let opened = try disk(a.url)
        a.doc.replaceContents("# mine\n")
        XCTAssertEqual(a.doc.reloadFromDisk(), .unsavedEdits, "磁盘没变")
        try "# theirs\n".write(to: a.url, atomically: true, encoding: .utf8)
        XCTAssertEqual(a.doc.reloadFromDisk(), .conflict)
        XCTAssertNil(a.ws.window?.attachedSheet, "不打断")
        XCTAssertEqual(a.doc.source, "# mine\n", "编辑器不动")
        XCTAssertEqual(try disk(a.url), "# theirs\n", "不写盘")
        try opened.write(to: a.url, atomically: true, encoding: .utf8)
        XCTAssertEqual(a.doc.reloadFromDisk(), .unsavedEdits, "磁盘回到了打开时的版本")
        a.doc.autosave(withImplicitCancellability: false) { _ in }
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(try disk(a.url), "# mine\n")
    }

    /// sheet 挂上来（挂不上来由看门狗收场）
    private func visibleSheet(on ws: WorkspaceWindowController) async throws -> NSWindow {
        let window = try XCTUnwrap(ws.window)
        try await failingOnDeadlock { while window.attachedSheet?.isVisible != true { try await Task.sleep(for: .milliseconds(20)) } }
        return try XCTUnwrap(window.attachedSheet)
    }
    private func buttons(in view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) } }
    private func labels(in view: NSView) -> [String] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0.stringValue] } ?? labels(in: $0) } }

    /// 定时器到了（打字后约 15 s）走的就是这里；文件被改过就由系统问
    private func timerAutosave(_ doc: MarkdownDocument) { doc.autosave(withDelegate: nil, didAutosave: nil, contextInfo: nil) }

    /// 系统问的三个按钮，按加入的顺序（标题随语言变）；显示顺序不算数：对话框宽的时候竖排变横排
    private enum SystemAnswer: Int { case saveAnyway, revert, saveAs }
    private func answer(_ choice: SystemAnswer, on ws: WorkspaceWindowController) async throws {
        let sheet = try await visibleSheet(on: ws)
        let shown = buttons(in: try XCTUnwrap(sheet.contentView)).filter { !$0.title.isEmpty && !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(shown.count, 3, "\(shown.map(\.title))")
        try XCTUnwrap(shown.first { $0.tag == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + choice.rawValue }, "\(shown.map(\.title))").performClick(nil)
        try await failingOnDeadlock { while ws.window?.sheets.contains(sheet) == true { try await Task.sleep(for: .milliseconds(20)) } }
    }

    /// 这份内容进了历史版本（写入版本库要一点时间）
    private func waitForVersion(_ text: String, of url: URL) async throws {
        for _ in 0..<250 {
            let versions = NSFileVersion.otherVersionsOfItem(at: url) ?? []
            if versions.contains(where: { (try? String(contentsOf: $0.url, encoding: .utf8)) == text }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("历史版本里没有：\(text)")
    }

    /// 下一次存储由系统问（标题换成发生了什么）。选"仍要保存"：磁盘是我的，对方那版进历史版本——这个会话已经自动保存过也一样（只同步修改时间的话它就丢了）。问过就结束，之后照常存储
    func testSaveAnywayKeepsTheOtherVersion() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        a.doc.replaceContents("# first\n")
        a.doc.autosave(withImplicitCancellability: false) { _ in }
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        a.doc.replaceContents("# mine\n")
        try "# theirs\n".write(to: a.url, atomically: true, encoding: .utf8)
        XCTAssertEqual(a.doc.reloadFromDisk(), .conflict)
        timerAutosave(a.doc)
        let sheet = try await visibleSheet(on: a.ws)
        XCTAssertTrue(labels(in: try XCTUnwrap(sheet.contentView)).contains(String(format: L("“%@”已被其他程序修改"), "a.md")))
        try await answer(.saveAnyway, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(try disk(a.url), "# mine\n")
        try await waitForVersion("# theirs\n", of: a.url)
        a.doc.replaceContents("# mine again\n")
        a.doc.autosave(withImplicitCancellability: false) { _ in }
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(try disk(a.url), "# mine again\n")
    }

    /// 选"复原"：载入点按钮这一刻磁盘上的版本（询问开着时外部可能又改回去了，git stash 再 pop），我的改动进历史版本，撤销栈清空，之后照常存储
    func testRevertLoadsTheVersionOnDiskNowAndKeepsMine() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        let opened = try disk(a.url)
        a.doc.replaceContents("# mine\n")
        try "# stashed\n".write(to: a.url, atomically: true, encoding: .utf8)
        timerAutosave(a.doc)
        _ = try await visibleSheet(on: a.ws)
        try opened.write(to: a.url, atomically: true, encoding: .utf8)
        a.doc.reloadFromDisk()
        try await answer(.revert, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(a.doc.source, opened)
        try await waitForVersion("# mine\n", of: a.url)
        XCTAssertFalse(try XCTUnwrap(a.doc.undoManager).canUndo)
        a.doc.replaceContents(opened + "typed\n")
        a.doc.autosave(withImplicitCancellability: false) { _ in }
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(try disk(a.url), opened + "typed\n")
    }

    /// 询问开着时磁盘又变了：不叠第二个 sheet。"仍要保存"留下的是最新的那版，"复原"载入的也是最新的
    func testFurtherExternalChangeWhileAsking() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        func external(_ text: String) throws {
            try text.write(to: a.url, atomically: true, encoding: .utf8)
            XCTAssertEqual(a.doc.reloadFromDisk(), .conflict)
        }
        a.doc.replaceContents("# mine\n")
        try external("# one\n")
        timerAutosave(a.doc)
        _ = try await visibleSheet(on: a.ws)
        try external("# two\n")
        timerAutosave(a.doc)   // 定时器又到了：排在后面
        XCTAssertEqual(a.ws.window?.sheets.count, 1)
        try await answer(.saveAnyway, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(try disk(a.url), "# mine\n")
        try await waitForVersion("# two\n", of: a.url)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(a.ws.window?.attachedSheet, "问过了，排在后面的那次自动保存没东西可存")
        a.doc.replaceContents("# mine again\n")
        try external("# three\n")
        timerAutosave(a.doc)
        _ = try await visibleSheet(on: a.ws)
        try external("# four\n")
        try await answer(.revert, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(a.doc.source, "# four\n")
        XCTAssertEqual(try disk(a.url), "# four\n")
        XCTAssertNil(a.ws.window?.attachedSheet)
    }

    /// 询问开着时定时器又到了，答完之后关闭：不能卡死
    func testClosingAfterAnsweringDoesNotHang() async throws {
        let a = try await openFile("a.md")
        a.doc.replaceContents("# mine\n")
        try "# theirs\n".write(to: a.url, atomically: true, encoding: .utf8)
        timerAutosave(a.doc)
        _ = try await visibleSheet(on: a.ws)
        timerAutosave(a.doc)
        try await Task.sleep(for: .milliseconds(200))
        try await answer(.saveAnyway, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(try disk(a.url), "# mine\n", "改动不能丢")
        let tab = try XCTUnwrap(a.ws.tab(for: a.doc))
        try await failingOnDeadlock {
            a.ws.closeTab(tab)
            while isOpen(a.doc) { try await Task.sleep(for: .milliseconds(20)) }
        }
    }

    /// 询问开着时要关闭标签、追加（quire://append、快捷指令）：都拒绝；答完之后照常
    func testCloseAndAppendAreRefusedWhileAsking() async throws {
        let a = try await openFile("a.md")
        _ = try await openFile("b.md", in: a.ws)
        let tab = try XCTUnwrap(a.ws.tab(for: a.doc))
        a.ws.select(tab)
        a.doc.replaceContents("# mine\n")
        try "# theirs\n".write(to: a.url, atomically: true, encoding: .utf8)
        timerAutosave(a.doc)
        let asking = try await visibleSheet(on: a.ws)
        try await failingOnDeadlock {
            a.ws.closeTab(tab)
            a.ws.closeOtherTabs(keeping: tab)
            XCTAssertFalse(URLScheme.appendText("x", to: a.url, external: false))
        }
        XCTAssertEqual(a.ws.window?.attachedSheet, asking)
        XCTAssertEqual(a.ws.tabs.count, 2)
        XCTAssertTrue(a.ws.current === tab)
        XCTAssertEqual(a.doc.source, "# mine\n")
        try await answer(.revert, on: a.ws)
        try await failingOnDeadlock { while a.doc.source != "# theirs\n" { try await Task.sleep(for: .milliseconds(20)) } }
        a.ws.closeTab(tab)
        try await failingOnDeadlock { while a.ws.tabs.count > 1 { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertFalse(isOpen(a.doc))
    }

    /// 询问开着时又打开了别的文件，标签切到后台：windowForSheet 还得是这个窗口，否则 AppKit 找不到 sheet，等活动队列就是真死锁。询问还能答，答的还是原来的文档
    func testAppendToABackgroundTabIsRefusedWhileAsking() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try "# theirs\n".write(to: a.url, atomically: true, encoding: .utf8)
        timerAutosave(a.doc)
        let asking = try await visibleSheet(on: a.ws)
        let b = try await openFile("b.md", in: a.ws)
        XCTAssertTrue(a.ws.current === a.ws.tab(for: b.doc))
        XCTAssertEqual(a.doc.windowForSheet, a.ws.window)
        XCTAssertEqual(a.ws.window?.attachedSheet, asking)
        try await failingOnDeadlock { XCTAssertFalse(URLScheme.appendText("x", to: a.url, external: false)) }
        XCTAssertEqual(a.doc.source, "# mine\n")
        try await answer(.revert, on: a.ws)
        try await failingOnDeadlock { while a.doc.source != "# theirs\n" { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertFalse(a.doc.isDocumentEdited)
    }

    /// 改完文件就切到别的标签，定时器到点时标签在后台：系统还是挂 sheet（不退回 app 级模态），答完文档是干净的（app 级模态那条路答完又被标成未保存，这之后就不跟磁盘了）
    func testQuestionForABackgroundTabIsASheetOnItsWindow() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try "# theirs\n".write(to: a.url, atomically: true, encoding: .utf8)
        _ = try await openFile("b.md", in: a.ws)
        timerAutosave(a.doc)
        try await answer(.saveAnyway, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(a.doc.isDocumentEdited)
        XCTAssertEqual(try disk(a.url), "# mine\n")
        try await waitForVersion("# theirs\n", of: a.url)
    }

    /// 改动撤销完了：有改动时没跟的外部修改现在要跟。这时没有存储，系统不会再来问，不跟就一直停在旧内容
    func testFollowsTheDiskOnceTheEditsAreUndone() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try "# theirs\n".write(to: a.url, atomically: true, encoding: .utf8)
        XCTAssertEqual(a.doc.reloadFromDisk(), .conflict)
        a.doc.updateChangeCount(.changeUndone)
        XCTAssertFalse(a.doc.isDocumentEdited)
        try await failingOnDeadlock { while a.doc.source != "# theirs\n" { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertNil(a.ws.window?.attachedSheet)
    }

    /// ⌘R 是用户自己要的：没有未保存改动就跟磁盘，冲突就立刻问，已经是最新就安静，做不到要有回应（返回 false = 响一声）
    func testReloadCommandAlwaysAnswers() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        XCTAssertTrue(a.doc.reloadCommand(), "已经是最新")
        try "# theirs\n".write(to: a.url, atomically: true, encoding: .utf8)
        XCTAssertTrue(a.doc.reloadCommand())
        XCTAssertEqual(a.doc.source, "# theirs\n", "没有未保存改动：跟磁盘")
        a.doc.replaceContents("# mine\n")
        XCTAssertFalse(a.doc.reloadCommand(), "磁盘没变、有未保存改动")
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(a.doc.source, "# mine\n")
        try "# theirs 2\n".write(to: a.url, atomically: true, encoding: .utf8)
        XCTAssertTrue(a.doc.reloadCommand(), "冲突：立刻问")
        for _ in 0..<250 where a.ws.window?.attachedSheet?.isVisible != true { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(a.ws.window?.attachedSheet?.isVisible, true, "不等定时器（打字后约 15 s）")
        _ = try await visibleSheet(on: a.ws)
        XCTAssertFalse(a.doc.reloadCommand(), "已经在问了")
        XCTAssertEqual(a.ws.window?.sheets.count, 1)
        try await answer(.saveAnyway, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(try disk(a.url), "# mine\n")
        // 记下的编码解不开的字节：和打开走同一个解码器，跟上（什么字节 Latin-1 都解得开，"解不开"到不了这里）
        try bytes(gbkNoteBytes).write(to: a.url)
        XCTAssertTrue(a.doc.reloadCommand())
        XCTAssertEqual(a.doc.source, gbkNote)
        try FileManager.default.removeItem(at: a.url)
        XCTAssertFalse(a.doc.reloadCommand(), "文件被删")
        XCTAssertEqual(a.doc.source, gbkNote)
    }

    /// CRLF 文件被外部改过、重新载入之后还是 CRLF：否则下次存储把整个文件的换行都改了
    func testExternalChangeKeepsCRLF() async throws {
        let url = tmp.appendingPathComponent("crlf.md")
        try "one\r\ntwo\r\n".write(to: url, atomically: true, encoding: .utf8)
        let a = try await openFile("crlf.md")
        try "one\r\ntwo\r\nthree\r\n".write(to: url, atomically: true, encoding: .utf8)
        a.doc.reloadFromDisk()
        XCTAssertEqual(a.doc.source, "one\ntwo\nthree\n")
        a.doc.replaceContents("one\ntwo\nthree\nfour\n")
        a.doc.autosave(withImplicitCancellability: false) { _ in }
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(try disk(url), "one\r\ntwo\r\nthree\r\nfour\r\n")
    }

    /// 外部改了又改回去（切分支再切回来）：每次都要跟上。比较用的字节不跟着更新的话，改回去时会被当成"没变"，文档停在中间那版，下次存储还会盖回磁盘
    func testExternalChangeAndBackIsFollowed() async throws {
        let a = try await openFile("a.md")
        func external(_ text: String) throws {
            try text.write(to: a.url, atomically: true, encoding: .utf8)
            a.doc.reloadFromDisk()
            XCTAssertEqual(a.doc.source, text)
        }
        // 打开时读到的那版
        let opened = try disk(a.url)
        try external("# theirs\n")
        try external(opened)
        // 自己写下去的那版
        a.doc.replaceContents("# mine\n")
        a.doc.autosave(withImplicitCancellability: false) { _ in }
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        try external("# theirs again\n")
        try external("# mine\n")
    }

    /// 就地改写（不是替换文件）也要看得出来：留着比较的字节不能跟着文件变。
    /// 文件要够大：14 字节以内的 Data 就存在结构体里，怎么都不会跟着变，测不出来
    func testInPlaceExternalWriteIsNoticed() async throws {
        let url = tmp.appendingPathComponent("big.md")
        let body = String(repeating: "text\n", count: 20_000)
        try body.write(to: url, atomically: true, encoding: .utf8)
        let a = try await openFile("big.md")
        // 长度不变，不截断
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("TEXT\n".utf8))
        try handle.close()
        a.doc.reloadFromDisk()
        XCTAssertTrue(a.doc.source.hasPrefix("TEXT\ntext\n"))
        // 截断后重写
        try Data(body.utf8).write(to: url)
        a.doc.reloadFromDisk()
        XCTAssertEqual(a.doc.source, body)
    }

    /// 打开之后不能留着文件映射（NSDocument 给的 Data 可能是映射）：卷卸不掉，强行卸掉后再比较字节还会崩
    func testOpeningDoesNotKeepTheFileMapped() async throws {
        func isMapped(_ url: URL) -> Bool {
            let suffix = url.pathComponents.suffix(2).joined(separator: "/")   // 映射表里是解析过符号链接的路径（/private/var/…）
            var address: UInt64 = 0
            var info = proc_regionwithpathinfo()
            let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
            while proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, address, &info, size) == size {
                let path = withUnsafeBytes(of: info.prp_vip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if path.hasSuffix(suffix) { return true }
                address = info.prp_prinfo.pri_address + info.prp_prinfo.pri_size
            }
            return false
        }
        let url = tmp.appendingPathComponent("big.md")
        try String(repeating: "text\n", count: 20_000).write(to: url, atomically: true, encoding: .utf8)
        let a = try await openFile("big.md")
        // NSDocument 自己的引用要等 autorelease 池放掉
        for _ in 0..<100 where isMapped(a.url) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(isMapped(a.url))
    }

    // MARK: 编码（字节直接写进文件，打开、打字、存储、重载都走真路径）

    private typealias Opened = (doc: MarkdownDocument, ws: WorkspaceWindowController, url: URL)
    private var gb18030: String.Encoding { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))) }
    private var gbkNote: String { "# 中文标题\n\n正文\n" }
    private var gbkNoteBytes: String { "2320d6d0cec4b1eacce20a0ad5fdcec40a" }

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var digits = Substring(hex)
        while !digits.isEmpty {
            data.append(UInt8(digits.prefix(2), radix: 16)!)
            digits = digits.dropFirst(2)
        }
        return data
    }
    private func utf16(_ text: String, bigEndian: Bool = false) -> Data {
        let bom: [UInt8] = bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]
        let order: String.Encoding = bigEndian ? .utf16BigEndian : .utf16LittleEndian
        return Data(bom) + text.data(using: order)!
    }
    private func openBytes(_ data: Data, named name: String = "encoded.md") async throws -> Opened {
        try data.write(to: tmp.appendingPathComponent(name))
        return try await openFile(name)
    }
    /// 和真实打字一样：切到编辑器，在文末 insertText，等自动保存写完（撤销组在 run loop 转一圈之后才关）
    private func typeAtEndAndAutosave(_ text: String, in a: Opened) async throws {
        a.ws.setModeEditor(nil)
        let tv = try XCTUnwrap(a.ws.editorViewController.textView)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(a.doc.isDocumentEdited)
        a.doc.autosave(withImplicitCancellability: false) { _ in }
        try await failingOnDeadlock {
            while a.doc.isDocumentEdited {
                // 系统问"文件已被修改"说明文档没跟上磁盘：报失败、答掉，不用等看门狗把整轮带崩
                if let window = a.ws.window, let sheet = window.attachedSheet, sheet.isVisible {
                    XCTFail("存储时弹了提示：文档没跟上磁盘")
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    /// 无 BOM 的字节不能当 UTF-16：奇数长度的短文会丢最后一个字节，打一个字、自动保存，文件就变成 fffe2023d0d6…（加 BOM、字节序反过来）
    func testGBKNotesOpenAsGB18030AndKeepTheirBytes() async throws {
        let long = String(repeating: "这是一段比较长的中文笔记，用来确认长文件也走同一条路。\n", count: 50)
        var samples: [(String, Data)] = [
            (gbkNote, bytes(gbkNoteBytes)),   // 奇数长度
            ("# 中文\n\n", bytes("2320d6d0cec40a0a")),   // 偶数长度
            (long, long.data(using: gb18030)!),
        ]
        // 只要有一个常用字、中文标点或假名，或者四字节序列，就算 GB18030
        for text in ["中\n", "繁體中文\n", "「，」\n", "あいう\n", "😀 note\n"] { samples.append((text, text.data(using: gb18030)!)) }
        for (i, (text, data)) in samples.enumerated() {
            let a = try await openBytes(data, named: "gbk\(i).md")
            XCTAssertEqual(a.doc.source, text)
            XCTAssertEqual(a.doc.encoding, gb18030)
            try await typeAtEndAndAutosave("x", in: a)
            XCTAssertEqual(try Data(contentsOf: a.url), data + Data("x".utf8), "只多了打的那个字")
            let again = try await openBytes(try Data(contentsOf: a.url), named: "gbk\(i)-again.md")
            XCTAssertEqual(again.doc.source, text + "x", "存完再打开还是对的")
        }
    }

    func testLatin1FilesOpenAsLatin1AndKeepTheirBytes() async throws {
        let samples = [
            "café au lait\n", "Le café est à côté de la gare.\n", "¿Qué día es hoy? Está aquí.\n", "O pão é bom e está aqui.\n",
            // 下面这些字节同时也是合法的 GB18030（重音字母后面跟字母）：只看"解得开"会变成 Se駉r 这样的乱码
            "Señor Núñez\n", "Größe\n", "économie\n", "A informação\n", "Éric\n", "Österreich\n", "«Été»\n",
            String(repeating: "Der Bäcker öffnet früh, über der Tür hängt ein Schild.\n", count: 40),
        ]
        for (i, text) in samples.enumerated() {
            let data = text.data(using: .isoLatin1)!
            let a = try await openBytes(data, named: "latin\(i).md")
            XCTAssertEqual(a.doc.source, text)
            XCTAssertEqual(a.doc.encoding, .isoLatin1)
            try await typeAtEndAndAutosave("x", in: a)
            XCTAssertEqual(try Data(contentsOf: a.url), data + Data("x".utf8), "只多了打的那个字")
        }
    }

    /// Latin-1 装不下新打的字：整个文件改存 UTF-8，一个字不丢，之后也按 UTF-8
    func testLatin1FileSwitchesToUTF8WhenTypedTextDoesNotFit() async throws {
        let a = try await openBytes("café au lait\n".data(using: .isoLatin1)!)
        a.doc.session.stopWatching()
        try await typeAtEndAndAutosave("中", in: a)
        XCTAssertEqual(a.doc.encoding, .utf8)
        XCTAssertEqual(try disk(a.url), "café au lait\n中")
        a.doc.reloadFromDisk()
        XCTAssertEqual(a.doc.source, "café au lait\n中")
    }

    func testUTF16WithBOMOpensAndStaysUTF16() async throws {
        let text = "# 标题 😀\n\nbody\n"
        for (name, bigEndian) in [("le.md", false), ("be.md", true)] {
            let a = try await openBytes(utf16(text, bigEndian: bigEndian), named: name)
            XCTAssertEqual(a.doc.source, text, name)
            XCTAssertEqual(a.doc.encoding, .utf16, name)
            try await typeAtEndAndAutosave("x", in: a)
            let saved = try Data(contentsOf: a.url)
            XCTAssertTrue(saved.starts(with: [0xFF, 0xFE]) || saved.starts(with: [0xFE, 0xFF]), "\(name)：存完还有 BOM，下次才认得出")
            XCTAssertEqual(String(data: saved, encoding: .utf16), text + "x", name)
        }
    }

    /// BOM 后面不是完整的 UTF-16（奇数长度、孤立代理项）：不能照 UTF-16 解，那样最后一个字节存一次就没了
    func testBrokenUTF16AfterBOMKeepsEveryByte() async throws {
        let samples = [("odd", bytes("fffe2300200061000a")), ("lone-surrogate", bytes("fffe230000d820006100")), ("odd-be", bytes("feff002300200a"))]
        for (name, data) in samples {
            let a = try await openBytes(data, named: "\(name).md")
            XCTAssertNotEqual(a.doc.encoding, .utf16, name)
            try await typeAtEndAndAutosave("x", in: a)
            XCTAssertEqual(try Data(contentsOf: a.url), data + Data("x".utf8), name)
        }
    }

    /// 猜错编码时显示是乱码，但文件不能被毁：无 BOM 的 UTF-16 不再被猜（也就不再加 BOM、反转字节序），没有常用字的 GBK 短文被当成 Latin-1 时同样字节不变
    func testBytesNobodyCanRecognizeSurviveSaving() async throws {
        let chinese = "# 中文标题\n\n正文第一段。\n", mixed = "# Notes 笔记\n\n- item 1 第一项\n", ascii = "# hello world\n"
        let samples: [(String, Data)] = [
            ("zh-le", chinese.data(using: .utf16LittleEndian)!), ("zh-be", chinese.data(using: .utf16BigEndian)!),
            ("mixed-le", mixed.data(using: .utf16LittleEndian)!), ("mixed-be", mixed.data(using: .utf16BigEndian)!),
            ("ascii-le", ascii.data(using: .utf16LittleEndian)!), ("ascii-be", ascii.data(using: .utf16BigEndian)!),
            ("gbk-rare", "這個\n".data(using: gb18030)!), ("gbk-level2", "魑魅魍魉\n".data(using: gb18030)!),
        ]
        for (name, data) in samples {
            let a = try await openBytes(data, named: "\(name).md")
            XCTAssertNotEqual(a.doc.encoding, .utf16, name)
            try await typeAtEndAndAutosave("x", in: a)
            XCTAssertEqual(try Data(contentsOf: a.url), data + Data("x".utf8), name)
        }
    }

    /// UTF-16 文档被别的工具改写成 UTF-8：以前用记下的 UTF-16 解成"⌠桥汬漠睯牬搊"，不问，打一个字就把乱码存下去
    func testExternalRewriteFromUTF16ToUTF8() async throws {
        let a = try await openBytes(utf16("# 你好\n"))
        a.doc.session.stopWatching()   // 只看这里调的：监视器晚到的事件会替没写对的地方补救
        XCTAssertEqual(a.doc.encoding, .utf16)
        try Data("# hello world\n".utf8).write(to: a.url, options: .atomic)
        a.doc.reloadFromDisk()
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(a.doc.source, "# hello world\n")
        XCTAssertEqual(a.doc.encoding, .utf8)
        try await typeAtEndAndAutosave("x", in: a)
        XCTAssertEqual(try Data(contentsOf: a.url), Data("# hello world\nx".utf8))
    }

    /// UTF-8 文档被改写成 GB18030：以前解不开就 return，干净的文档留着旧文字
    func testExternalRewriteFromUTF8ToGB18030() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        try bytes(gbkNoteBytes).write(to: a.url, options: .atomic)
        a.doc.reloadFromDisk()
        XCTAssertEqual(a.doc.source, gbkNote)
        XCTAssertEqual(a.doc.encoding, gb18030)
        try await typeAtEndAndAutosave("x", in: a)
        XCTAssertEqual(try Data(contentsOf: a.url), bytes(gbkNoteBytes) + Data("x".utf8))
    }

    /// 文字没变、只是换了编码（iconv 转过）：编码也要跟上，否则下次存储又把文件转回旧编码
    func testExternalReencodingWithSameTextIsFollowed() async throws {
        let a = try await openBytes(utf16(gbkNote))
        a.doc.session.stopWatching()
        func external(_ data: Data, is encoding: String.Encoding) throws {
            try data.write(to: a.url, options: .atomic)
            a.doc.reloadFromDisk()
            XCTAssertEqual(a.doc.source, gbkNote)
            XCTAssertEqual(a.doc.encoding, encoding)
            XCTAssertNil(a.ws.window?.attachedSheet, "文档没改过、文字也没变，没什么可问的")
        }
        try external(Data(gbkNote.utf8), is: .utf8)
        try external(bytes(gbkNoteBytes), is: gb18030)
        try external(utf16(gbkNote), is: .utf16)
        try external(Data(gbkNote.utf8), is: .utf8)
        try await typeAtEndAndAutosave("x", in: a)
        XCTAssertEqual(try disk(a.url), gbkNote + "x")
    }

    /// Windows 记事本的文件（UTF-16 + CRLF）被转成 UTF-8 + LF：换行也跟着磁盘走，不能存回 CRLF
    func testConvertingWindowsFileToUTF8LFIsFollowed() async throws {
        let a = try await openBytes(utf16("one\r\n二\r\n"))
        a.doc.session.stopWatching()
        XCTAssertEqual(a.doc.source, "one\n二\n")
        XCTAssertTrue(a.doc.usesCRLF)
        try Data("one\n二\n".utf8).write(to: a.url, options: .atomic)
        a.doc.reloadFromDisk()
        XCTAssertEqual(a.doc.encoding, .utf8)
        XCTAssertFalse(a.doc.usesCRLF)
        try await typeAtEndAndAutosave("x", in: a)
        XCTAssertEqual(try disk(a.url), "one\n二\nx")
    }

    /// 旧编码的文件被外部改了、编码没变：还是原来的编码，存储不转码
    func testExternalEditOfLegacyFileKeepsItsEncoding() async throws {
        let samples: [(String, String, String.Encoding)] = [("# 旧内容\n", gbkNote, gb18030), ("café au lait\n", "thé à la menthe\n", .isoLatin1), ("café au lait\n", "Señor Núñez\n", .isoLatin1)]
        for (i, (before, after, encoding)) in samples.enumerated() {
            let a = try await openBytes(before.data(using: encoding)!, named: "legacy\(i).md")
            a.doc.session.stopWatching()
            XCTAssertEqual(a.doc.encoding, encoding)
            try after.data(using: encoding)!.write(to: a.url, options: .atomic)
            a.doc.reloadFromDisk()
            XCTAssertEqual(a.doc.source, after)
            XCTAssertEqual(a.doc.encoding, encoding)
            try await typeAtEndAndAutosave("x", in: a)
            XCTAssertEqual(try Data(contentsOf: a.url), (after + "x").data(using: encoding)!)
        }
    }

    /// 有未保存改动时 UTF-8 文档被改写成 GB18030：是冲突，文字不动，由系统问（以前解不开就 return，连 ⌘R 都没反应）；选"复原"载入解对的文字
    func testRewriteToAnotherEncodingWithUnsavedEditsAsks() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try bytes(gbkNoteBytes).write(to: a.url, options: .atomic)
        XCTAssertEqual(a.doc.reloadFromDisk(), .conflict)
        XCTAssertEqual(a.doc.source, "# mine\n", "问之前不动")
        timerAutosave(a.doc)
        try await answer(.revert, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(a.doc.source, gbkNote)
        XCTAssertEqual(a.doc.encoding, gb18030)
        try await typeAtEndAndAutosave("x", in: a)
        XCTAssertEqual(try Data(contentsOf: a.url), bytes(gbkNoteBytes) + Data("x".utf8))
    }

    /// "复原"同样不能用记下的编码解：UTF-16 文档改写成 UTF-8 之后选它，载入的不能是乱码
    func testRevertOnUTF16DocumentDecodesTheRewrittenUTF8() async throws {
        let a = try await openBytes(utf16("# 你好\n"))
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try Data("# hello world\n".utf8).write(to: a.url, options: .atomic)
        XCTAssertEqual(a.doc.reloadFromDisk(), .conflict)
        timerAutosave(a.doc)
        try await answer(.revert, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(a.doc.source, "# hello world\n")
        XCTAssertEqual(a.doc.encoding, .utf8)
        try await typeAtEndAndAutosave("x", in: a)
        XCTAssertEqual(try Data(contentsOf: a.url), Data("# hello world\nx".utf8))
    }

    /// 询问开着时磁盘又换了编码："复原"载入的还是点按钮这一刻的版本
    func testRevertFollowsEncodingChangedWhileAsking() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try Data("# one\n".utf8).write(to: a.url, options: .atomic)
        timerAutosave(a.doc)
        _ = try await visibleSheet(on: a.ws)
        try bytes(gbkNoteBytes).write(to: a.url, options: .atomic)
        XCTAssertEqual(a.doc.reloadFromDisk(), .conflict)
        try await answer(.revert, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(a.doc.source, gbkNote)
        XCTAssertEqual(a.doc.encoding, gb18030)
        XCTAssertNil(a.ws.window?.attachedSheet)
    }

    /// 有未保存改动时磁盘换了编码：监视器反复响也不打断，文字不动；系统问一次，"仍要保存"之后两边一致，不再问（换了编码也不能变成一直问）
    func testOtherEncodingWithUnsavedEditsAsksOnce() async throws {
        let a = try await openBytes(utf16("# 你好\n"))
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try Data("# hello world\n".utf8).write(to: a.url, options: .atomic)
        XCTAssertEqual(a.doc.reloadFromDisk(), .conflict)
        XCTAssertEqual(a.doc.reloadFromDisk(), .conflict)
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(a.doc.source, "# mine\n")
        timerAutosave(a.doc)
        try await answer(.saveAnyway, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(a.doc.source, "# mine\n")
        XCTAssertEqual(a.doc.reloadFromDisk(), .current)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(a.ws.window?.attachedSheet)
    }

    // MARK: 往没打开的文件追加（quire://append、快捷指令都走 appendText；追加之后走真路径重新打开）

    /// 字节写进文件，不打开就追加，返回追加后的磁盘字节
    private func appendWithoutOpening(_ text: String, to data: Data, named name: String) throws -> Data {
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        XCTAssertNil(QuireDocumentController.shared.document(for: url), "\(name)：这里测的是没打开的文件")
        XCTAssertTrue(URLScheme.appendText(text, to: url, external: false), name)
        return try Data(contentsOf: url)
    }
    private func assertOpens(_ name: String, as text: String, encoding: String.Encoding, file: StaticString = #filePath, line: UInt = #line) async throws {
        let a = try await openFile(name)
        XCTAssertEqual(a.doc.source, text, name, file: file, line: line)
        XCTAssertEqual(a.doc.encoding, encoding, name, file: file, line: line)
    }

    /// 以前一律追加 UTF-8 字节：GBK 文件变成混合编码，下次打开整篇乱码
    func testAppendToClosedGB18030FileKeepsItsEncoding() async throws {
        let after = try appendWithoutOpening("追加", to: bytes(gbkNoteBytes), named: "newline.md")
        XCTAssertEqual(after, bytes(gbkNoteBytes + "d7b7bcd3"), "旧字节不动，新文字是 GBK")
        try await assertOpens("newline.md", as: gbkNote + "追加", encoding: gb18030)

        // 结尾没有换行：补的换行也按原编码写；四字节字符也装得下
        let noNewline = try appendWithoutOpening("😀", to: "# 中文标题".data(using: gb18030)!, named: "no-newline.md")
        XCTAssertEqual(noNewline, "# 中文标题\n😀".data(using: gb18030)!)
        try await assertOpens("no-newline.md", as: "# 中文标题\n😀", encoding: gb18030)
    }

    func testAppendToClosedLatin1FileKeepsItsEncoding() async throws {
        let data = "café au lait\n".data(using: .isoLatin1)!
        XCTAssertEqual(try appendWithoutOpening("crème", to: data, named: "newline.md"), data + bytes("6372e86d65"), "旧字节不动，新文字是 Latin-1")
        try await assertOpens("newline.md", as: "café au lait\ncrème", encoding: .isoLatin1)

        let noNewline = try appendWithoutOpening("Núñez", to: "Señor".data(using: .isoLatin1)!, named: "no-newline.md")
        XCTAssertEqual(noNewline, "Señor\nNúñez".data(using: .isoLatin1)!)
        try await assertOpens("no-newline.md", as: "Señor\nNúñez", encoding: .isoLatin1)

        // 没有常用字的短 GBK 被认成 Latin-1：追加 ASCII 时旧字节还是原样，以后还救得回来
        let rare = "這個".data(using: gb18030)!
        XCTAssertEqual(try appendWithoutOpening("x", to: rare, named: "rare.md"), rare + Data("\nx".utf8))
    }

    /// UTF-16 文件以前追加什么都会坏：字节对不齐，结尾的换行也认不出来（小端 LF 的最后一个字节是 00；大端的「上」、小端的「ਅ」最后一个字节是 0A）
    func testAppendToClosedUTF16FileKeepsBOMAndByteOrder() async throws {
        let samples: [(old: String, appended: String, expected: String, bigEndian: Bool)] = [
            ("# 标题\n", "追加 😀", "# 标题\n追加 😀", false),
            ("# 标题\n", "追加 😀", "# 标题\n追加 😀", true),
            ("# 标题", "x", "# 标题\nx", false),
            ("# 标题", "x", "# 标题\nx", true),
            ("上", "x", "上\nx", true),
            ("ਅ", "x", "ਅ\nx", false),
            ("", "x", "x", false),   // 只有 BOM
            ("", "x", "x", true),
        ]
        for (i, s) in samples.enumerated() {
            let name = "utf16-\(i).md"
            let after = try appendWithoutOpening(s.appended, to: utf16(s.old, bigEndian: s.bigEndian), named: name)
            XCTAssertEqual(after, utf16(s.expected, bigEndian: s.bigEndian), name)
            try await assertOpens(name, as: s.expected, encoding: .utf16)
        }
    }

    /// Latin-1 装不下新文字：和已打开的文档存储时一样，整个文件改存 UTF-8，一个字不丢，也不留混合编码
    func testAppendToClosedLatin1FileSwitchesToUTF8WhenTextDoesNotFit() async throws {
        for (i, text) in ["中", "€", "😀"].enumerated() {
            let name = "fit-\(i).md"
            let after = try appendWithoutOpening(text, to: "café au lait\n".data(using: .isoLatin1)!, named: name)
            XCTAssertEqual(after, Data("café au lait\n\(text)".utf8), name)
            try await assertOpens(name, as: "café au lait\n\(text)", encoding: .utf8)
        }
        // 旧内容的换行原样留着，\r\n 结尾也不再补一个
        XCTAssertEqual(try appendWithoutOpening("中", to: "café\r\n".data(using: .isoLatin1)!, named: "crlf.md"), Data("café\r\n中".utf8))

        // 已知代价，和已打开时一样：没有常用字的短 GBK 被认成 Latin-1，装不下中文，旧内容就按 Latin-1 解出来的样子存下去
        let rare = "這個\n".data(using: gb18030)!
        let latin1 = String(data: rare, encoding: .isoLatin1)!
        XCTAssertEqual(try appendWithoutOpening("中", to: rare, named: "rare.md"), Data((latin1 + "中").utf8))
    }

    /// 新文字装得下，但追加之后下次打开会被认成别的编码：照样整个文件改存 UTF-8，否则整篇乱码
    func testAppendThatWouldReadAsAnotherEncodingSwitchesToUTF8() async throws {
        // Ç Ã 的字节落在 GB18030 的常用区，整个文件又刚好都是合法的 GB18030
        let gb = try appendWithoutOpening("INFORMAÇÃO", to: "Señor\n".data(using: .isoLatin1)!, named: "gb.md")
        XCTAssertEqual(gb, Data("Señor\nINFORMAÇÃO".utf8))
        try await assertOpens("gb.md", as: "Señor\nINFORMAÇÃO", encoding: .utf8)

        // BOM 后面是奇数个字节，只能当 Latin-1；再多一个字节就成了完整的 UTF-16
        let broken = bytes("fffe2300200061000a")
        let expected = String(data: broken, encoding: .isoLatin1)! + "x"
        XCTAssertEqual(try appendWithoutOpening("x", to: broken, named: "broken.md"), Data(expected.utf8))
        try await assertOpens("broken.md", as: expected, encoding: .utf8)
    }

    /// UTF-8 文件还是只多新字节；Swift 里 "\r\n" 是一个字符，hasSuffix("\n") 不成立，不能因此多补一个换行
    func testAppendToClosedUTF8FileOnlyAddsTheNewBytes() async throws {
        let bom = bytes("efbbbf")
        let samples: [(old: Data, expected: Data)] = [
            (Data("a\n".utf8), Data("a\n中".utf8)),
            (Data("a".utf8), Data("a\n中".utf8)),
            (Data(), Data("中".utf8)),
            (Data("a\r\n".utf8), Data("a\r\n中".utf8)),
            (bom + Data("a\n".utf8), bom + Data("a\n中".utf8)),
        ]
        for (i, s) in samples.enumerated() {
            let name = "utf8-\(i).md"
            XCTAssertEqual(try appendWithoutOpening("中", to: s.old, named: name), s.expected, name)
            // BOM 留不留不归这里管，只要求和直接解一样；内存里一律 LF
            let text = try XCTUnwrap(String(data: s.expected, encoding: .utf8)).replacingOccurrences(of: "\r\n", with: "\n")
            try await assertOpens(name, as: text, encoding: .utf8)
        }
    }

    /// 同样的字节追加同样的文字，文档开着和没开着，磁盘上要一样（大端 UTF-16 例外：存储一直按本机字节序写，没打开时只追加，字节序不变）
    func testAppendGivesTheSameBytesWhetherTheFileIsOpenOrNot() async throws {
        let samples: [(old: Data, text: String)] = [
            (bytes(gbkNoteBytes), "追加"),
            ("# 中文标题".data(using: gb18030)!, "😀"),
            ("café au lait\n".data(using: .isoLatin1)!, "crème"),
            ("café au lait\n".data(using: .isoLatin1)!, "中"),
            (utf16("# 标题"), "追加"),
            (utf16("# 标题\n"), "x"),
            (Data("a".utf8), "中"),
            (Data("a\r\n".utf8), "中"),
        ]
        for (i, s) in samples.enumerated() {
            let closed = try appendWithoutOpening(s.text, to: s.old, named: "closed-\(i).md")
            let a = try await openBytes(s.old, named: "open-\(i).md")
            try await failingOnDeadlock {
                XCTAssertTrue(URLScheme.appendText(s.text, to: a.url, external: false))
                while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) }
            }
            XCTAssertEqual(closed, try Data(contentsOf: a.url), "样本 \(i)")
        }
    }

    /// 整篇改存 UTF-8 是替换整个文件：符号链接要写到真文件上（.atomic 会把链接换成普通文件，真文件不动），权限和扩展属性（Finder 标签就存在这里）都要留着
    func testSwitchingClosedFileToUTF8KeepsLinkPermissionsAndAttributes() throws {
        let fm = FileManager.default
        let real = tmp.appendingPathComponent("real.md"), link = tmp.appendingPathComponent("link.md")
        try "café\n".data(using: .isoLatin1)!.write(to: real)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        XCTAssertEqual(setxattr(real.path, "com.korako.quire.test", "tag", 3, 0, 0), 0)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertTrue(URLScheme.appendText("中", to: link, external: false))

        XCTAssertEqual(try Data(contentsOf: real), Data("café\n中".utf8), "真文件改了")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), real.path, "链接还是链接")
        XCTAssertEqual(try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(getxattr(real.path, "com.korako.quire.test", nil, 0, 0, 0), 3, "扩展属性还在")
    }

    /// 只读文件要报错，内容不变。直接调下一层：appendText 报错时弹模态窗口，测试里没人点
    func testAppendToClosedReadOnlyFileThrowsAndChangesNothing() throws {
        for (i, text) in ["x", "中"].enumerated() {
            let url = tmp.appendingPathComponent("read-only-\(i).md")
            let data = "café\n".data(using: .isoLatin1)!
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: url.path)
            XCTAssertThrowsError(try URLScheme.appendToClosedFile(text, at: url), text)
            XCTAssertEqual(try Data(contentsOf: url), data, text)
        }
    }

    // MARK: 写盘成功才算磁盘上的内容（不开窗口、没有监视器：只看这里调的 reloadFromDisk 的结论，NSDocument 的存储是真的）

    private func detached(_ name: String) throws -> (doc: ScriptedDocument, url: URL) {
        let url = tmp.appendingPathComponent(name)
        let doc = ScriptedDocument()
        doc.fileURL = url
        doc.fileType = QuireDocumentController.markdownType
        NSDocumentController.shared.addDocument(doc)
        try doc.read(from: Data(contentsOf: url), ofType: QuireDocumentController.markdownType)
        doc.fileModificationDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        return (doc, url)
    }

    /// 存一次，返回 NSDocument 给的错误（出错时回调也会到）
    private func save(_ doc: MarkdownDocument, to url: URL? = nil, _ operation: NSDocument.SaveOperationType) async throws -> NSError? {
        let target = try XCTUnwrap(url ?? doc.fileURL)
        nonisolated(unsafe) var finished = false, result: (any Error)?
        doc.save(to: target, ofType: QuireDocumentController.markdownType, for: operation) { error in
            result = error
            finished = true
        }
        try await failingOnDeadlock { while !finished { try await Task.sleep(for: .milliseconds(20)) } }
        return result as NSError?
    }

    /// 只动属性的外部事件：chmod、touch、Finder 标签、备份工具，内容都没变
    private func touch(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: url.path)
    }

    /// 文件和所在文件夹都只读：不管 NSDocument 走哪条路都写不进去（结束时还原，tearDown 才删得掉）
    private func saveWhileReadOnly(_ doc: MarkdownDocument, _ url: URL, _ operation: NSDocument.SaveOperationType) async throws -> NSError? {
        let fm = FileManager.default, dir = url.deletingLastPathComponent().path
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        return try await save(doc, operation)
    }

    /// 写盘失败，磁盘上还是旧字节。以前序列化时就记下了新字节，之后监视器一响（权限改回来也算）就问"已被其他程序修改"，选重新载入就丢了改动
    func testFailedSaveIsNotMistakenForAnExternalChange() async throws {
        for (name, operation) in [("a.md", NSDocument.SaveOperationType.autosaveInPlaceOperation), ("b.md", .saveOperation)] {
            let (doc, url) = try detached(name)
            let opened = try disk(url)
            doc.replaceContents("# mine\n")
            let error = try await saveWhileReadOnly(doc, url, operation)
            XCTAssertNotNil(error, "这个测试的前提：写不进去")
            XCTAssertEqual(try disk(url), opened)
            XCTAssertTrue(doc.isDocumentEdited)

            try touch(url)
            XCTAssertEqual(doc.reloadFromDisk(), .unsavedEdits, "\(name)：磁盘上还是打开时的字节，没有外部修改")
            XCTAssertEqual(doc.source, "# mine\n")

            // 能写了之后照常存
            let retried = try await save(doc, operation)
            XCTAssertNil(retried, "\(name)：修改时间已跟上 touch，不该再拦")
            XCTAssertEqual(try disk(url), "# mine\n")
        }
    }

    /// 写失败之后真的来了外部修改：还是要问。写失败的那份字节也不留着：外部恰好写成这样、文档又往后改过，同样是外部修改
    func testRealExternalChangeAfterFailedSaveStillAsks() async throws {
        let (doc, url) = try detached("a.md")
        doc.replaceContents("# mine\n")
        let error = try await saveWhileReadOnly(doc, url, .autosaveInPlaceOperation)
        XCTAssertNotNil(error)
        doc.replaceContents("# more\n")
        try "# mine\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(doc.reloadFromDisk(), .conflict)
        XCTAssertEqual(doc.source, "# more\n")
    }

    /// 只序列化不写盘的调用方（探针曾因此造出这个 bug 的假象）：什么都不算
    func testSerializingWithoutWritingChangesNothing() throws {
        let (doc, url) = try detached("a.md")
        doc.replaceContents("# probed\n")
        _ = try doc.data(ofType: QuireDocumentController.markdownType)
        try touch(url)
        XCTAssertEqual(doc.reloadFromDisk(), .unsavedEdits, "磁盘上还是打开时的字节")
        // 序列化出来的字节也不算"正在写的"：外部恰好写成这样、文档又往后改过，就是外部修改
        doc.replaceContents("# typed\n")
        try "# probed\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(doc.reloadFromDisk(), .conflict)
    }

    /// 写完之后也一样：写盘结束，序列化就又不留痕迹了
    func testSerializingAfterASaveChangesNothing() async throws {
        let (doc, url) = try detached("a.md")
        doc.replaceContents("# saved\n")
        let error = try await save(doc, .saveOperation)
        XCTAssertNil(error)
        doc.replaceContents("# probed\n")
        _ = try doc.data(ofType: QuireDocumentController.markdownType)
        doc.replaceContents("# typed\n")
        try "# probed\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(doc.reloadFromDisk(), .conflict)
    }

    /// 导出副本、写到自动保存目录：文档自己的文件没动，不算
    func testWritingElsewhereLeavesTheDocumentsFileAlone() async throws {
        let (doc, url) = try detached("a.md")
        doc.replaceContents("# mine\n")
        for (name, operation) in [("copy.md", NSDocument.SaveOperationType.saveToOperation), ("elsewhere.md", .autosaveElsewhereOperation)] {
            let elsewhere = tmp.appendingPathComponent(name)
            let error = try await save(doc, to: elsewhere, operation)
            XCTAssertNil(error, name)
            XCTAssertEqual(try disk(elsewhere), "# mine\n")
            XCTAssertEqual(doc.fileURL, url)
            try touch(url)
            XCTAssertEqual(doc.reloadFromDisk(), .unsavedEdits, "\(name)：文档的文件还是打开时的字节")
        }
    }

    /// 写成功了就是磁盘上的内容：接着打字、再来一个只动属性的事件，不是外部修改（自动保存、⌘S 同样）
    func testSuccessfulSaveCountsAsOnDisk() async throws {
        for (name, operation) in [("a.md", NSDocument.SaveOperationType.autosaveInPlaceOperation), ("b.md", .saveOperation)] {
            let (doc, url) = try detached(name)
            doc.replaceContents("# one\n")
            let error = try await save(doc, operation)
            XCTAssertNil(error, name)
            doc.replaceContents("# two\n")
            try touch(url)
            XCTAssertEqual(doc.reloadFromDisk(), .unsavedEdits, "\(name)：磁盘上是自己刚写的那份")
            XCTAssertEqual(doc.source, "# two\n")
        }
    }

    /// 存储为：写的时候 fileURL 还是旧的，存完才换。按"目标 == fileURL"判断的话这里记不上
    func testSaveAsCountsAsOnDisk() async throws {
        let (doc, _) = try detached("a.md")
        let other = tmp.appendingPathComponent("other.md")
        doc.replaceContents("# one\n")
        let error = try await save(doc, to: other, .saveAsOperation)
        XCTAssertNil(error)
        XCTAssertEqual(doc.fileURL?.lastPathComponent, "other.md")
        doc.replaceContents("# two\n")
        try touch(other)
        XCTAssertEqual(doc.reloadFromDisk(), .unsavedEdits)
    }

    /// 在后台线程写，写到一半停住（NSDocument 默认在主线程写，`canAsynchronouslyWrite` 打开才走这条路）
    private final class BackgroundWriteDocument: MarkdownDocument {
        nonisolated(unsafe) var wroteOffMain = false
        private let midWrite = DispatchSemaphore(value: 0)
        let finishWrite = DispatchSemaphore(value: 0)

        func hasReachedMidWrite() -> Bool { midWrite.wait(timeout: .now()) == .success }
        override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { true }
        override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL absoluteOriginalContentsURL: URL?) throws {
            try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
            wroteOffMain = !Thread.isMainThread
            midWrite.signal()
            finishWrite.wait()
        }
    }

    /// 写盘在后台进行时用户接着打字，监视器（防抖 0.15 s）也可能在记账之前响：磁盘上是正在写的那份，不是外部修改；写完之后才算数
    func testExternalCheckDuringABackgroundWrite() async throws {
        let url = tmp.appendingPathComponent("a.md")
        let doc = BackgroundWriteDocument()
        doc.fileURL = url
        doc.fileType = QuireDocumentController.markdownType
        NSDocumentController.shared.addDocument(doc)
        try doc.read(from: Data(contentsOf: url), ofType: QuireDocumentController.markdownType)

        doc.replaceContents("# one\n")
        nonisolated(unsafe) var finished = false, result: (any Error)?
        doc.save(to: url, ofType: QuireDocumentController.markdownType, for: .autosaveInPlaceOperation) { error in
            result = error
            finished = true
        }
        try await failingOnDeadlock { while !doc.hasReachedMidWrite() { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertTrue(doc.wroteOffMain, "这个测试的前提：写盘不在主线程")

        doc.replaceContents("# two\n")
        XCTAssertEqual(doc.reloadFromDisk(), .unsavedEdits, "还没写进去：磁盘上是打开时的字节")
        try "# one\n".write(to: url, atomically: true, encoding: .utf8)   // 文件已经换进去、写盘线程还没走到记账的样子
        XCTAssertEqual(doc.reloadFromDisk(), .unsavedEdits, "磁盘上是正在写的那份")

        doc.finishWrite.signal()
        try await failingOnDeadlock { while !finished { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertNil(result)
        XCTAssertEqual(try disk(url), "# one\n")
        try touch(url)
        XCTAssertEqual(doc.reloadFromDisk(), .unsavedEdits, "写完了：磁盘上是自己写的")
        XCTAssertEqual(doc.source, "# two\n", "写盘期间打的字还在")
    }

    // MARK: 符号链接文档（macOS 27 上 NSDocument 存不了符号链接路径：FileManager.replaceItem 对它报 ENOENT，裸 NSDocument 子类也一样）

    @discardableResult
    private func symlink(_ path: String, to destination: String) throws -> URL {
        let url = tmp.appendingPathComponent(path)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }

    private func isSamePath(_ a: URL?, _ b: URL) -> Bool { a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }

    /// 真实场景：侧栏点符号链接、打字、等自动保存，或者 ⌘S。写进它指向的文件，链接本身不动；之后的 touch 也不是外部修改
    func testSymlinkDocumentSavesToTheFileItPointsTo() async throws {
        let link = try symlink("link.md", to: "a.md")
        let real = tmp.appendingPathComponent("a.md")
        let a = try await openFile("link.md")
        a.doc.session.stopWatching()   // 只看这里调的：监视器晚到的事件会替没写对的地方补救
        XCTAssertTrue(isSamePath(a.doc.fileURL, real), "NSDocument 拿到的是真实文件")

        a.doc.replaceContents("# autosaved\n")
        var error = try await save(a.doc, .autosaveInPlaceOperation)
        XCTAssertNil(error, "自动保存")
        XCTAssertEqual(try disk(real), "# autosaved\n")

        a.doc.replaceContents("# saved\n")
        error = try await save(a.doc, .saveOperation)
        XCTAssertNil(error, "⌘S")
        XCTAssertEqual(try disk(real), "# saved\n")
        XCTAssertEqual(try disk(link), "# saved\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "a.md", "链接还是原来的链接")

        a.doc.replaceContents("# typing\n")
        try touch(real)
        a.doc.reloadFromDisk()
        XCTAssertNil(a.ws.window?.attachedSheet, "内容没变，不该问")
        error = try await save(a.doc, .saveOperation)
        XCTAssertNil(error, "修改时间跟的是真实文件，不该挡住存储")
        XCTAssertEqual(try disk(real), "# typing\n")
    }

    /// 外部改了链接指向的文件：比较按真实文件，系统照样问，"复原"载入的也是它
    func testExternalChangeBehindASymlinkStillAsks() async throws {
        try symlink("link.md", to: "a.md")
        let a = try await openFile("link.md")
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try "# theirs\n".write(to: tmp.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(a.doc.reloadFromDisk(), .conflict)
        timerAutosave(a.doc)
        try await answer(.revert, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(a.doc.source, "# theirs\n")
    }

    /// 界面还是用户点的那个：链接指向根外时，侧栏不能跳到那个文件夹，也不另开窗口
    func testSymlinkToAFileOutsideTheRootStaysInTheWorkspace() async throws {
        let fm = FileManager.default
        let root = tmp.appendingPathComponent("root"), outside = tmp.appendingPathComponent("outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let real = outside.appendingPathComponent("real.md")
        try "# real\n".write(to: real, atomically: true, encoding: .utf8)
        let link = try symlink("root/link.md", to: "../outside/real.md")

        let (ws, _) = makeWorkspace(root: root)
        XCTAssertTrue(ws.contains(link))
        let opened = await open(link, in: ws, ephemeral: false)   // 侧栏点文件走的就是这里
        let doc = try XCTUnwrap(opened)
        XCTAssertTrue(doc.workspace === ws, "链接在根内：进这个工作区")
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertTrue(isSamePath(doc.fileURL, real))
        XCTAssertEqual(ws.tab(for: doc)?.title, "link", "标签和侧栏同名")
        XCTAssertEqual(ws.rootURL?.standardizedFileURL, root.standardizedFileURL, "侧栏不跳")
        XCTAssertEqual(ws.sidebarViewController.currentURL?.standardizedFileURL, link.standardizedFileURL, "侧栏的当前项是点的那个")

        // 切走再切回来也一样
        ws.select(ws.tabs[0])
        ws.select(try XCTUnwrap(ws.tab(for: doc)))
        XCTAssertEqual(ws.rootURL?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(ws.sidebarViewController.currentURL?.standardizedFileURL, link.standardizedFileURL)
    }

    /// 没指定去向（⌘O、拖放、wikilink、quire://）：去向按链接的位置判断，不按它指向哪
    func testUntargetedOpenOfASymlinkFollowsTheLinksLocation() async throws {
        let fm = FileManager.default
        let root = tmp.appendingPathComponent("root"), outside = tmp.appendingPathComponent("outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "# real\n".write(to: outside.appendingPathComponent("real.md"), atomically: true, encoding: .utf8)
        let link = try symlink("root/link.md", to: "../outside/real.md")
        let (ws, _) = makeWorkspace(root: root)
        ws.showWindow(nil)   // 没指定去向时按屏幕上的工作区判断

        var result: NSDocument?
        let done = expectation(description: "open")
        NSDocumentController.shared.openDocument(withContentsOf: link, display: true) { doc, _, _ in
            result = doc
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertTrue((result as? MarkdownDocument)?.workspace === ws)
    }

    /// 不在任何工作区的根内：另开窗口，根是链接所在的文件夹（和普通文件一样），不是它指向的文件夹
    func testSymlinkOutsideEveryWorkspaceOpensAtTheLinksFolder() async throws {
        let fm = FileManager.default
        let folder = tmp.appendingPathComponent("folder"), outside = tmp.appendingPathComponent("outside")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "# real\n".write(to: outside.appendingPathComponent("real.md"), atomically: true, encoding: .utf8)
        let link = try symlink("folder/link.md", to: "../outside/real.md")
        let opened = await open(link, in: nil, ephemeral: false)
        let ws = try XCTUnwrap(opened?.workspace)
        XCTAssertEqual(ws.rootURL?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(ws.sidebarViewController.currentURL?.standardizedFileURL, link.standardizedFileURL)
        XCTAssertFalse(SidebarSettings.recentRoots.contains { $0.standardizedFileURL == outside.standardizedFileURL }, "它指向的文件夹没开过，不进最近目录")
    }

    /// 侧栏点进链接、再点别的文件（临时标签被替换，文档关了）、后退：还是经链接回来，留在这个工作区
    func testGoingBackReturnsThroughTheLink() async throws {
        let fm = FileManager.default
        let root = tmp.appendingPathComponent("root"), outside = tmp.appendingPathComponent("outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "# real\n".write(to: outside.appendingPathComponent("real.md"), atomically: true, encoding: .utf8)
        let other = root.appendingPathComponent("other.md")
        try "# other\n".write(to: other, atomically: true, encoding: .utf8)
        let link = try symlink("root/link.md", to: "../outside/real.md")
        let (ws, _) = makeWorkspace(root: root)
        ws.showWindow(nil)   // 没指定去向时按屏幕上的工作区判断

        func current(is name: String, after action: () -> Void) async throws {
            action()
            for _ in 0..<250 where ws.current.title != name { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(ws.current.title, name)
        }
        try await current(is: "link") { ws.sidebarViewController.onOpenFile?(link, nil, false) }
        try await current(is: "other") { ws.sidebarViewController.onOpenFile?(other, nil, false) }
        XCTAssertEqual(ws.tabs.count, 2, "临时标签被替换")
        try await current(is: "link") { ws.navigateBack(nil) }
        XCTAssertEqual(ws.rootURL?.standardizedFileURL, root.standardizedFileURL, "侧栏不跳")
        XCTAssertEqual(ws.sidebarViewController.currentURL?.standardizedFileURL, link.standardizedFileURL)
        // 前进、关掉链接的标签、再后退：前进时记下的也是链接
        try await current(is: "other") { ws.navigateForward(nil) }
        let linkTab = try XCTUnwrap(ws.tabs.first { $0.title == "link" })
        ws.closeTab(linkTab)
        for _ in 0..<250 where ws.tabs.contains(where: { $0 === linkTab }) { try await Task.sleep(for: .milliseconds(20)) }
        try await current(is: "link") { ws.navigateBack(nil) }
        XCTAssertEqual(ws.rootURL?.standardizedFileURL, root.standardizedFileURL)
    }

    /// 链接指向扩展名不是 md 的文件：写进去，文件不改名（NSDocument 就地存储时会把扩展名不对的文件改名，链接就断了）
    func testSymlinkTargetKeepsItsNameWhateverItsExtension() async throws {
        for destination in ["NOTES", "notes.dat", "plain.txt", "other.mdown"] {
            let real = tmp.appendingPathComponent(destination)
            try "# real\n".write(to: real, atomically: true, encoding: .utf8)
            let link = try symlink("\(destination)-link.md", to: destination)
            let a = try await openFile("\(destination)-link.md")
            a.doc.session.stopWatching()

            a.doc.replaceContents("# autosaved\n")
            let autosaveError = try await autosave(a.doc)
            XCTAssertNil(autosaveError, destination)
            XCTAssertTrue(isSamePath(a.doc.fileURL, real), "\(destination)：没改名")
            XCTAssertEqual(try? disk(real), "# autosaved\n", destination)

            a.doc.replaceContents("# saved\n")
            let error = try await save(a.doc, .saveOperation)
            XCTAssertNil(error, destination)
            XCTAssertEqual(try? disk(real), "# saved\n", destination)
            XCTAssertEqual(try? disk(link), "# saved\n", "\(destination)：链接没断")
            XCTAssertTrue(isSamePath(a.doc.fileURL, real), destination)
            XCTAssertEqual(a.doc.fileNameExtension(forType: QuireDocumentController.markdownType, saveOperation: .saveAsOperation), "md", "存储为面板的默认扩展名不变")
        }
    }

    /// 定时器走的那条自动保存（改名发生在这里和 ⌘S 里，`save(to:)` 的目标是调用方给的，不会改名）
    private func autosave(_ doc: MarkdownDocument) async throws -> (any Error)? {
        nonisolated(unsafe) var finished = false, result: (any Error)?
        doc.autosave(withImplicitCancellability: false) { error in
            result = error
            finished = true
        }
        try await failingOnDeadlock { while !finished { try await Task.sleep(for: .milliseconds(20)) } }
        return result
    }

    /// ⌘S 走的那条路，等它写完
    private func commandS(_ doc: MarkdownDocument) async throws {
        doc.save(nil)
        try await failingOnDeadlock { while doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
    }

    /// 文件叫什么，存完还叫什么：自动保存和 ⌘S 分开走（第一次存储就会改名，一次只能看一条路），文件夹里不多不少
    private func assertSavingKeepsName(_ name: String, beside neighbour: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws {
        let fm = FileManager.default
        for operation in ["autosave", "save"] {
            let folder = tmp.appendingPathComponent(operation + "-" + UUID().uuidString)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try "# original\n".write(to: url, atomically: true, encoding: .utf8)
            if let neighbour { try "# neighbour\n".write(to: folder.appendingPathComponent(neighbour), atomically: true, encoding: .utf8) }
            let opened = await open(url, in: nil, ephemeral: false)
            let doc = try XCTUnwrap(opened, name, file: file, line: line)
            doc.session.stopWatching()

            doc.replaceContents("# changed\n")
            if operation == "autosave" {
                let error = try await autosave(doc)
                XCTAssertNil(error, "\(name) \(operation)", file: file, line: line)
            } else {
                try await commandS(doc)
            }
            XCTAssertEqual(doc.fileURL?.lastPathComponent, name, operation, file: file, line: line)
            // y~.md 是 NSDocument 自动保存时的临时备份，什么时候删不归我们管
            let files = try fm.contentsOfDirectory(atPath: folder.path).filter { !$0.contains("~") }.sorted()
            XCTAssertEqual(files, ([name] + [neighbour].compactMap { $0 }).sorted(), "\(name) \(operation)", file: file, line: line)
            XCTAssertEqual(try? disk(url), "# changed\n", "\(name) \(operation)", file: file, line: line)
            if let neighbour { XCTAssertEqual(try? disk(folder.appendingPathComponent(neighbour)), "# neighbour\n", "\(name) \(operation)", file: file, line: line) }
            XCTAssertFalse(doc.isDocumentEdited, "\(name) \(operation)", file: file, line: line)
            doc.close()
        }
    }

    /// 系统的 Markdown 类型只认 md 和 markdown：NSDocument 就地存储时会把别的扩展名改名成 `fileNameExtension` 给的（y.txt 第一次自动保存就成了 y.md）
    func testSavingKeepsTheNameOfEveryMarkdownExtension() async throws {
        for ext in QuireDocumentController.markdownExtensions.sorted() {
            try await assertSavingKeepsName("y." + ext)
        }
        try await assertSavingKeepsName("README.MD")
        try await assertSavingKeepsName("y.TXT")
        try await assertSavingKeepsName("release.notes.txt")
        try await assertSavingKeepsName("读 我.mkd")
    }

    /// 设置里加的扩展名（.qmd、.mdx）：加它就是为了编辑这种文件，存一次变成 .md 就全白加了
    func testSavingKeepsTheNameOfAnExtraExtension() async throws {
        let extras = Preferences.shared.sidebarExtraExtensions
        defer { Preferences.shared.sidebarExtraExtensions = extras }
        Preferences.shared.sidebarExtraExtensions = "qmd"
        try await assertSavingKeepsName("y.qmd")
    }

    /// 没有 Markdown 扩展名的文件也能打开（`open -a`、拖到程序坞）
    func testSavingKeepsTheNameOfAFileWithoutAMarkdownExtension() async throws {
        for name in ["NOTES", "notes.dat", "v1.2", ".notes", "y.", "data.json"] {
            try await assertSavingKeepsName(name)
        }
    }

    /// y.txt 旁边已经有 y.md：以前改名撞车，自动保存一直静默失败（改动只在内存里），⌘S 报"已存在同名文件"
    func testSavingWritesTheFileItselfWhenItsMdNamesakeExists() async throws {
        try await assertSavingKeepsName("y.txt", beside: "y.md")
        try await assertSavingKeepsName("NOTES", beside: "NOTES.md")
    }

    /// 数后台线程读了几次 windowControllers。后台那次只记数、返回空：这里不撞崩溃，只看读没读
    private final class WindowControllersReadDocument: MarkdownDocument {
        private let lock = NSLock()
        nonisolated(unsafe) private var reads = 0, invalidations = 0
        var offMainReads: Int { lock.withLock { reads } }
        var offMainInvalidations: Int { lock.withLock { invalidations } }

        nonisolated override var windowControllers: [NSWindowController] {
            guard Thread.isMainThread else { lock.withLock { reads += 1 }; return [] }
            return MainActor.assumeIsolated { super.windowControllers }
        }
        nonisolated override func invalidateRestorableState() {
            super.invalidateRestorableState()
            if !Thread.isMainThread { lock.withLock { invalidations += 1 } }
        }
    }

    /// NSDocument 存完之后在后台线程保留旧版本，最后调 invalidateRestorableState，默认实现读 windowControllers 不加锁：
    /// 主线程同时摘窗口控制器（切标签、关闭）就 NSRangeException，整个进程崩掉。撞上全凭运气，后台线程读没读是必现的
    func testSavingDoesNotReadWindowControllersOffTheMainThread() async throws {
        let url = tmp.appendingPathComponent("a.md")
        let doc = WindowControllersReadDocument()
        doc.fileURL = url
        doc.fileType = QuireDocumentController.markdownType
        NSDocumentController.shared.addDocument(doc)
        try doc.read(from: Data(contentsOf: url), ofType: QuireDocumentController.markdownType)
        doc.fileModificationDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        doc.replaceContents("# changed\n")
        let error = try await save(doc, .saveOperation)
        XCTAssertNil(error)
        // 版本是在存储回调前后才在后台保留的，要等它走完
        let deadline = Date().addingTimeInterval(10)
        while doc.offMainInvalidations == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(doc.offMainInvalidations, 0, "系统不再从后台调 invalidateRestorableState：这个测试测不到东西了，连同 MarkdownDocument 里的 override 一起重新看")
        XCTAssertEqual(doc.offMainReads, 0)
    }

    /// 存储为 .txt 之后也一样：扩展名是用户刚选的
    func testSavedAsAnotherExtensionStaysThatWay() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        let target = tmp.appendingPathComponent("renamed.txt")
        let error = try await save(a.doc, to: target, .saveAsOperation)
        XCTAssertNil(error)
        a.doc.replaceContents("# changed\n")
        let autosaveError = try await autosave(a.doc)
        XCTAssertNil(autosaveError)
        XCTAssertEqual(a.doc.fileURL?.lastPathComponent, "renamed.txt")
        XCTAssertEqual(try? disk(target), "# changed\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("renamed.md").path))
    }

    /// 只有就地存储保留原名。新文档、存储为、导出没有"原来的名字"，默认还是 md
    func testOnlySavingInPlaceKeepsTheExtension() async throws {
        let type = QuireDocumentController.markdownType
        let a = try await openFile("a.md")
        try "# t\n".write(to: tmp.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        let y = try await openFile("y.txt", in: a.ws)
        for operation: NSDocument.SaveOperationType in [.saveOperation, .autosaveInPlaceOperation] {
            XCTAssertEqual(y.doc.fileNameExtension(forType: type, saveOperation: operation), "txt")
        }
        for operation: NSDocument.SaveOperationType in [.saveAsOperation, .saveToOperation, .autosaveElsewhereOperation, .autosaveAsOperation] {
            XCTAssertEqual(y.doc.fileNameExtension(forType: type, saveOperation: operation), "md")
        }
        let new = untitled()
        for operation: NSDocument.SaveOperationType in [.saveOperation, .autosaveInPlaceOperation, .saveAsOperation, .saveToOperation, .autosaveElsewhereOperation, .autosaveAsOperation] {
            XCTAssertEqual(new.fileNameExtension(forType: type, saveOperation: operation), "md")
        }
    }

    /// 链接和它指向的文件是同一份文档：两份各改各的会互相覆盖。相对、绝对、链接的链接都一样
    func testSymlinkAndItsTargetAreOneDocument() async throws {
        let link = try symlink("link.md", to: "a.md")
        let viaLink = try await openFile("link.md")
        let direct = try await openFile("a.md", in: viaLink.ws)
        XCTAssertTrue(direct.doc === viaLink.doc)
        XCTAssertEqual(viaLink.ws.tabs.count, 1)
        let b = try await openFile("b.md", in: viaLink.ws)
        XCTAssertTrue(viaLink.ws.current.document === b.doc)
        let again = await open(link, in: viaLink.ws, ephemeral: false)
        XCTAssertTrue(again === viaLink.doc)
        XCTAssertTrue(viaLink.ws.current.document === viaLink.doc, "切到已有的标签")
        viaLink.ws.select(try XCTUnwrap(viaLink.ws.tab(for: b.doc)))
        let absolute = try symlink("absolute.md", to: tmp.appendingPathComponent("a.md").path)
        let chained = try symlink("chained.md", to: "link.md")
        for other in [absolute, chained] {
            let opened = await open(other, in: viaLink.ws, ephemeral: false)
            XCTAssertTrue(opened === viaLink.doc, other.lastPathComponent)
        }
        XCTAssertEqual(viaLink.ws.tabs.count, 2)
    }

    /// quire://append 给的是链接路径：要找到开着的文档，而不是绕过它直接改文件
    func testAppendThroughASymlinkGoesToTheOpenDocument() async throws {
        let link = try symlink("link.md", to: "a.md")
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        XCTAssertTrue(URLScheme.appendText("appended", to: link, external: false))
        XCTAssertTrue(a.doc.source.hasSuffix("appended"), "开着的文档跟上")
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertTrue(try disk(tmp.appendingPathComponent("a.md")).hasSuffix("appended"))
    }

    /// 文档不再是这个链接指向的文件（存储为、链接被删或改指向）：界面回到真实路径，不留过期的名字
    func testNameFollowsTheFileOnceTheLinkNoLongerPointsToIt() async throws {
        let link = try symlink("link.md", to: "a.md")
        let a = try await openFile("link.md")
        a.doc.session.stopWatching()
        let tab = try XCTUnwrap(a.ws.tab(for: a.doc))
        XCTAssertEqual(tab.title, "link")

        try FileManager.default.removeItem(at: link)
        try symlink("link.md", to: "b.md")
        XCTAssertEqual(tab.title, "a", "链接改指向别的文件")
        try FileManager.default.removeItem(at: link)
        try symlink("link.md", to: "a.md")
        XCTAssertEqual(tab.title, "link")

        let other = tmp.appendingPathComponent("other.md")
        let error = try await save(a.doc, to: other, .saveAsOperation)
        XCTAssertNil(error)
        XCTAssertEqual(tab.title, "other", "存储为之后是新文件")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "a.md", "链接和原文件不受影响")
    }

    /// 下次启动恢复的也是用户点的那个路径：否则链接指向根外时，恢复一次侧栏就跳走了
    func testWorkspaceStateRemembersTheLink() async throws {
        let key = "workspaces.restore"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let link = try symlink("link.md", to: "a.md")
        _ = try await openFile("link.md")
        WorkspaceState.save()
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: key))
        let workspaces = try JSONDecoder().decode([WorkspaceState.Workspace].self, from: data)
        XCTAssertEqual(workspaces.first?.tabs.first?.path, link.path)
    }

    /// 符号链接目录里的文件照常：目录部分不影响存储，路径也还要在工作区根下（`contains`、标签名都靠它）
    func testFileInsideASymlinkedFolderKeepsItsPath() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "# x\n".write(to: tmp.appendingPathComponent("sub/x.md"), atomically: true, encoding: .utf8)
        try symlink("folder", to: "sub")
        let url = tmp.appendingPathComponent("folder/x.md")
        let opened = await open(url, in: nil, ephemeral: false)
        let doc = try XCTUnwrap(opened)
        doc.session.stopWatching()
        XCTAssertEqual(doc.fileURL?.path, url.path)
        doc.replaceContents("# edited\n")
        let error = try await save(doc, .saveOperation)
        XCTAssertNil(error)
        XCTAssertEqual(try disk(tmp.appendingPathComponent("sub/x.md")), "# edited\n")
    }

    /// 坏链接（指向不存在的文件、绕成环）：打开要报错，不能挂住或开出一份空文档
    func testBrokenSymlinksFailToOpen() async throws {
        let dangling = try symlink("dangling.md", to: "missing.md")
        try symlink("loop-b.md", to: "loop-a.md")
        let loop = try symlink("loop-a.md", to: "loop-b.md")
        for url in [dangling, loop] {
            var opened: NSDocument?, failure: (any Error)?
            let done = expectation(description: url.lastPathComponent)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
                opened = doc
                failure = error
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 10)
            XCTAssertNil(opened, url.lastPathComponent)
            XCTAssertNotNil(failure, url.lastPathComponent)
        }
    }

    // MARK: 后台标签（只有当前标签有监视器，切过来时要补上这段时间磁盘上的变化）

    private func external(_ text: String, to url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }

    /// 以前显示旧内容、不提示；接着打字则自动保存失败（67000），约 15 s 后弹系统的 Save Anyway / Revert / Save As
    func testSelectingBackgroundTabPicksUpExternalChange() async throws {
        let a = try await openFile("a.md")
        _ = try await openFile("b.md", in: a.ws)
        try external("# theirs\n", to: a.url)
        a.ws.select(try XCTUnwrap(a.ws.tab(for: a.doc)))
        XCTAssertEqual(a.doc.source, "# theirs\n", "切过来这一刻就跟上（中间没让出主线程，不是监视器补的）")
        a.doc.session.stopWatching()   // 只看切标签这一下：监视器晚到的事件会替没写对的地方补救
        a.doc.replaceContents("# theirs\nmine\n")
        let failure = try await autosave(a.doc)
        XCTAssertNil(failure, "修改时间也要跟上，否则存不下去")
        XCTAssertEqual(try disk(a.url), "# theirs\nmine\n")
        XCTAssertNil(a.ws.window?.attachedSheet)
    }

    /// 编辑模式的后台标签：编辑器要跟上，重载不算用户的改动，之后照常打字、存储
    func testSelectingBackgroundTabInEditorModeFollows() async throws {
        let a = try await openFile("a.md")
        a.ws.setModeEditor(nil)
        let tv = try XCTUnwrap(a.ws.editorViewController.textView)
        _ = try await openFile("b.md", in: a.ws)
        try external("# theirs\n", to: a.url)
        a.ws.select(try XCTUnwrap(a.ws.tab(for: a.doc)))
        a.doc.session.stopWatching()   // 只看切标签这一下：监视器晚到的事件会替没写对的地方补救
        XCTAssertEqual(tv.string, "# theirs\n")
        try await Task.sleep(for: .milliseconds(50))   // 撤销组在 run loop 转一圈之后才关
        XCTAssertFalse(a.doc.isDocumentEdited)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(a.doc.isDocumentEdited)
        let failure = try await autosave(a.doc)
        XCTAssertNil(failure)
        XCTAssertEqual(try disk(a.url), "# theirs\ntyped")
    }

    /// 切过来时的重载和监视器的重载走同一条路：窗格刚挂上就重载，不能跳回开头。
    /// 只看没有回到开头。精确位置现在保不住：排好之后真实高度替换估算高度，滚动位置不动，内容就错开了（真实 App 上第 120 节跳到第 89 节，监视器的重载也一样，已知未修）
    func testSelectingBackgroundTabDoesNotJumpToTheTop() async throws {
        let body = (0..<200).map { "## Section \($0)\n\n" + String(repeating: "paragraph text ", count: 40) + "\n\n" }.joined()
        try external(body, to: tmp.appendingPathComponent("long.md"))
        let a = try await openFile("long.md")
        a.ws.setModeReader(nil)
        let tab = try XCTUnwrap(a.ws.tab(for: a.doc)), reader = tab.reader
        let rendered = try await eventually { reader.textView.string.contains("Section 199") }
        XCTAssertTrue(rendered)
        reader.scroll(toBlock: 200)
        let scrolled = try await eventually { (reader.textView.topVisibleBlockIndex() ?? 0) > 100 }
        XCTAssertTrue(scrolled)
        try await Task.sleep(for: .milliseconds(500))   // 滚动动画走完
        _ = try await openFile("b.md", in: a.ws)
        try external(body.replacingOccurrences(of: "## Section 5\n", with: "## Section five\n"), to: a.url)   // 改的是视口之前的块
        a.ws.select(tab)
        a.doc.session.stopWatching()   // 只看切标签这一下：监视器晚到的事件会替没写对的地方补救
        let reloaded = try await eventually { reader.textView.string.contains("Section five") }
        XCTAssertTrue(reloaded)
        XCTAssertGreaterThan(reader.textView.topVisibleBlockIndex() ?? 0, 50)
    }

    /// touch 没有改内容：切过来之后存储不该报"文件被改过"（以前是假警报）
    func testTouchWhileInBackgroundIsNotAChange() async throws {
        let a = try await openFile("a.md")
        _ = try await openFile("b.md", in: a.ws)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: a.url.path)
        a.ws.select(try XCTUnwrap(a.ws.tab(for: a.doc)))
        a.doc.session.stopWatching()   // 只看切标签这一下：监视器晚到的事件会替没写对的地方补救
        a.doc.replaceContents("# edited a\n")
        let failure = try await autosave(a.doc)
        XCTAssertNil(failure)
        XCTAssertEqual(try disk(a.url), "# edited a\n")
        XCTAssertNil(a.ws.window?.attachedSheet)
    }

    /// 关了"自动重新载入"：改动撤销完了也不替用户载入，⌘R 才载入
    func testUndoingEveryEditDoesNotFollowWithAutoReloadOff() async throws {
        let saved = Preferences.shared.autoReload
        Preferences.shared.autoReload = false
        defer { Preferences.shared.autoReload = saved }
        let a = try await openFile("a.md")
        a.doc.replaceContents("# mine\n")
        try external("# theirs\n", to: a.url)
        a.doc.updateChangeCount(.changeUndone)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(a.doc.isDocumentEdited)
        XCTAssertEqual(a.doc.source, "# mine\n")
        XCTAssertTrue(a.doc.reloadCommand())
        XCTAssertEqual(a.doc.source, "# theirs\n")
    }

    /// 有未保存改动的后台标签被外部改过：切过来也不打断，文字不动，切走再切回来也一样；下一次存储由系统问（标签在不在前台都一样，见下面）
    func testDirtyBackgroundTabIsNotInterruptedWhenSelected() async throws {
        let a = try await openFile("a.md")
        let b = try await openFile("b.md", in: a.ws)
        let tabA = try XCTUnwrap(a.ws.tab(for: a.doc)), tabB = try XCTUnwrap(a.ws.tab(for: b.doc))
        a.ws.select(tabA)
        a.doc.replaceContents("# mine\n")
        a.ws.select(tabB)
        try external("# theirs\n", to: a.url)
        /// 切过去，只看这一下：监视器晚到的事件会替没写对的地方补救
        func selectA() {
            a.ws.select(tabA)
            a.doc.session.stopWatching()
        }
        selectA()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(a.doc.source, "# mine\n", "问之前不动")
        a.ws.select(tabB)
        selectA()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(a.ws.window?.attachedSheet)
        timerAutosave(a.doc)
        try await answer(.revert, on: a.ws)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(a.doc.source, "# theirs\n")
    }

    /// 关掉当前标签：换上来的邻居同样是从后台回来的（同步走完，中间没让出主线程，不是监视器补的）
    func testNeighbourSelectedByClosingATabCatchesUp() async throws {
        let a = try await openFile("a.md")
        let b = try await openFile("b.md", in: a.ws)
        try external("# theirs\n", to: a.url)
        b.doc.close()
        XCTAssertTrue(a.ws.current.document === a.doc)
        XCTAssertEqual(a.doc.source, "# theirs\n")
    }

    /// 再次打开已经开着的文件 = 切到它的标签：一样要跟上（同上，同步走完）
    func testReopeningAFileInABackgroundTabCatchesUp() async throws {
        let a = try await openFile("a.md")
        _ = try await openFile("b.md", in: a.ws)
        try external("# theirs\n", to: a.url)
        NSDocumentController.shared.openDocument(withContentsOf: a.url, display: true) { _, already, _ in XCTAssertTrue(already) }
        XCTAssertTrue(a.ws.current.document === a.doc)
        XCTAssertEqual(a.doc.source, "# theirs\n")
    }

    /// 后台标签拆到新窗口（打开它所在的文件夹）：窗口显示的时候跟上
    func testBackgroundTabMovedToANewWindowCatchesUp() async throws {
        let (ws, _) = makeWorkspace(root: tmp.deletingLastPathComponent())
        let openedA = await open(tmp.appendingPathComponent("a.md"), in: ws, ephemeral: false)
        let doc = try XCTUnwrap(openedA)
        _ = await open(tmp.appendingPathComponent("b.md"), in: ws, ephemeral: false)
        try external("# theirs\n", to: tmp.appendingPathComponent("a.md"))
        (NSDocumentController.shared as! QuireDocumentController).openFolder(tmp)
        XCTAssertFalse(doc.workspace === ws)
        XCTAssertEqual(doc.source, "# theirs\n")
    }

    /// 关了"自动重新载入"：切标签也不能替用户载入；再打开时补上
    func testSelectingDoesNotReloadWithAutoReloadOff() async throws {
        let saved = Preferences.shared.autoReload
        Preferences.shared.autoReload = false
        defer { Preferences.shared.autoReload = saved }
        let a = try await openFile("a.md")
        _ = try await openFile("b.md", in: a.ws)
        let opened = try disk(a.url)
        try external("# theirs\n", to: a.url)
        a.ws.select(try XCTUnwrap(a.ws.tab(for: a.doc)))
        XCTAssertEqual(a.doc.source, opened)
        Preferences.shared.autoReload = true
        try await Task.sleep(for: .milliseconds(50))   // 比监视器的防抖短：不是监视器补的
        XCTAssertEqual(a.doc.source, "# theirs\n")
    }

    /// 有未保存改动的后台标签被外部改过，然后要关闭。关闭会先切过去（切过去时对磁盘，这时不能问）再 canClose：只有系统那一个问题
    ///（第一个选项是 Save Anyway），问的时候切到了它。不问就是静默盖掉对方那版。答完这一轮关闭不再继续，是系统的行为，这里不管
    private func closeDirtyStaleBackgroundTab(_ close: (WorkspaceWindowController, DocumentTab) -> Void) async throws {
        let a = try await openFile("a.md")
        let b = try await openFile("b.md", in: a.ws)
        let tabA = try XCTUnwrap(a.ws.tab(for: a.doc))
        a.ws.select(tabA)
        a.doc.replaceContents("# mine\n")
        a.ws.select(try XCTUnwrap(a.ws.tab(for: b.doc)))
        try external("# theirs\n", to: a.url)
        var asked: [NSWindow] = []
        try await failingOnDeadlock {
            close(a.ws, tabA)
            for _ in 0..<150 where a.doc.isDocumentEdited {
                if let sheet = a.ws.window?.attachedSheet, sheet.isVisible, !asked.contains(sheet) {
                    asked.append(sheet)
                    XCTAssertTrue(a.ws.current === tabA, "问的时候要切到它")
                    a.ws.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertEqual(asked.count, 1)
        XCTAssertFalse(a.doc.isDocumentEdited)
        XCTAssertEqual(try disk(a.url), "# mine\n", "选了 Save Anyway")
    }

    func testClosingDirtyStaleBackgroundTabAsksOnce() async throws {
        try await closeDirtyStaleBackgroundTab { ws, tab in ws.closeTab(tab) }
    }

    func testClosingOtherTabsWithADirtyStaleOneAsksOnce() async throws {
        try await closeDirtyStaleBackgroundTab { ws, tab in ws.closeOtherTabs(keeping: ws.tabs.first { $0 !== tab }!) }
    }

    func testClosingWindowWithADirtyStaleTabAsksOnce() async throws {
        try await closeDirtyStaleBackgroundTab { ws, _ in ws.window?.performClose(nil) }
    }

    private final class CloseDelegate: NSObject {
        @objc func document(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {}
    }

    /// 文档直接被问（AppKit 的路径）：文档自己切过去，同样只有系统那一个问题
    func testAskingADirtyStaleBackgroundDocumentDirectlyAsksOnce() async throws {
        let delegate = CloseDelegate()
        defer { withExtendedLifetime(delegate) {} }
        try await closeDirtyStaleBackgroundTab { _, tab in
            tab.document.canClose(withDelegate: delegate, shouldClose: #selector(CloseDelegate.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        }
    }

    /// 合并窗口时一个个摘标签，中间的"选中邻居"会对磁盘：有未保存改动的不动也不问，合并过来之后下一次存储由系统问
    func testMergingWindowsDoesNotAsk() async throws {
        let a = try await openFile("a.md")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quire-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = dir.appendingPathComponent("x.md"), y = dir.appendingPathComponent("y.md")
        for u in [x, y] { try external("# \(u.lastPathComponent)\n", to: u) }
        let openedX = await open(x, in: nil, ephemeral: false)
        let other = try XCTUnwrap(openedX?.workspace)
        XCTAssertFalse(other === a.ws)
        let openedY = await open(y, in: other, ephemeral: false)
        let docX = try XCTUnwrap(openedX), docY = try XCTUnwrap(openedY)
        // 另一个窗口：[x 当前, y 有未保存改动且被外部改过]
        docY.replaceContents("# mine\n")
        other.select(try XCTUnwrap(other.tab(for: docX)))
        try external("# theirs\n", to: y)
        a.ws.mergeAllWindows(nil)
        XCTAssertEqual(a.ws.tabs.count, 3)
        XCTAssertTrue(docY.workspace === a.ws)
        try await Task.sleep(for: .milliseconds(100))   // 排着的询问（如果有）轮到了
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(docY.source, "# mine\n")
        timerAutosave(docY)
        try await answer(.revert, on: a.ws)
        try await failingOnDeadlock { while docY.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(docY.source, "# theirs\n")
    }

    /// 改过、只被 touch 过的后台标签要关闭：切过去时对磁盘，修改时间跟上，不问（否则是假警报，这一轮关闭还停下来）
    func testTouchedDirtyBackgroundTabClosesWithoutAsking() async throws {
        let a = try await openFile("a.md")
        let b = try await openFile("b.md", in: a.ws)
        let tabA = try XCTUnwrap(a.ws.tab(for: a.doc))
        a.ws.select(tabA)
        a.doc.replaceContents("# mine\n")
        a.ws.select(try XCTUnwrap(a.ws.tab(for: b.doc)))
        try touch(a.url)
        try await failingOnDeadlock {
            a.ws.closeTab(tabA)
            for _ in 0..<250 where isOpen(a.doc) {
                if let window = a.ws.window, let sheet = window.attachedSheet, sheet.isVisible {
                    XCTFail("只被 touch 过：假警报")
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertEqual(try disk(a.url), "# mine\n")
    }

    /// 带著作归属块的文件，外部改了正文（哈希对不上）：跟上磁盘时会弹"著作归属标记已丢弃"
    private func withAuthorship(_ body: String) -> String { Authorship(spans: [.init(author: "me", start: 0, length: 3)]).embed(into: body) }
    private func editBodyExternally(_ url: URL) throws {
        try external(try disk(url).replacingOccurrences(of: "body", with: "theirs"), to: url)
    }

    /// 关干净的后台标签：关的时候不跟磁盘。跟了的话通知说的是已经关掉的文档，还会挡住关闭链上后面的存储面板，之后永远卡死
    func testClosingCleanStaleBackgroundTabShowsNoAuthorshipNotice() async throws {
        try external(withAuthorship("# a\n\nbody\n"), to: tmp.appendingPathComponent("a.md"))
        let a = try await openFile("a.md")
        _ = try await openFile("b.md", in: a.ws)
        try editBodyExternally(a.url)
        a.ws.closeTab(try XCTUnwrap(a.ws.tab(for: a.doc)))
        try await Task.sleep(for: .milliseconds(500))
        let notice = a.ws.window?.attachedSheet
        if let notice { a.ws.window?.endSheet(notice) }
        XCTAssertEqual(a.ws.tabs.count, 1)
        XCTAssertNil(notice, "通知说的是已经关掉的文档")
    }

    /// 合并窗口摘标签时不跟磁盘：通知会挂在要关的窗口上没人看见，标记还清掉了。留到用户切到它的时候
    func testMergingKeepsTheAuthorshipNoticeForTheSelection() async throws {
        let a = try await openFile("a.md")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quire-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = dir.appendingPathComponent("x.md"), y = dir.appendingPathComponent("y.md")
        try external("# x\n", to: x)
        try external(withAuthorship("# y\n\nbody\n"), to: y)
        let openedX = await open(x, in: nil, ephemeral: false)
        let other = try XCTUnwrap(openedX?.workspace)
        let openedY = await open(y, in: other, ephemeral: false)
        let docY = try XCTUnwrap(openedY)
        other.select(try XCTUnwrap(other.tab(for: try XCTUnwrap(openedX))))
        try editBodyExternally(y)
        a.ws.mergeAllWindows(nil)
        let orphan = other.window?.attachedSheet
        if let orphan { other.window?.endSheet(orphan) }
        a.ws.select(try XCTUnwrap(a.ws.tab(for: docY)))
        let notice = a.ws.window?.attachedSheet
        if let notice { a.ws.window?.endSheet(notice) }
        XCTAssertNil(orphan, "挂在要关的窗口上")
        XCTAssertNotNil(notice, "切到它的时候要说")
        XCTAssertEqual(docY.source, "# y\n\ntheirs\n")
    }

    /// 询问挂在窗口上时不能把文档从询问底下搬走：搬走之后 windowForSheet 指向没有 sheet 的新窗口，存储、关闭、追加都死等活动队列
    func testMovingATabIsRefusedWhileItIsAsked() async throws {
        let a = try await openFile("a.md")
        _ = try await openFile("b.md", in: a.ws)
        a.ws.select(try XCTUnwrap(a.ws.tab(for: a.doc)))
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try external("# theirs\n", to: a.url)
        timerAutosave(a.doc)
        let sheet = try await visibleSheet(on: a.ws)
        let window = try XCTUnwrap(a.ws.window)
        a.ws.moveTabToNewWindow(nil)
        XCTAssertTrue(a.doc.workspace === a.ws)
        XCTAssertTrue(a.doc.windowForSheet === window)
        XCTAssertEqual(window.attachedSheet, sheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(try disk(a.url), "# mine\n")
    }

    /// 同上，走打开文件夹：文件开在根目录更靠上的工作区里，打开它所在的文件夹本来要把它拆到新窗口
    func testOpeningTheFolderOfATabDoesNotMoveItWhileItIsAsked() async throws {
        let (ws, _) = makeWorkspace(root: tmp.deletingLastPathComponent())
        let openedA = await open(tmp.appendingPathComponent("a.md"), in: ws, ephemeral: false)
        let doc = try XCTUnwrap(openedA)
        _ = await open(tmp.appendingPathComponent("b.md"), in: ws, ephemeral: false)
        ws.select(try XCTUnwrap(ws.tab(for: doc)))
        doc.session.stopWatching()
        doc.replaceContents("# mine\n")
        try external("# theirs\n", to: tmp.appendingPathComponent("a.md"))
        timerAutosave(doc)
        let sheet = try await visibleSheet(on: ws)
        (NSDocumentController.shared as! QuireDocumentController).openFolder(tmp)
        XCTAssertTrue(doc.workspace === ws)
        XCTAssertEqual(ws.window?.attachedSheet, sheet)
        ws.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await failingOnDeadlock { while doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
    }

    // MARK: 后台标签的定时自动保存

    /// 有未保存改动的后台标签被外部改过，一直不切过去，定时器到点：系统问，挂在窗口上，也不把用户切走。
    /// 窗口控制器只挂在当前标签的文档上，以前这时 windowForSheet 是 nil，系统退回 app 级模态：挡住整个 App，答完文档又被标成未保存，之后就不跟磁盘了
    func testAutosaveOfABackgroundTabAsksOnItsWindow() async throws {
        let a = try await openFile("a.md")
        let b = try await openFile("b.md", in: a.ws)
        a.doc.replaceContents("# mine\n")
        try external("# theirs\n", to: a.url)
        timerAutosave(a.doc)
        let sheet = try await visibleSheet(on: a.ws)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertTrue(a.ws.current.document === b.doc)
        a.ws.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(a.doc.isDocumentEdited, "答完又被标成未保存")
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(try disk(a.url), "# mine\n")
        // 问过就结束，之后照常存储
        a.doc.replaceContents("# mine again\n")
        let failure = try await autosave(a.doc)
        XCTAssertNil(failure)
        XCTAssertEqual(try disk(a.url), "# mine again\n")
    }

    /// 选 Revert：后台标签跟上磁盘（编辑器也是），不算用户的改动。切过去看到的就是这一版，不再问，之后照常打字、存储
    func testRevertAnswerMakesABackgroundTabFollowTheDisk() async throws {
        let a = try await openFile("a.md")
        a.ws.setModeEditor(nil)
        let tv = try XCTUnwrap(a.ws.editorViewController.textView)
        _ = try await openFile("b.md", in: a.ws)
        a.doc.replaceContents("# mine\n")
        try external("# theirs\n", to: a.url)
        timerAutosave(a.doc)
        let sheet = try await visibleSheet(on: a.ws)
        XCTAssertNil(NSApp.modalWindow)
        a.ws.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await failingOnDeadlock { while a.doc.source != "# theirs\n" { try await Task.sleep(for: .milliseconds(20)) } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(a.doc.isDocumentEdited)
        XCTAssertEqual(tv.string, "# theirs\n")
        XCTAssertEqual(try disk(a.url), "# theirs\n")
        a.ws.select(try XCTUnwrap(a.ws.tab(for: a.doc)))
        a.doc.session.stopWatching()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(a.ws.window?.attachedSheet)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        let failure = try await autosave(a.doc)
        XCTAssertNil(failure)
        XCTAssertEqual(try disk(a.url), "# theirs\ntyped")
    }

    /// 过了排队重存的时间（sheet 关闭动画 + 等待 + 存储）。这时弹了没人点的模态的话由看门狗收场
    private func waitPastTheRetry() async throws { try await failingOnDeadlock { try await Task.sleep(for: .milliseconds(1200)) } }

    /// 它的活动队列是通的：卡住的话，之后存储、关闭都死等（这里由看门狗收场）
    private func assertActivityQueueIsFree(_ doc: MarkdownDocument) async throws {
        nonisolated(unsafe) var free = false
        doc.performActivity(withSynchronousWaiting: false) { done in free = true; done() }
        try await failingOnDeadlock { while !free { try await Task.sleep(for: .milliseconds(20)) } }
    }

    /// 两个后台标签都到点，第一个的询问还开着：一个窗口一次只能挂一个。以前第二个系统既不显示也不结束，它的活动队列卡住，之后存储、关闭都死等。
    /// 现在它先不问，第一个答完接着问，两边都存下来
    func testSecondBackgroundTabAsksAfterTheFirstIsAnswered() async throws {
        let a = try await openFile("a.md")
        let c = try await openFile("c.md", in: a.ws)
        _ = try await openFile("b.md", in: a.ws)
        for d in [a, c] {
            d.doc.replaceContents("# mine\n")
            try external("# theirs\n", to: d.url)
        }
        timerAutosave(a.doc)
        let first = try await visibleSheet(on: a.ws)
        timerAutosave(c.doc)
        try await assertActivityQueueIsFree(c.doc)
        XCTAssertTrue(c.doc.isDocumentEdited)
        XCTAssertEqual(a.ws.window?.attachedSheet, first)
        a.ws.window?.endSheet(first, returnCode: .alertFirstButtonReturn)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        let second = try await visibleSheet(on: a.ws)
        XCTAssertNotEqual(second, first)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(c.doc.source, "# mine\n", "问之前不动")
        a.ws.window?.endSheet(second, returnCode: .alertFirstButtonReturn)
        try await failingOnDeadlock { while c.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(try disk(a.url), "# mine\n")
        XCTAssertEqual(try disk(c.url), "# mine\n")
    }

    /// 窗口上开着别的 sheet（导出面板这一类，不在活动队列里），当前标签也一样存不下去：先不问，sheet 结束再问。
    /// 那个 sheet 刚结束又来一个（选"存储为"之后的面板）就接着等，不抢在它前面：面板挂不上去就丢了
    func testAutosaveFailingUnderAnotherSheetAsksAfterIt() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try external("# theirs\n", to: a.url)
        let window = try XCTUnwrap(a.ws.window)
        /// 挂上来的必须是它（询问抢在前面的话，它排在后面，由看门狗收场）
        func unrelatedSheet() async throws -> NSWindow {
            let alert = NSAlert()
            alert.messageText = "unrelated"
            alert.beginSheetModal(for: window) { _ in }
            try await failingOnDeadlock { while window.attachedSheet !== alert.window { try await Task.sleep(for: .milliseconds(5)) } }
            return alert.window
        }
        let other = try await unrelatedSheet()
        timerAutosave(a.doc)
        try await assertActivityQueueIsFree(a.doc)
        XCTAssertEqual(window.attachedSheet, other)
        window.endSheet(other)
        try await failingOnDeadlock { while window.attachedSheet === other { try await Task.sleep(for: .milliseconds(5)) } }
        try await Task.sleep(for: .milliseconds(50))
        let next = try await unrelatedSheet()
        try await waitPastTheRetry()
        XCTAssertEqual(window.attachedSheet, next)
        XCTAssertTrue(a.doc.isDocumentEdited)
        window.endSheet(next)
        try await failingOnDeadlock { while window.attachedSheet === next { try await Task.sleep(for: .milliseconds(5)) } }
        let asked = try await visibleSheet(on: a.ws)
        XCTAssertNotEqual(asked, next)
        window.endSheet(asked, returnCode: .alertFirstButtonReturn)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertEqual(try disk(a.url), "# mine\n")
    }

    /// 系统的询问开着时，从外面打开（Finder、quire://）另一个排队的标签：它不抢在询问前面，答完第一个接着问它，两边都存下来
    func testWaitingTabSelectedWhileAskingIsAskedAfterIt() async throws {
        let a = try await openFile("a.md")
        let c = try await openFile("c.md", in: a.ws)
        _ = try await openFile("b.md", in: a.ws)
        for d in [a, c] {
            d.doc.replaceContents("# mine\n")
            try external("# theirs\n", to: d.url)
        }
        timerAutosave(a.doc)
        let first = try await visibleSheet(on: a.ws)
        timerAutosave(c.doc)
        try await assertActivityQueueIsFree(c.doc)
        a.ws.select(try XCTUnwrap(a.ws.tab(for: c.doc)))
        c.doc.session.stopWatching()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(a.ws.window?.attachedSheet, first)
        a.ws.window?.endSheet(first, returnCode: .alertFirstButtonReturn)
        try await failingOnDeadlock { while a.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        let second = try await visibleSheet(on: a.ws)
        XCTAssertNotEqual(second, first)
        a.ws.window?.endSheet(second, returnCode: .alertFirstButtonReturn)
        try await failingOnDeadlock { while c.doc.isDocumentEdited { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(try disk(a.url), "# mine\n")
        XCTAssertEqual(try disk(c.url), "# mine\n")
    }

    /// 排队等着问的标签轮到时已经没有未保存改动：不用问，也不写盘
    func testTabWithNothingLeftToSaveIsNotAskedWhenItsTurnComes() async throws {
        let a = try await openFile("a.md")
        let c = try await openFile("c.md", in: a.ws)
        _ = try await openFile("b.md", in: a.ws)
        for d in [a, c] {
            d.doc.replaceContents("# mine\n")
            try external("# theirs\n", to: d.url)
        }
        timerAutosave(a.doc)
        let first = try await visibleSheet(on: a.ws)
        timerAutosave(c.doc)
        try await assertActivityQueueIsFree(c.doc)
        c.doc.updateChangeCount(.changeCleared)
        try await Task.sleep(for: .milliseconds(100))   // 改动撤销完了，它跟上了磁盘；内容一样的写盘只能从修改时间看出来
        let modified = try FileManager.default.attributesOfItem(atPath: c.url.path)[.modificationDate] as? Date
        a.ws.window?.endSheet(first, returnCode: .alertSecondButtonReturn)
        try await waitPastTheRetry()
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(try disk(c.url), "# theirs\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: c.url.path)[.modificationDate] as? Date, modified, "写了盘")
    }

    /// 用户取消的操作（系统也用 presentError 回这个，不显示）：窗口忙也不排队，否则之后又问一遍用户刚取消的事
    func testCancelledSaveIsNotAskedAgainAfterTheSheetEnds() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try external("# theirs\n", to: a.url)
        let window = try XCTUnwrap(a.ws.window)
        let alert = NSAlert()
        alert.messageText = "unrelated"
        alert.beginSheetModal(for: window) { _ in }
        let other = try await visibleSheet(on: a.ws)
        a.doc.presentError(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError), modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
        window.endSheet(other)
        try await waitPastTheRetry()
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(a.doc.isDocumentEdited)
        a.doc.updateChangeCount(.changeCleared)
    }

    /// 排队等着问的标签在轮到之前关掉了（文档 close 不问）：不再问，关掉的文档没有窗口，问就是没人点的模态
    func testClosedTabIsNotAskedWhenItsTurnComes() async throws {
        let a = try await openFile("a.md")
        let c = try await openFile("c.md", in: a.ws)
        _ = try await openFile("b.md", in: a.ws)
        for d in [a, c] {
            d.doc.replaceContents("# mine\n")
            try external("# theirs\n", to: d.url)
        }
        timerAutosave(a.doc)
        let first = try await visibleSheet(on: a.ws)
        timerAutosave(c.doc)
        try await assertActivityQueueIsFree(c.doc)
        a.ws.window?.endSheet(first, returnCode: .alertSecondButtonReturn)
        c.doc.close()
        try await waitPastTheRetry()
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertNil(a.ws.window?.attachedSheet)
        XCTAssertEqual(a.doc.source, "# theirs\n")
    }

    /// 问着的时候又打开了别的文件（Finder、quire://），被问的标签到了后台：询问还在窗口上、还能答，追加（quire://append、快捷指令）和关闭都拒绝。
    /// 以前追加看 windowForSheet，标签一到后台就放行，存储要等询问答完，AppKit 又找不到 sheet，主线程真的死等
    func testTabBeingAskedRefusesAppendAfterGoingToTheBackground() async throws {
        let a = try await openFile("a.md")
        a.doc.session.stopWatching()
        a.doc.replaceContents("# mine\n")
        try external("# theirs\n", to: a.url)
        timerAutosave(a.doc)
        let asking = try await visibleSheet(on: a.ws)
        let b = try await openFile("b.md", in: a.ws)
        XCTAssertTrue(a.ws.current.document === b.doc)
        XCTAssertEqual(a.ws.window?.attachedSheet, asking)
        try await failingOnDeadlock {
            XCTAssertFalse(URLScheme.appendText("x", to: a.url, external: false))
            a.ws.closeTab(try XCTUnwrap(a.ws.tab(for: a.doc)))
        }
        XCTAssertEqual(a.ws.tabs.count, 2)
        XCTAssertEqual(a.doc.source, "# mine\n")
        a.ws.window?.endSheet(asking, returnCode: .alertSecondButtonReturn)
        try await failingOnDeadlock { while a.doc.source != "# theirs\n" { try await Task.sleep(for: .milliseconds(20)) } }
        XCTAssertFalse(a.doc.isDocumentEdited)
    }

    // MARK: 监视器停了就不再回调

    /// 事件和防抖都已经走完、回主线程的那一跳还在排队时切走：这一跳不能再动已经切走的标签，切回来时才跟上
    func testWatcherEventAlreadyOnItsWayDoesNotReachADeselectedTab() async throws {
        let a = try await openFile("a.md")
        let b = try await openFile("b.md", in: a.ws)
        let tabA = try XCTUnwrap(a.ws.tab(for: a.doc))
        a.ws.select(tabA)
        try await Task.sleep(for: .milliseconds(100))   // 等 kqueue 注册好
        let opened = try disk(a.url)
        try external("# theirs\n", to: a.url)
        usleep(400_000)   // 主线程不转：后台把事件、防抖走完，回主线程的那一跳排上队
        a.ws.select(try XCTUnwrap(a.ws.tab(for: b.doc)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(a.doc.source, opened, "切走之后不动它，切回来再说")
        a.ws.select(tabA)
        XCTAssertEqual(a.doc.source, "# theirs\n")
    }

    /// 监视器回调里读文件：通知到的时候磁盘上是什么
    private final class WatcherLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0, _last: String?
        func record(_ url: URL) {
            let s = try? String(contentsOf: url, encoding: .utf8)
            lock.withLock { _calls += 1; _last = s }
        }
        var calls: Int { lock.withLock { _calls } }
        var last: String? { lock.withLock { _last } }
    }

    private func eventually(within seconds: TimeInterval = 3, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    /// 放掉监视器时防抖里还排着一次：不能再回调
    func testFileWatcherReleasedDuringDebounceStaysSilent() async throws {
        let url = tmp.appendingPathComponent("a.md")
        let log = WatcherLog()
        var watcher: FileWatcher? = FileWatcher(url: url, debounce: 1) { log.record(url) }
        XCTAssertNotNil(watcher)
        try await Task.sleep(for: .milliseconds(100))   // 等 kqueue 注册好
        try external("# theirs\n", to: url)
        try await Task.sleep(for: .milliseconds(100))   // 事件到了，防抖还没到
        watcher = nil
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(log.calls, 0)
    }

    /// 替换之后到重新打开之间（0.2 s）旧 fd 看不到新文件：这段时间又被替换（连续存储、切分支），第一次通知已经发过了，重新打开之后要再报一次
    func testFileWatcherReportsAReplaceDuringItsReopen() async throws {
        let url = tmp.appendingPathComponent("a.md")
        let log = WatcherLog()
        let watcher = FileWatcher(url: url, debounce: 0.02) { log.record(url) }
        defer { withExtendedLifetime(watcher) {} }
        try await Task.sleep(for: .milliseconds(100))   // 等 kqueue 注册好
        try external("one", to: url)
        let first = try await eventually { log.last == "one" }
        XCTAssertTrue(first)
        try external("two", to: url)
        let second = try await eventually { log.last == "two" }
        XCTAssertTrue(second, "停在了上一版")
    }

    /// 文件一直被替换时，重新打开的 open 和 kqueue 注册之间总会落上一次：fd 留在没人用的 inode 上，之后再也没有任何事件
    func testFileWatcherSurvivesAStormOfReplaces() async throws {
        let url = tmp.appendingPathComponent("a.md")
        let log = WatcherLog()
        let watcher = FileWatcher(url: url, debounce: 0.02) { log.record(url) }
        defer { withExtendedLifetime(watcher) {} }
        try await Task.sleep(for: .milliseconds(100))   // 等 kqueue 注册好
        let temp = tmp.appendingPathComponent("a.md.tmp").path, path = url.path
        await Task.detached {
            let bytes = Data("storm".utf8)
            let end = Date(timeIntervalSinceNow: 1.2)   // 够重新打开很多轮
            while Date() < end {
                FileManager.default.createFile(atPath: temp, contents: bytes)
                rename(temp, path)
            }
        }.value
        try await Task.sleep(for: .milliseconds(600))   // 等排着的重新打开都走完
        try external("after", to: url)
        let seen = try await eventually { log.last == "after" }
        XCTAssertTrue(seen, "监视器已经瞎了")
    }

    /// 指向这个文件的 fd 数（打开着的监视器每个占一个）
    private func descriptorCount(of url: URL) -> Int {
        let suffix = url.pathComponents.suffix(2).joined(separator: "/")   // F_GETPATH 给的是解析过符号链接的路径（/private/var/…）
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return (0..<Int32(4096)).filter { fcntl($0, F_GETPATH, &path) == 0 && String(cString: path).hasSuffix(suffix) }.count
    }

    /// 文件不在时可能同时有几路在重试打开（移走又立刻删掉：两个事件各排一次重新打开）：文件回来之后只能留一个监视，多出来的 fd 永远关不掉
    func testFileWatcherKeepsOneDescriptorWhenTheFileComesBack() async throws {
        let url = tmp.appendingPathComponent("a.md"), moved = tmp.appendingPathComponent("moved.md")
        let log = WatcherLog()
        let watcher = FileWatcher(url: url, debounce: 0.02) { log.record(url) }
        defer { withExtendedLifetime(watcher) {} }
        try await Task.sleep(for: .milliseconds(100))   // 等 kqueue 注册好
        try FileManager.default.moveItem(at: url, to: moved)
        try await Task.sleep(for: .milliseconds(50))
        try FileManager.default.removeItem(at: moved)
        try await Task.sleep(for: .milliseconds(400))   // 排着的重新打开都走完，都在重试
        try external("back", to: url)
        let seen = try await eventually { log.last == "back" }
        XCTAssertTrue(seen)
        try await Task.sleep(for: .milliseconds(1500))   // 第二路重试也到了
        XCTAssertEqual(descriptorCount(of: url), 1)
    }

    // MARK: 标签条的鼠标（直接把事件交给视图：没有窗口时 locationInWindow 就是视图坐标）

    private func click(_ strip: TabStripView, at p: NSPoint, count: Int = 1) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        strip.mouseMoved(with: event(.mouseMoved))
        strip.mouseDown(with: event(.leftMouseDown))
        strip.mouseUp(with: event(.leftMouseUp))
    }

    private func strip(width: CGFloat, titles: [String]) -> TabStripView {
        let s = TabStripView(frame: NSRect(x: 0, y: 0, width: width, height: TabStripView.height))
        s.items = titles.enumerated().map { TabStripView.Item(title: $1, path: nil, ephemeral: false, selected: $0 == 0) }
        return s
    }

    func testTabStripKeepsItsDragsAwayFromTheWindow() {
        XCTAssertFalse(strip(width: 400, titles: ["a", "b"]).mouseDownCanMoveWindow, "否则窗口服务器直接拖窗口，这里收不到 mouseDragged")
    }

    /// 让 hitTest 看到一次真的按下（NSApp.currentEvent）
    private func withCurrentLeftMouseDown(clickCount: Int, timestamp: TimeInterval = 0, modifierFlags: NSEvent.ModifierFlags = [], _ body: () -> Void) {
        NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: modifierFlags, timestamp: timestamp, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!, atStart: true)
        _ = NSApp.nextEvent(matching: .leftMouseDown, until: nil, inMode: .default, dequeue: true)
        body()
    }

    /// 空白处不接事件，交给系统的标题栏：拖窗口、双击都按系统设置（Fill 的再次双击不还原、全屏里不响，照抄总有对不上的）
    func testBlankPartOfTheStripIsLeftToTheTitleBar() {
        let s = strip(width: 800, titles: ["a", "b"])   // 单元宽 200，+ 在 404–432
        XCTAssertNil(s.hitTest(NSPoint(x: 600, y: 14)), "空白")
        XCTAssertNil(s.hitTest(NSPoint(x: 402, y: 14)), "标签和 + 之间的缝")
        XCTAssertTrue(s.hitTest(NSPoint(x: 100, y: 14)) === s, "标签")
        XCTAssertTrue(s.hitTest(NSPoint(x: 418, y: 14)) === s, "+")
    }

    /// 唯一的固定标签读作窗口标题：左键交给标题栏；临时标签双击要固定，× 要能点，右键菜单不在这里判断
    func testLonePinnedTabReadsAsTitleForTheLeftButton() {
        let s = strip(width: 800, titles: ["a"])
        XCTAssertTrue(s.hitTest(NSPoint(x: 30, y: 14)) === s, "不是左键按下（右键、悬停时的命中检查）：还是它的")
        withCurrentLeftMouseDown(clickCount: 1, modifierFlags: .control) { XCTAssertTrue(s.hitTest(NSPoint(x: 30, y: 14)) === s, "Ctrl+点击是右键菜单") }
        withCurrentLeftMouseDown(clickCount: 1) {
            XCTAssertNil(s.hitTest(NSPoint(x: 30, y: 14)))
            s.items[0].ephemeral = true
            XCTAssertTrue(s.hitTest(NSPoint(x: 30, y: 14)) === s, "临时标签：双击固定")
        }
    }

    /// 刚点完 × 标签挪了位置，连按的第二下可能落到空白处：不能变成标题栏双击（窗口缩放）。过了连按时间的双击照常给标题栏
    func testRepeatClickAfterCloseIsNotLeftToTheTitleBar() {
        let s = strip(width: 800, titles: ["a", "b", "c"])
        var closed = 0
        s.onClose = { _ in closed += 1 }
        click(s, at: NSPoint(x: 82, y: 14))   // 第一个标签的 ×（单元宽 200，标题居中，× 紧贴标题左边）
        XCTAssertEqual(closed, 1)
        let blank = NSPoint(x: 700, y: 14)
        withCurrentLeftMouseDown(clickCount: 2) { XCTAssertTrue(s.hitTest(blank) === s, "这一下归条子，在 mouseDown 里吃掉") }
        withCurrentLeftMouseDown(clickCount: 2, timestamp: NSEvent.doubleClickInterval + 1) { XCTAssertNil(s.hitTest(blank), "空白处的单击清不掉标记：过了连按时间的双击也要给标题栏") }
    }

    func testPlusStaysInsideANarrowStripWithALongLoneTitle() {
        let s = strip(width: 150, titles: [String(repeating: "很长的文件名", count: 10)])
        var created = 0
        s.onNew = { created += 1 }
        click(s, at: NSPoint(x: 140, y: 14))
        XCTAssertEqual(created, 1, "+ 要留在条内点得到")
    }

    func testDoubleClickOnCloseIsOneClose() {
        let s = strip(width: 400, titles: ["a", "b", "c"])
        var closed: [Int] = [], pinned: [Int] = []
        s.onClose = { closed.append($0) }
        s.onPin = { pinned.append($0) }
        // 三个标签时单元宽 122，标题居中，× 紧贴标题左边（35–51）
        click(s, at: NSPoint(x: 43, y: 14))
        XCTAssertEqual(closed, [0])
        s.items.removeFirst()
        click(s, at: NSPoint(x: 43, y: 14), count: 2)   // 第二下落在挪过来的标签上
        XCTAssertEqual(closed, [0])
        XCTAssertEqual(pinned, [], "不算双击固定")
        // 两个标签时单元宽 184：× 在 66–82，这里是标题右边的空处
        click(s, at: NSPoint(x: 150, y: 14), count: 1)
        click(s, at: NSPoint(x: 150, y: 14), count: 2)
        XCTAssertEqual(pinned, [0], "正常的双击照常固定")
    }

    /// 标签在指针底下挪动时鼠标没动、收不到 mouseMoved：× 和提亮要跟着指针现在压着的标签走，否则 × 留在原来的位置（或者已经不存在的下标上）
    func testHoverFollowsTabsMovingUnderAStillPointer() {
        let s = strip(width: 400, titles: ["a", "b", "c"])
        let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: true)
        w.contentView = s
        /// 把窗口摆到真实指针底下，让指针压在条内 p 处（不用上屏，也不碰指针）
        func pointer(at p: NSPoint) {
            let m = NSEvent.mouseLocation
            w.setFrameOrigin(NSPoint(x: m.x - p.x, y: m.y - (s.bounds.height - p.y)))
        }
        // 三个标签时单元宽 122：x = 300 在第三个上
        pointer(at: NSPoint(x: 300, y: 14))
        s.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: w.mouseLocationOutsideOfEventStream, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        XCTAssertEqual(s.hoverIndex, 2)
        s.items.removeLast()   // 关掉它：两个标签时单元宽 184，指针压到了第二个上
        XCTAssertEqual(s.hoverIndex, 1)
        s.items.swapAt(0, 1)   // 拖动排序
        XCTAssertEqual(s.hoverIndex, 1)
        s.items.removeLast()   // 只剩一个：标签贴着名字，指针在空白处
        XCTAssertNil(s.hoverIndex, "下标不能留在已经不存在的标签上")
    }

    func testDetachAndMerge() {
        let (ws, _) = makeWorkspace(root: tmp)
        let b = untitled()
        ws.addTab(b, ephemeral: false)
        ws.moveTabToNewWindow(nil)
        XCTAssertEqual(ws.tabs.count, 1)
        let other = b.workspace
        XCTAssertNotNil(other); XCTAssertFalse(other === ws)
        XCTAssertEqual(other?.rootURL?.standardizedFileURL, tmp.standardizedFileURL, "拆出去的窗口沿用根目录")
        XCTAssertEqual(other?.tabs.count, 1)
        other?.window?.close()   // 合并测试直接调 addTab（mergeAll 依赖 orderedWindows，测试进程里窗口未必上屏）
    }

    func testContains() {
        let (ws, _) = makeWorkspace(root: tmp)
        XCTAssertTrue(ws.contains(tmp.appendingPathComponent("a.md")))
        XCTAssertTrue(ws.contains(tmp.appendingPathComponent("sub/x.md")))
        XCTAssertFalse(ws.contains(URL(fileURLWithPath: "/tmp/elsewhere.md")))
        let (empty, _) = makeWorkspace(root: nil)
        XCTAssertTrue(empty.contains(URL(fileURLWithPath: "/tmp/anything.md")), "没有根的空工作区什么都收")
    }

    // MARK: 文档控制器的去向

    func testOpenFileIntoWorkspaceAsTab() async throws {
        let (ws, _) = makeWorkspace(root: tmp)
        let a = tmp.appendingPathComponent("a.md")
        let doc = await open(a, in: ws, ephemeral: true)
        XCTAssertNotNil(doc)
        XCTAssertTrue(doc?.workspace === ws, "指定工作区：作为标签打开，不开新窗")
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertTrue(ws.tab(for: doc!)!.isEphemeral)
        // 再打开同一个文件：切到已有标签，不重复
        let again = await open(a, in: ws, ephemeral: false)
        XCTAssertTrue(again === doc)
        XCTAssertEqual(ws.tabs.count, 2)
    }

    func testOpenFileOutsideRootOpensNewWindow() async throws {
        let (ws, _) = makeWorkspace(root: tmp)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("quire-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let x = other.appendingPathComponent("x.md")
        try "# x\n".write(to: x, atomically: true, encoding: .utf8)
        let doc = await open(x, in: nil, ephemeral: false)
        XCTAssertNotNil(doc?.workspace)
        XCTAssertFalse(doc?.workspace === ws, "根外的文件另开工作区")
        XCTAssertEqual(doc?.workspace?.rootURL?.standardizedFileURL, other.standardizedFileURL)
        XCTAssertEqual(ws.tabs.count, 1)
    }

    // MARK: 标签名

    func testDuplicateTitlesAreDisambiguated() {
        let a = URL(fileURLWithPath: "/w/a/README.md"), b = URL(fileURLWithPath: "/w/b/README.md")
        let n1 = URL(fileURLWithPath: "/w/notes.md"), n2 = URL(fileURLWithPath: "/w/notes.markdown")
        let t = WorkspaceWindowController.disambiguatedTitles([("README", a), ("README", b), ("notes", n1), ("notes", n2), ("THEMES", URL(fileURLWithPath: "/w/THEMES.md")), ("Untitled", nil)])
        XCTAssertEqual(t, ["README — a", "README — b", "notes.md", "notes.markdown", "THEMES", "Untitled"])
        // 大小写不同也算重名
        XCTAssertEqual(WorkspaceWindowController.disambiguatedTitles([("Readme", a), ("README", b)]), ["Readme — a", "README — b"])
    }

    /// 上级文件夹也同名（两个项目的 docs/README）：只加一层还是分不清，要一直往上加到分得清为止，每个标签只加自己需要的那么多层
    func testDuplicateTitlesInSameNamedFoldersGoUpUntilTheyDiffer() {
        func titles(_ paths: String...) -> [String] {
            WorkspaceWindowController.disambiguatedTitles(paths.map { p in
                let u = URL(fileURLWithPath: p)
                return (u.deletingPathExtension().lastPathComponent, u)
            })
        }
        XCTAssertEqual(titles("/w/a/docs/README.md", "/w/b/docs/README.md"), ["README — a/docs", "README — b/docs"])
        XCTAssertEqual(titles("/w/a/docs/README.md", "/w/b/docs/README.md", "/w/c/README.md"), ["README — a/docs", "README — b/docs", "README — c"])
        XCTAssertEqual(titles("/p/x/y/z/n.md", "/q/x/y/z/n.md"), ["n — p/x/y/z", "n — q/x/y/z"])
        // 一个的上级路径是另一个的后缀：到根为止
        XCTAssertEqual(titles("/x/n.md", "/y/x/n.md"), ["n — /x", "n — y/x"])
        // 两个文件夹里都有 notes.md 和 notes.markdown：完整文件名也重名
        XCTAssertEqual(titles("/w/a/notes.md", "/w/a/notes.markdown", "/w/b/notes.md", "/w/b/notes.markdown"),
                       ["notes.md — a", "notes.markdown — a", "notes.md — b", "notes.markdown — b"])
    }

    func testTabTitleDropsMarkdownExtensionLikeSidebar() {
        let (ws, _) = makeWorkspace(root: tmp)
        let doc = MarkdownDocument()
        doc.fileURL = tmp.appendingPathComponent("a.md")
        NSDocumentController.shared.addDocument(doc)
        let tab = ws.addTab(doc, ephemeral: false)
        XCTAssertEqual(tab.title, "a")
        XCTAssertEqual(tab.title, FileTreeController.displayName(tmp.appendingPathComponent("a.md"), ambiguous: false))
    }

    // MARK: 铬的墨阶（DESIGN.md §8.1）

    private func rgb(_ c: NSColor) -> [Int] {
        let s = c.usingColorSpace(.sRGB)!
        return [s.redComponent, s.greenComponent, s.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    /// 选中底板 = 同一行里系统分段控件的选中段（macOS 27.0.1 实测：Claude Dark (50,50,49)）；浅色主题故意深一档
    func testSelectedPlateMatchesSystemSegmentInDarkThemes() {
        let dark = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x13 / 255, alpha: 1)   // Claude Dark 背景
        let plate = rgb(ChromeColors.ink(dark, ChromeStep.selected(dark: true)))
        for (a, b) in zip(plate, [50, 50, 49]) { XCTAssertEqual(a, b, accuracy: 1) }
        let light = NSColor(srgbRed: 0xFA / 255, green: 0xF9 / 255, blue: 0xF5 / 255, alpha: 1)   // Claude Light 背景
        let chrome = ChromeColors.elevated(light), lp = ChromeColors.ink(light, ChromeStep.selected(dark: false))
        XCTAssertLessThan(rgb(lp)[0], rgb(chrome)[0], "浅色主题里选中底板比铬深（和系统选中段同方向）")
    }

    /// 所有内置主题：铬上的次要标题 ≥ 4.5:1；选中标题在底板上 ≥ 4.5:1；状态都朝同一方向（深色变亮、浅色变暗）
    func testChromeInkLadderReadableInEveryBuiltInTheme() {
        let themes = ThemeStore.loadBuiltIn().themes
        XCTAssertGreaterThanOrEqual(themes.count, 12)
        for theme in themes {
            let bg = RenderStyle(theme: theme).background
            let dark = ChromeColors.isDark(bg)
            let chrome = ChromeColors.elevated(bg)
            let plate = ChromeColors.ink(bg, ChromeStep.selected(dark: dark))
            let secondary = ChromeColors.ink(bg, ChromeStep.secondaryText(dark: dark))
            let primary = ChromeColors.ink(bg, ChromeStep.primaryText)
            XCTAssertGreaterThanOrEqual(ChromeColors.contrast(secondary, chrome), 4.5, "\(theme.id) 次要标题")
            XCTAssertGreaterThanOrEqual(ChromeColors.contrast(primary, plate), 4.5, "\(theme.id) 选中标题")
            let lum = { (c: NSColor) in self.rgb(c).reduce(0, +) }
            if dark { XCTAssertGreaterThan(lum(plate), lum(chrome), "\(theme.id) 深色主题：选中变亮") }
            else { XCTAssertLessThan(lum(plate), lum(chrome), "\(theme.id) 浅色主题：选中变暗") }
            XCTAssertGreaterThan(ChromeColors.contrast(plate, chrome), ChromeColors.contrast(ChromeColors.ink(bg, ChromeStep.hoverFill), chrome), "\(theme.id) 悬停底比选中弱")
        }
    }

    func testTabTextInsetIsContinuous() {
        XCTAssertEqual(TabStripView.textInset(plateWidth: 192), 22)
        XCTAssertEqual(TabStripView.textInset(plateWidth: 82), 21)
        XCTAssertEqual(TabStripView.textInset(plateWidth: 52), 6)
        var prev = TabStripView.textInset(plateWidth: 20)
        for w in stride(from: 21, through: 240, by: 1) {
            let v = TabStripView.textInset(plateWidth: CGFloat(w))
            XCTAssertLessThanOrEqual(abs(v - prev), 0.5 + 1e-9); prev = v
        }
    }

    // MARK: 状态

    func testWorkspaceStateRoundTrip() throws {
        let saved = [WorkspaceState.Workspace(root: tmp.path, tabs: [.init(path: tmp.appendingPathComponent("a.md").path, ephemeral: false, mode: 2), .init(path: tmp.appendingPathComponent("b.md").path, ephemeral: true, mode: 0)], current: 1, frame: "0 0 800 600", sidebarCollapsed: false)]
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode([WorkspaceState.Workspace].self, from: data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].tabs.count, 2)
        XCTAssertEqual(back[0].current, 1)
        XCTAssertTrue(back[0].tabs[1].ephemeral)
        XCTAssertEqual(back[0].tabs[0].mode, 2)
    }
}
