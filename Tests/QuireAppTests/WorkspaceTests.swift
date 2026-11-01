import XCTest
import AppKit
@testable import Quire
import QuireCore
import QuireRender

/// 工作区窗口模型（ADR-18）：标签的增删选、临时标签替换 / 固定、document 换挂、文档控制器的去向判断、状态存取。
/// 在 xctest 进程里真建窗口（不显示到屏幕的也能建），不弹任何 sheet（只用没改过的文档，或改过但有文件、就地自动保存的文档；要取消就用 ScriptedDocument 替面板回答）。
@MainActor
final class WorkspaceTests: XCTestCase {
    private var tmp: URL!
    nonisolated(unsafe) private static var booted = false

    /// 同一个测试进程只能建一次（所有测试类都走这里）：macOS 26 上再建一个 QuireDocumentController，共享控制器就变回系统默认的
    static func bootApp() {
        // 和 main.swift 一样的顺序：先建 QuireDocumentController（NSApplication.shared 会顺手建默认的文档控制器）
        if !booted { _ = QuireDocumentController(); _ = NSApplication.shared; booted = true }
    }

    override func setUp() async throws {
        Self.bootApp()
        XCTAssertTrue(NSDocumentController.shared is QuireDocumentController, "QuireDocumentController 必须是共享控制器（在任何 NSDocumentController.shared 之前建）")
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quire-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for n in ["a", "b", "c"] { try "# \(n)\n\ntext\n".write(to: tmp.appendingPathComponent("\(n).md"), atomically: true, encoding: .utf8) }
    }

    override func tearDown() async throws {
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
        let watchdog = DispatchWorkItem { @Sendable in fatalError("关闭死锁：主线程 30 s 没回来") }
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
