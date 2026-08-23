import XCTest
@testable import QuireCore

final class WikiLinkTests: XCTestCase {
    func testParse() {
        guard case .paragraph(let i) = MarkdownParser().parse("见 [[设计文档]] 与 [[docs/ROADMAP | 路线图]]s。\n").blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(i, [.text("见 "), .link(destination: "quire-wiki:设计文档", title: nil, children: [.text("设计文档")]), .text(" 与 "),
                           .link(destination: "quire-wiki:docs/ROADMAP", title: nil, children: [.text("路线图")]), .text("s。")])
        var o = MarkdownParser.Options(); o.wikilinks = false
        guard case .paragraph(let j) = MarkdownParser(options: o).parse("[[x]]\n").blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(j, [.text("[[x]]")])
    }
    func testResolveNearest() {
        let files = ["notes/a.md", "notes/sub/a.md", "a.md", "other/deep/a.md", "notes/B.MD"]
        XCTAssertEqual(WikiLink.resolve("a", candidates: files, fromDir: "notes"), "notes/a.md", "同目录优先")
        XCTAssertEqual(WikiLink.resolve("a", candidates: files, fromDir: "notes/sub"), "notes/sub/a.md")
        XCTAssertEqual(WikiLink.resolve("a", candidates: files, fromDir: "notes/x"), "notes/a.md", "父目录优先于旁支")
        XCTAssertEqual(WikiLink.resolve("b", candidates: files, fromDir: ""), "notes/B.MD", "不分大小写")
        XCTAssertEqual(WikiLink.resolve("sub/a", candidates: files, fromDir: ""), "notes/sub/a.md", "带路径")
        XCTAssertNil(WikiLink.resolve("nope", candidates: files, fromDir: ""))
        XCTAssertNil(WikiLink.resolve("../../etc/passwd", candidates: files, fromDir: ""), "越界路径不会匹配到根外")
    }
    func testExportPlain() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let html = HTMLRenderer(theme: theme).render(MarkdownParser().parse("[[目标 | 显示]]\n"))
        XCTAssertTrue(html.contains("<p>显示</p>")); XCTAssertFalse(html.contains("quire-wiki"))
    }
}
