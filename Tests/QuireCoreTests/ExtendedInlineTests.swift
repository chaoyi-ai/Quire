import XCTest
@testable import QuireCore

final class ExtendedInlineTests: XCTestCase {
    func parse(_ s: String, _ configure: (inout ExtendedInlineOptions) -> Void) -> [Inline] {
        var o = MarkdownParser.Options(); configure(&o.extendedInline)
        guard case .paragraph(let i) = MarkdownParser(options: o).parse(s).blocks[0].kind else { return [] }
        return i
    }
    func testOffByDefault() {
        // 默认：==、^、:emoji: 都是普通文字；单波浪线按 GFM 本来就是删除线
        guard case .paragraph(let i) = MarkdownParser().parse("==a== ~b~ ^c^ :tada:\n").blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(i, [.text("==a== "), .strikethrough([.text("b")]), .text(" ^c^ :tada:")])
    }
    func testHighlightSubSupEmoji() {
        let i = parse("水 H~2~O 和 x^2^ 与 ==重点== :tada: 完", { $0.highlight = true; $0.subscriptText = true; $0.superscriptText = true; $0.emoji = true })
        XCTAssertEqual(i, [.text("水 H"), .subscript([.text("2")]), .text("O 和 x"), .superscript([.text("2")]), .text(" 与 "), .highlight([.text("重点")]), .text(" "), .text("🎉"), .text(" 完")])
    }
    func testStrikethroughStillWorksAndSpacesBlockSubscript() {
        let i = parse("~~删~~ a ~ b ~ c", { $0.subscriptText = true })
        XCTAssertEqual(i.first, .strikethrough([.text("删")]))
        XCTAssertEqual(i.last, .text(" a ~ b ~ c"))
    }
    func testUnderlineHTML() {
        let i = parse("前 <u>下划**粗**</u> 后", { $0.underline = true })
        XCTAssertEqual(i, [.text("前 "), .underline([.text("下划"), .strong([.text("粗")])]), .text(" 后")])
        let off = parse("<u>x</u>", { _ in })
        XCTAssertEqual(off, [.html("<u>"), .text("x"), .html("</u>")])
    }
    func testHTMLExport() {
        var o = MarkdownParser.Options(); o.extendedInline.highlight = true; o.extendedInline.superscriptText = true
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let html = HTMLRenderer(theme: theme).render(MarkdownParser(options: o).parse("==a== x^2^\n"))
        XCTAssertTrue(html.contains("<mark>a</mark>")); XCTAssertTrue(html.contains("x<sup>2</sup>"))
        XCTAssertEqual(HTMLToMarkdown.convert("<p><mark>a</mark> x<sup>2</sup> <u>u</u></p>"), "==a== x^2^ <u>u</u>\n")
    }
}
