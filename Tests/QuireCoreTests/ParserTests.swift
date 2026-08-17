import XCTest
@testable import QuireCore

final class ParserTests: XCTestCase {
    let parser = MarkdownParser()

    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSmallFixtureStructure() throws {
        let doc = parser.parse(try fixture("small"))
        let kinds = doc.blocks.map { b -> String in
            switch b.kind {
            case .frontMatter: "frontMatter"; case .heading(let l, _, _): "h\(l)"; case .paragraph: "p"
            case .codeBlock: "code"; case .mermaid: "mermaid"; case .blockQuote: "quote"; case .list(let o, _, _): o ? "ol" : "ul"
            case .table: "table"; case .thematicBreak: "hr"; case .html: "html"; case .image: "img"; case .footnoteDefinition: "fn"
            }
        }
        XCTAssertEqual(kinds, ["frontMatter", "h1", "p", "h2", "ul", "ol", "h2", "quote", "h2", "code", "mermaid", "h2", "table", "hr", "img", "html", "h2", "h2"])
    }

    func testFrontMatterAndLineOffsets() throws {
        let doc = parser.parse(try fixture("small"))
        guard case .frontMatter(let yaml) = doc.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(yaml, "title: Quire 示例\ntags: [markdown, macos]")
        XCTAssertEqual(doc.blocks[0].sourceRange?.lineRange, 1...4)
        // 首个标题在第 6 行（front matter 4 行 + 空行）
        XCTAssertEqual(doc.blocks[1].sourceRange?.start.line, 6)
    }

    func testInlines() throws {
        let doc = parser.parse("这是 **粗体**、*斜体*、~~删~~、`code`、[链接](https://e.com \"T\")。")
        guard case .paragraph(let inl) = doc.blocks[0].kind else { return XCTFail() }
        XCTAssertTrue(inl.contains(.strong([.text("粗体")])))
        XCTAssertTrue(inl.contains(.emphasis([.text("斜体")])))
        XCTAssertTrue(inl.contains(.strikethrough([.text("删")])))
        XCTAssertTrue(inl.contains(.code("code")))
        XCTAssertTrue(inl.contains(.link(destination: "https://e.com", title: "T", children: [.text("链接")])))
    }

    func testAutolink() {
        let doc = parser.parse("见 https://github.com/chaoyi-ai/Quire。以及 www.example.com/x) 和 (https://a.io/b(c)) 结尾。")
        guard case .paragraph(let inl) = doc.blocks[0].kind else { return XCTFail() }
        let links = inl.compactMap { if case .link(let d, _, _) = $0 { d } else { nil } }
        XCTAssertEqual(links, ["https://github.com/chaoyi-ai/Quire", "http://www.example.com/x", "https://a.io/b(c)"])
        // 不含链接的文本走快速路径
        let plain = parser.parse("普通文本 no links here")
        guard case .paragraph(let p) = plain.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(p, [.text("普通文本 no links here")])
    }

    func testTaskListAndNested() {
        let doc = parser.parse("- [x] done\n- [ ] todo\n  - nested\n")
        guard case .list(false, _, let items) = doc.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].checkbox, .checked)
        XCTAssertEqual(items[1].checkbox, .unchecked)
        XCTAssertEqual(items[1].blocks.count, 2) // 段落 + 嵌套列表
    }

    func testTable() {
        let doc = parser.parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n")
        guard case .table(let t) = doc.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(t.alignments, [.left, .center, .right])
        XCTAssertEqual(t.header.map(\.plainText), ["a", "b", "c"])
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.rows[1].map(\.plainText), ["4", "5", "6"])
    }

    func testMermaidAndCode() {
        let doc = parser.parse("```mermaid\ngraph TD\nA-->B\n```\n\n```swift title=\"x\"\nlet a = 1\n```\n\n```\nplain\n```\n")
        XCTAssertEqual(doc.blocks[0].kind, .mermaid(source: "graph TD\nA-->B"))
        XCTAssertEqual(doc.blocks[1].kind, .codeBlock(language: "swift title=\"x\"", code: "let a = 1"))
        XCTAssertEqual(doc.blocks[2].kind, .codeBlock(language: nil, code: "plain"))
    }

    func testStandaloneImagePromoted() {
        let doc = parser.parse("![alt](a.png \"t\")\n\n文字 ![inline](b.png) 文字\n")
        XCTAssertEqual(doc.blocks[0].kind, .image(source: "a.png", title: "t", alt: "alt"))
        guard case .paragraph = doc.blocks[1].kind else { return XCTFail("行内图片不应提升") }
    }

    func testOutlineAndHeadingIDs() throws {
        let doc = parser.parse(try fixture("small"))
        let ids = doc.outline.entries.map(\.id)
        XCTAssertEqual(ids, ["quire-示例文档", "列表", "引用", "代码", "表格", "重复标题", "重复标题-1"])
        XCTAssertEqual(doc.outline.entries[0].level, 1)
        XCTAssertEqual(doc.outline.entries[1].level, 2)
        XCTAssertEqual(HeadingIDGenerator.slug("Hello, World! Foo_bar-baz 1.2"), "hello-world-foo_bar-baz-12")
    }

    func testBlockEqualityIgnoresPosition() {
        let a = Block(kind: .paragraph([.text("x")]), sourceRange: SourceRange(start: .init(line: 1, column: 1), end: .init(line: 1, column: 2)))
        let b = Block(kind: .paragraph([.text("x")]), sourceRange: SourceRange(start: .init(line: 9, column: 1), end: .init(line: 9, column: 2)))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.contentHash, b.contentHash)
    }

    func testBlockDiff() {
        let old = parser.parse("# A\n\npara 1\n\npara 2\n\npara 3\n").blocks
        let new = parser.parse("# A\n\npara 1\n\npara 2 changed\n\ninserted\n\npara 3\n").blocks
        let d = BlockDiff.compute(old: old, new: new)
        XCTAssertEqual(d.oldChanged, 2..<3)
        XCTAssertEqual(d.newChanged, 2..<4)
        XCTAssertTrue(BlockDiff.compute(old: old, new: old).isEmpty)
    }

    func testEmptyAndWeirdInput() {
        XCTAssertTrue(parser.parse("").blocks.isEmpty)
        XCTAssertEqual(parser.parse("---\n").blocks.count, 1) // 单独 --- 是分割线
        _ = parser.parse("---\nno end front matter\n# still md")
        _ = parser.parse(String(repeating: "* ", count: 5000))
    }
}
