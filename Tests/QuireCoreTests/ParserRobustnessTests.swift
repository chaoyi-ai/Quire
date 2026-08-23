import XCTest
@testable import QuireCore

/// 全仓 review 发现的解析器静默失效：CRLF、`\$` 转义、`[[TOC]]`、单波浪线
final class ParserRobustnessTests: XCTestCase {
    func testCRLFKeepsDisplayMathAndSubscript() {
        var o = MarkdownParser.Options(); o.extendedInline.subscriptText = true
        let p = MarkdownParser(options: o)
        let crlf = "# T\r\n\r\n$$\r\nx^2\r\n$$\r\n\r\nH~2~O 与 $a+b$\r\n"
        let doc = p.parse(crlf)
        XCTAssertEqual(doc.blocks.count, 3)
        guard case .math(let m) = doc.blocks[1].kind else { return XCTFail("\(doc.blocks[1].kind)") }
        XCTAssertEqual(m, "x^2")
        guard case .paragraph(let inl) = doc.blocks[2].kind else { return XCTFail() }
        XCTAssertTrue(inl.contains { if case .subscript = $0 { true } else { false } }, "\(inl)")
        XCTAssertTrue(inl.contains { if case .inlineMath("a+b") = $0 { true } else { false } }, "\(inl)")
        // 与 LF 版本完全一致
        let lf = p.parse(crlf.replacingOccurrences(of: "\r\n", with: "\n"))
        XCTAssertEqual(doc.blocks, lf.blocks)
    }

    func testEscapedDollarIsLiteral() {
        let p = MarkdownParser()
        let doc = p.parse("价格 \\$5 和 \\$10，公式 $x$，代码 `\\$y`\n")
        guard case .paragraph(let inl) = doc.blocks[0].kind else { return XCTFail() }
        XCTAssertFalse(inl.contains { if case .inlineMath("5 和 \\") = $0 { true } else { false } })
        XCTAssertEqual(inl.plainText.contains("$5"), true, inl.plainText)
        XCTAssertTrue(inl.contains { if case .inlineMath("x") = $0 { true } else { false } }, "\(inl)")
        XCTAssertTrue(inl.contains { if case .code("\\$y") = $0 { true } else { false } }, "\(inl)")
        // 数学关掉：不动
        var o = MarkdownParser.Options(); o.math = false
        guard case .paragraph(let raw) = MarkdownParser(options: o).parse("a \\$b\n").blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(raw.plainText, "a $b")
    }

    func testDisplayMathInsideListItemStaysInList() {
        let doc = MarkdownParser().parse("- 项\n\n  $$\n  x\n  $$\n\n- 项二\n")
        XCTAssertEqual(doc.blocks.count, 1, "\(doc.blocks.map { $0.kind })")
        guard case .list(_, _, let items) = doc.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].blocks.contains { if case .math = $0.kind { true } else { false } }, "\(items[0].blocks.map { $0.kind })")
    }

    func testDoubleBracketTOCWorksWithWikilinks() {
        let doc = MarkdownParser().parse("[[TOC]]\n\n# A\n\n## B\n")
        guard case .list = doc.blocks[0].kind else { return XCTFail("\(doc.blocks[0].kind)") }
    }

    func testSingleTildeIsSubscriptOnlyWhenEnabled() {
        let plain = MarkdownParser().parse("H~2~O ~~del~~\n")
        guard case .paragraph(let a) = plain.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(a.filter { if case .strikethrough = $0 { true } else { false } }.count, 2)
        var o = MarkdownParser.Options(); o.extendedInline.subscriptText = true
        guard case .paragraph(let b) = MarkdownParser(options: o).parse("H~2~O ~~del~~\n").blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(b.filter { if case .subscript = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(b.filter { if case .strikethrough = $0 { true } else { false } }.count, 1)
    }
}
