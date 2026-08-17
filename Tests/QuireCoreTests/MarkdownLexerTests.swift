import XCTest
@testable import QuireCore

final class MarkdownLexerTests: XCTestCase {
    let lexer = MarkdownLexer()

    func tokens(_ s: String) -> [MarkdownLexer.Token] { var st = MarkdownLexer.State(); return lexer.tokenize(s, state: &st) }

    func assertKind(_ src: String, _ snippet: String, _ kind: MarkdownLexer.Kind, file: StaticString = #filePath, line: UInt = #line) {
        let ts = tokens(src)
        let r = (src as NSString).range(of: snippet)
        XCTAssertNotEqual(r.location, NSNotFound, file: file, line: line)
        let hit = ts.first { $0.kind == kind && $0.range.lowerBound <= r.location && $0.range.upperBound >= r.location + r.length }
        XCTAssertNotNil(hit, "「\(snippet)」应为 \(kind)，实际 \(ts.filter { $0.range.overlaps(r.location..<(r.location + r.length)) }.map { "\($0.kind)@\($0.range)" })", file: file, line: line)
    }

    func testBlocks() {
        assertKind("# 标题 一\n", "#", .marker)
        assertKind("# 标题 一\n", "标题 一", .heading)
        assertKind("## 二级 ##\n", "二级", .heading)
        assertKind("- 项目\n", "-", .marker)
        assertKind("- [x] 完成\n", "[x]", .marker)
        assertKind("12. 有序\n", "12.", .marker)
        assertKind("> 引用 **粗**\n", ">", .marker)
        assertKind("> 引用 **粗**\n", "引用", .quote)
        assertKind("> 引用 **粗**\n", "粗", .strong)
        assertKind("---\n", "---", .marker)
        assertKind("| a | b |\n|---|:-:|\n", "|---|:-:|", .tableDelim)
        assertKind("| a | b |\n", "|", .tableDelim)
        assertKind("    code\n", "code", .codeBlock)
    }

    func testFenceState() {
        let src = "```swift\nlet a = 1\n```\n\n正常 *斜体*\n"
        assertKind(src, "```", .marker)
        assertKind(src, "swift", .fenceInfo)
        assertKind(src, "let a = 1", .codeBlock)
        assertKind(src, "斜体", .emphasis)
        // 分段续扫：先扫开头两行，再用状态扫剩余
        var st = MarkdownLexer.State()
        _ = lexer.tokenize("```swift\nlet a = 1\n", state: &st)
        XCTAssertTrue(st.inFence)
        let rest = lexer.tokenize("```\n\n正常 *斜体*\n", base: 20, state: &st)
        XCTAssertFalse(st.inFence)
        XCTAssertTrue(rest.contains { $0.kind == .emphasis && $0.range.lowerBound >= 20 })
        // ~~~ 围栏与更长的闭合
        var st2 = MarkdownLexer.State()
        let t2 = lexer.tokenize("~~~\ncode\n````\n~~~~\nafter\n", state: &st2)
        XCTAssertFalse(st2.inFence)
        XCTAssertTrue(t2.contains { $0.kind == .codeBlock })
    }

    func testFrontMatter() {
        let src = "---\ntitle: x\n---\n# H\n"
        assertKind(src, "title: x", .frontMatter)
        assertKind(src, "H", .heading)
    }

    func testInlines() {
        let s = "文字 `code` **粗** *斜* ~~删~~ [链接](https://a.b) ![图](i.png) <b>x</b> <!-- c --> \\* 脚注[^1] https://x.y/z 结束"
        assertKind(s, "`code`", .codeSpan)
        assertKind(s, "粗", .strong)
        assertKind(s, "斜", .emphasis)
        assertKind(s, "删", .strike)
        assertKind(s, "[链接]", .linkText)
        assertKind(s, "(https://a.b)", .linkURL)
        assertKind(s, "![图]", .image)
        assertKind(s, "<b>", .html)
        assertKind(s, "<!-- c -->", .html)
        assertKind(s, "\\*", .escape)
        assertKind(s, "[^1]", .footnote)
        assertKind(s, "https://x.y/z", .linkURL)
    }

    func testNoFalseEmphasis() {
        // 2 * 3 * 4：星号两侧有空格，不是强调
        let ts = tokens("2 * 3 * 4\n")
        XCTAssertFalse(ts.contains { $0.kind == .emphasis })
        XCTAssertFalse(tokens("snake_case_name\n").contains { $0.kind == .emphasis && false })
    }

    func testThroughput() {
        let unit = "# 标题\n\n段落 **粗** *斜* `code` [l](u) 文字文字。\n\n- 项目一\n- 项目二\n\n```swift\nlet x = 1\n```\n\n"
        let src = String(repeating: unit, count: 4000) // ~500 KB
        let t0 = Date()
        var st = MarkdownLexer.State()
        let ts = lexer.tokenize(src, state: &st)
        let dt = Date().timeIntervalSince(t0)
        XCTAssertGreaterThan(ts.count, 10000)
        XCTAssertLessThan(dt, 1.5, "500KB 词法耗时 \(dt)s")
    }
}
