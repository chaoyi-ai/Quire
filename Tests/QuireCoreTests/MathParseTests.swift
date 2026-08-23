import XCTest
@testable import QuireCore

final class MathParseTests: XCTestCase {
    let parser = MarkdownParser()

    func testDisplayMathBlock() {
        let doc = parser.parse("before\n\n$$\n\\int_0^1 x\\,dx = \\frac{1}{2}\n$$\n\nafter\n")
        XCTAssertEqual(doc.blocks.count, 3)
        guard case .math(let src) = doc.blocks[1].kind else { return XCTFail("\(doc.blocks[1].kind)") }
        XCTAssertEqual(src, "\\int_0^1 x\\,dx = \\frac{1}{2}")
        XCTAssertEqual(doc.blocks[1].sourceRange?.lineRange, 3...5)
        // 单行 $$...$$ 也算；内容里的 * 不会被当成强调（按原文取）
        let one = parser.parse("$$ a*b*c $$\n")
        guard case .math(let s2) = one.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(s2, "a*b*c")
    }

    func testInlineMathPandocRules() {
        func inlines(_ s: String) -> [Inline] {
            guard case .paragraph(let i) = parser.parse(s).blocks[0].kind else { return [] }
            return i
        }
        XCTAssertEqual(inlines("质能 $E=mc^2$ 方程"), [.text("质能 "), .inlineMath("E=mc^2"), .text(" 方程")])
        XCTAssertEqual(inlines("花了 $2 和 $3"), [.text("花了 $2 和 $3")], "美元不是公式：结尾 $ 前有空格 / 开头 $ 后接数字")
        XCTAssertEqual(inlines("$ x $ 不算"), [.text("$ x $ 不算")])
        XCTAssertEqual(inlines("两个 $a$ 和 $b$"), [.text("两个 "), .inlineMath("a"), .text(" 和 "), .inlineMath("b")])
        XCTAssertEqual(inlines("价格 $5$6"), [.text("价格 $5$6")], "结尾 $ 后面是数字 → 不算")
    }

    func testDisplayBlockWithSetextLookalikeAndEscapes() {
        // `=` 独占行、`\\` 换行、`-` 行在 $$ 块里都不能被 cmark 动
        let doc = parser.parse("$$\n\\begin{pmatrix} a \\\\ b \\end{pmatrix}\n=\n-x\n$$\n\nafter\n")
        XCTAssertEqual(doc.blocks.count, 2)
        guard case .math(let src) = doc.blocks[0].kind else { return XCTFail("\(doc.blocks[0].kind)") }
        XCTAssertEqual(src, "\\begin{pmatrix} a \\\\ b \\end{pmatrix}\n=\n-x")
        XCTAssertEqual(doc.blocks[0].sourceRange?.lineRange, 1...5)
        XCTAssertEqual(doc.blocks[1].sourceRange?.start.line, 7)
        // 代码围栏里的 $$ 不动
        let code = parser.parse("```\n$$\nx\n$$\n```\n")
        guard case .codeBlock(_, let c) = code.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(c, "$$\nx\n$$")
        // GitLab 风格 ```math
        guard case .math(let g) = parser.parse("```math\nE=mc^2\n```\n").blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(g, "E=mc^2")
    }

    func testMathOff() {
        var o = MarkdownParser.Options(); o.math = false
        let doc = MarkdownParser(options: o).parse("$$\nx\n$$\n\n$a$\n")
        guard case .paragraph = doc.blocks[0].kind else { return XCTFail() }
        guard case .paragraph(let i) = doc.blocks[1].kind else { return XCTFail() }
        XCTAssertEqual(i, [.text("$a$")])
    }

    func testHTMLExport() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let html = HTMLRenderer(theme: theme).render(parser.parse("$$\nx^2\n$$\n\n行内 $y$\n"))
        XCTAssertTrue(html.contains("<div class=\"math\">\\[x^2\\]</div>"))
        XCTAssertTrue(html.contains("<span class=\"math\">\\(y\\)</span>"))
        XCTAssertTrue(html.contains("mathjax"))
    }
}
