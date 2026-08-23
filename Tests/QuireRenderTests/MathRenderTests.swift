import XCTest
import AppKit
@testable import QuireRender
@testable import QuireCore

final class MathRenderTests: XCTestCase {
    func testBlockAndInlineAttachments() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let r = DocumentRenderer(theme: theme).render(MarkdownParser().parse("$$\n\\frac{a}{b}\n$$\n\n行内 $x^2$ 公式\n"))
        var atts: [MathAttachment] = []
        r.attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: r.attributed.length)) { v, _, _ in if let m = v as? MathAttachment { atts.append(m) } }
        XCTAssertEqual(atts.count, 2)
        XCTAssertTrue(atts[0].isDisplay); XCTAssertFalse(atts[1].isDisplay)
        XCTAssertNotNil(atts[0].image); XCTAssertGreaterThan(atts[0].bounds.height, 10)
        XCTAssertLessThan(atts[1].bounds.origin.y, 0, "行内公式按基线下沉 descent")
        XCTAssertEqual(atts[0].image?.accessibilityDescription?.contains("\\frac"), true)
    }

    func testBadLatexFallsBackToSource() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let r = DocumentRenderer(theme: theme).render(MarkdownParser().parse("$$\n\\frac{a}{\n$$\n"))
        XCTAssertTrue(r.attributed.string.contains("\\frac{a}{"))
        XCTAssertTrue(r.attributed.string.contains("% "), "带错误说明")
    }

    func testLargeFileModeSkipsRendering() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        var o = RenderOptions(); o.largeFile = true
        let r = DocumentRenderer(style: RenderStyle(theme: theme, options: o)).render(MarkdownParser().parse("$$\nx\n$$\n\n$y$\n"))
        var n = 0
        r.attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: r.attributed.length)) { v, _, _ in if v is MathAttachment { n += 1 } }
        XCTAssertEqual(n, 0)
        XCTAssertTrue(r.attributed.string.contains("$y$"))
    }
}
