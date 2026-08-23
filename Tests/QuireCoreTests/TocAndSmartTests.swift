import XCTest
@testable import QuireCore

final class TocAndSmartTests: XCTestCase {
    func testTOCExpandsToNestedLinks() {
        let doc = MarkdownParser().parse("[TOC]\n\n# 一\n\n## 一点一\n\n### 深\n\n## 一点二\n\n# 二\n")
        guard case .list(let ordered, _, let items) = doc.blocks[0].kind else { return XCTFail("\(doc.blocks[0].kind)") }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 2)
        guard case .paragraph(let p) = items[0].blocks[0].kind, case .link(let dest, _, let c) = p[0] else { return XCTFail() }
        XCTAssertEqual(dest, "#一"); XCTAssertEqual(c.plainText, "一")
        guard case .list(_, _, let sub) = items[0].blocks[1].kind else { return XCTFail("缺子列表") }
        XCTAssertEqual(sub.count, 2)
        guard case .list(_, _, let deep) = sub[0].blocks[1].kind else { return XCTFail("缺三级") }
        XCTAssertEqual(deep.count, 1)
        // 关掉就是普通段落
        var o = MarkdownParser.Options(); o.toc = false
        guard case .paragraph = MarkdownParser(options: o).parse("[TOC]\n\n# x\n").blocks[0].kind else { return XCTFail() }
    }
    func testSmartPunctuation() {
        var o = MarkdownParser.Options(); o.smartPunctuation = true
        guard case .paragraph(let p) = MarkdownParser(options: o).parse("\"Hi\" -- ok...\n").blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(p.plainText, "“Hi” – ok…")
        guard case .paragraph(let q) = MarkdownParser().parse("\"Hi\" -- ok...\n").blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(q.plainText, "\"Hi\" -- ok...")
    }
}
