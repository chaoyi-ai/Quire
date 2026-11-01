import XCTest
import AppKit
import QuireCore
@testable import Quire

/// 侧栏的行永远不超出侧栏：长名字尾部省略，选中高亮两端都留内缩。在真的工作区窗口里量（分隔线走 setPosition，和 restoreSidebarWidth 同一条路）。
/// 回归：autoresizesOutlineColumn 让大纲列随展开层级增减（每层 ±indentationPerLevel，展开要下一轮才生效）。列一宽，行连同省略号跑到可视区外，
/// 又没有横向滚动条，看上去就是硬切、高亮顶到分隔线；拖分隔线会把列拉回贴合，所以 bug 时有时无；拖完再折叠，列又比侧栏窄，名字提前省略。
/// 所以这里先定宽度再展开，顺序反了量不到。
@MainActor
final class SidebarLayoutTests: XCTestCase {
    private static let longStem = "R04-decision-calibration-and-ordinal-papers"
    /// 三级标题挂在当前文档下面：文件行以下再多三层缩进
    private static let headings = Outline(entries: [
        .init(id: "h1", level: 1, title: "A long enough first level heading for the sidebar", blockIndex: 0, line: 1),
        .init(id: "h2", level: 2, title: "这是一个相当长的二级标题，用来看标题行会不会被正确截断", blockIndex: 1, line: 3),
        .init(id: "h3", level: 3, title: "Third level heading that is also rather long", blockIndex: 2, line: 5),
    ])
    private var tmp: URL!
    private var longFile: URL { tmp.appendingPathComponent(Self.longStem + ".md") }
    nonisolated(unsafe) private static var booted = false

    override func setUp() async throws {
        // 启动顺序同 WorkspaceTests：先建 QuireDocumentController，再 NSApplication.shared
        if !Self.booted { _ = QuireDocumentController(); _ = NSApplication.shared; Self.booted = true }
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quire-sidebar-\(UUID().uuidString)")
        let deep = tmp.appendingPathComponent("notes/deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for u in [longFile, tmp.appendingPathComponent("R01-short.md"), deep.appendingPathComponent("R05-another-rather-long-file-name-two-folders-down.md")] {
            try "# x\n".write(to: u, atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws {
        for ws in WorkspaceWindowController.all { ws.window?.close() }
        for doc in NSDocumentController.shared.documents { doc.close() }
        UserDefaults.standard.removeObject(forKey: "sidebar.width")   // 窗口的分隔线观察者会记下来，别带到下一个用例
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: 脚手架

    @MainActor private struct Sidebar {
        let workspace: WorkspaceWindowController
        var controller: SidebarViewController { workspace.sidebarViewController }
        var outline: SidebarOutlineView { controller.files.outlineView }
        var splitView: NSSplitView { (workspace.window!.contentViewController as! NSSplitViewController).splitView }
    }

    private func waitUntil(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    /// 工作区窗口（不上屏），侧栏定在 240 pt，树的第一层已加载
    private func makeSidebar() async -> Sidebar {
        let d = MarkdownDocument()
        NSDocumentController.shared.addDocument(d)
        let sidebar = Sidebar(workspace: WorkspaceWindowController(document: d, root: tmp))
        setWidth(240, sidebar)
        await waitUntil("树加载出来") { row(titled: "R01", in: sidebar.outline) != nil }
        return sidebar
    }

    /// 当前文档 = 长名字文件，它的大纲展开在树里
    private func openLongFile(in sidebar: Sidebar) async {
        sidebar.controller.outline = Self.headings
        sidebar.controller.currentURL = longFile
        await waitUntil("大纲展开到第三级标题") { row(titled: "Third level", in: sidebar.outline) != nil }
        await settle(sidebar)
    }

    /// NSOutlineView 展开后要下一轮才调列宽：等它做完再往下走，否则 bug 也能过（或者撞上还没落地的调整）
    private func settle(_ sidebar: Sidebar) async {
        try? await Task.sleep(nanoseconds: 50_000_000)
        sidebar.workspace.window?.layoutIfNeeded()
    }

    private func setWidth(_ width: CGFloat, _ sidebar: Sidebar, file: StaticString = #filePath, line: UInt = #line) {
        sidebar.splitView.setPosition(width, ofDividerAt: 0)
        sidebar.workspace.window?.layoutIfNeeded()
        XCTAssertEqual(sidebar.controller.view.frame.width, width, accuracy: 0.5, "分隔线没走到位，后面就没量到要量的宽度", file: file, line: line)
    }

    private func row(titled prefix: String, in outline: NSOutlineView) -> Int? {
        (0..<outline.numberOfRows).first { field(ofRow: $0, in: outline)?.stringValue.hasPrefix(prefix) == true }
    }

    private func field(ofRow row: Int, in outline: NSOutlineView) -> NSTextField? {
        (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField
    }

    /// 每一行（行视图：高亮画在它里面；文字框：省略号画在它里面）都落在可视区内，没有横向滚开；列宽也和展开层级无关（`columnWidth`：同一侧栏宽度下先前量到的列宽）
    private func assertRowsFit(_ sidebar: Sidebar, columnWidth: CGFloat? = nil, _ context: String, file: StaticString = #filePath, line: UInt = #line) async {
        await settle(sidebar)
        let outline = sidebar.outline
        let clip = outline.enclosingScrollView!.contentView
        XCTAssertEqual(clip.bounds.minX, 0, "\(context)：不该横向滚开", file: file, line: line)
        XCTAssertEqual(outline.frame.width, clip.bounds.width, accuracy: 0.5, "\(context)：大纲视图要和可视区同宽", file: file, line: line)
        if let columnWidth { XCTAssertEqual(outline.outlineTableColumn!.width, columnWidth, accuracy: 0.5, "\(context)：列宽不该跟着展开层级变", file: file, line: line) }
        XCTAssertGreaterThan(outline.numberOfRows, 0, "\(context)：没有行可量", file: file, line: line)
        for r in 0..<outline.numberOfRows {
            guard let rowView = outline.rowView(atRow: r, makeIfNecessary: true), let field = field(ofRow: r, in: outline) else {
                XCTFail("\(context)：第 \(r) 行没建出来", file: file, line: line); continue
            }
            XCTAssertLessThanOrEqual(rowView.frame.maxX, clip.bounds.maxX + 0.5, "\(context)：行视图超出可视区「\(field.stringValue)」", file: file, line: line)
            XCTAssertLessThanOrEqual(field.convert(field.bounds, to: clip).maxX, clip.bounds.maxX + 0.5, "\(context)：文字框超出可视区「\(field.stringValue)」", file: file, line: line)
        }
    }

    // MARK: 用例

    /// 用户的路径：侧栏已经是这个宽度，然后才打开带大纲的文档
    func testLongNameTruncatesWhenOutlineExpandsAtAnyWidth() async {
        for width: CGFloat in [180, 199, 240, 300, 420] {
            let sidebar = await makeSidebar()
            setWidth(width, sidebar)
            let columnWidth = sidebar.outline.outlineTableColumn!.width
            await openLongFile(in: sidebar)
            await assertRowsFit(sidebar, columnWidth: columnWidth, "\(width) pt 时打开带大纲的文档")
            guard let r = row(titled: Self.longStem, in: sidebar.outline), let name = field(ofRow: r, in: sidebar.outline) else { return XCTFail("长名字文件行") }
            XCTAssertEqual(name.lineBreakMode, .byTruncatingTail)
            if width <= 240 { XCTAssertLessThan(name.frame.width, name.intrinsicContentSize.width, "\(width) pt 放不下整个名字：文字框要比文字窄，省略号才画得出来") }
            sidebar.workspace.window?.close()
        }
    }

    /// 拖动本身就会把列拉回贴合，所以这条修复前也过：它守的是列宽继续跟着侧栏走（比如以后有人把列宽写死）
    func testRowsFollowSidebarWhenResizing() async {
        let sidebar = await makeSidebar()
        await openLongFile(in: sidebar)
        for width: CGFloat in [199, 180, 300, 420, 240] {
            setWidth(width, sidebar)
            await assertRowsFit(sidebar, "拖到 \(width) pt")
        }
    }

    /// 反向：拖的时候文件夹是展开的，之后折叠——列不该因此变窄（名字提前省略、右边空一截）
    func testColumnKeepsWidthWhenCollapsingAfterResizing() async {
        let sidebar = await makeSidebar()
        let outline = sidebar.outline
        guard let notes = row(titled: "notes", in: outline).flatMap({ outline.item(atRow: $0) }) else { return XCTFail("notes 文件夹行") }
        outline.expandItem(notes)
        await waitUntil("notes 的子目录") { row(titled: "deep", in: outline) != nil }
        await settle(sidebar)
        setWidth(199, sidebar)
        await assertRowsFit(sidebar, "拖到 199 pt")
        let columnWidth = outline.outlineTableColumn!.width
        outline.collapseItem(notes)
        await assertRowsFit(sidebar, columnWidth: columnWidth, "拖完折叠文件夹")
    }

    func testRowsFitWhenExpandingFolders() async {
        let sidebar = await makeSidebar()
        let outline = sidebar.outline
        let columnWidth = outline.outlineTableColumn!.width
        guard let notes = row(titled: "notes", in: outline).flatMap({ outline.item(atRow: $0) }) else { return XCTFail("notes 文件夹行") }
        outline.expandItem(notes)
        await waitUntil("notes 的子目录") { row(titled: "deep", in: outline) != nil }
        await assertRowsFit(sidebar, columnWidth: columnWidth, "展开一层文件夹")
        outline.expandItem(row(titled: "deep", in: outline).flatMap { outline.item(atRow: $0) })
        await waitUntil("更深一层的长名字文件") { row(titled: "R05", in: outline) != nil }
        await assertRowsFit(sidebar, columnWidth: columnWidth, "展开两层文件夹")
        outline.collapseItem(notes)
        await assertRowsFit(sidebar, columnWidth: columnWidth, "折叠文件夹")
    }

    /// 折叠的侧栏里切了文档，再展开
    func testRowsFitWhenOutlineExpandsWhileSidebarCollapsed() async {
        let sidebar = await makeSidebar()
        let columnWidth = sidebar.outline.outlineTableColumn!.width
        sidebar.workspace.setSidebarCollapsed(true, animated: false)
        sidebar.workspace.window?.layoutIfNeeded()
        await openLongFile(in: sidebar)
        sidebar.workspace.setSidebarCollapsed(false, animated: false)
        await assertRowsFit(sidebar, columnWidth: columnWidth, "侧栏折叠时展开大纲，再展开侧栏")
    }

    func testRowsFitInFilterAndSearchResults() async {
        let sidebar = await makeSidebar()
        let outline = sidebar.outline
        let columnWidth = outline.outlineTableColumn!.width
        let index = FileIndex.index(for: tmp)
        await waitUntil("索引扫完") { !index.isScanning && index.relativePaths.count == 3 }
        sidebar.controller.setFilterText("R0", search: false)
        await waitUntil("筛选结果里的深层文件") { row(titled: "R05", in: outline) != nil }
        await assertRowsFit(sidebar, columnWidth: columnWidth, "筛选态")
        sidebar.controller.setFilterText("x", search: true)
        await waitUntil("搜索结果") { row(titled: Self.longStem, in: outline) != nil }
        await assertRowsFit(sidebar, columnWidth: columnWidth, "搜索结果")
    }
}
