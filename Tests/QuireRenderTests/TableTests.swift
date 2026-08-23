import XCTest
@testable import QuireRender
@testable import QuireCore

final class TableTests: XCTestCase {
    func testDistributeFits() {
        XCTAssertEqual(TableLayout.distribute(natural: [100, 200], minimum: [40, 40], available: 400), [100, 200])
    }
    func testDistributeShrinksProportionally() {
        let w = TableLayout.distribute(natural: [100, 300], minimum: [50, 50], available: 300)
        XCTAssertEqual(w.reduce(0, +), 300, accuracy: 2)
        XCTAssertGreaterThan(w[1], w[0])
        XCTAssertGreaterThanOrEqual(w[0], 50)
    }
    func testDistributeBelowMinimumScales() {
        let w = TableLayout.distribute(natural: [200, 200], minimum: [150, 150], available: 200)
        XCTAssertEqual(w.reduce(0, +), 200, accuracy: 2)
        XCTAssertEqual(w[0], w[1])
    }
    func testLongColumnDoesNotStarveOthers() {
        // 一列超长文本 + 两列短 CJK：短列不该被压到最小
        let w = TableLayout.distribute(natural: [80, 90, 2000], minimum: [60, 60, 200], available: 700)
        XCTAssertEqual(w.reduce(0, +), 700, accuracy: 3)
        XCTAssertGreaterThan(w[0], 60)
        XCTAssertGreaterThan(w[1], 60)
    }
    func testAttachmentBuiltAndLaidOut() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let r = DocumentRenderer(theme: theme).render(MarkdownParser().parse("| a | b |\n|--|--|\n| 1 | 一段较长的中文内容用于换行测试 |\n"))
        var att: TableAttachment?
        r.attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: r.attributed.length)) { v, _, _ in if let t = v as? TableAttachment { att = t } }
        let a = try! XCTUnwrap(att)
        XCTAssertEqual(a.header.count, 2)
        XCTAssertEqual(a.rows.count, 1)
        let wide = a.layout(available: 700)
        XCTAssertLessThanOrEqual(wide.width, 700)
        XCTAssertEqual(wide.rowHeights.count, 2)
        let narrow = a.layout(available: 200)
        XCTAssertLessThanOrEqual(narrow.width, 200)
        XCTAssertGreaterThan(narrow.rowHeights[1], wide.rowHeights[1], "窄表应换行变高")
    }

    /// 单行单元格：行高按 lineHeight + 内边距，文字自然高度更小，绘制时必须垂直居中（textHeights 供绘制用）
    func testSingleLineCellTextHeightsForCentering() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let renderer = DocumentRenderer(theme: theme)
        let r = renderer.render(MarkdownParser().parse("| a | b |\n|--|--|\n| 1 | 2 |\n"))
        var att: TableAttachment?
        r.attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: r.attributed.length)) { v, _, _ in if let t = v as? TableAttachment { att = t } }
        let a = try! XCTUnwrap(att)
        let layout = a.layout(available: 700)
        let padV = renderer.style.tableCellPadding.vertical
        XCTAssertEqual(layout.textHeights.count, 2)
        XCTAssertEqual(layout.textHeights[1].count, 2)
        for row in 0..<2 {
            XCTAssertEqual(layout.rowHeights[row], renderer.style.lineHeight + padV * 2, "单行行高 = lineHeight + 2·padV")
            for th in layout.textHeights[row] {
                XCTAssertGreaterThan(th, 0)
                XCTAssertLessThan(th, renderer.style.lineHeight, "文字自然高度小于 lineHeight → 需要居中偏移")
            }
        }
    }
}

final class AttachmentAccessibilityTests: XCTestCase {
    func testAttachmentsCarryDescriptions() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let md = "| a | b |\n|--|--|\n| 1 | 2 |\n\n![一张图](x.png)\n\n```mermaid\ngraph TD\nA-->B\n```\n"
        let r = DocumentRenderer(theme: theme).render(MarkdownParser().parse(md))
        var descs: [String] = []
        r.attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: r.attributed.length)) { v, _, _ in
            if let a = v as? NSTextAttachment, let d = a.image?.accessibilityDescription { descs.append(d) }
        }
        // CI 上没有 mermaid.min.js 时 Mermaid 退化为代码块（无附件），所以只要求表格与图片
        XCTAssertGreaterThanOrEqual(descs.count, 2)
        XCTAssertTrue(descs[0].contains("a\tb"), descs[0])
        XCTAssertTrue(descs[0].contains("1\t2"))
        XCTAssertEqual(descs[1], "一张图")
        if descs.count > 2 { XCTAssertTrue(descs[2].contains("graph TD")) }
    }
}

final class TableFindMirrorTests: XCTestCase {
    func testTableTextIsSearchableAndInvisible() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let r = DocumentRenderer(theme: theme).render(MarkdownParser().parse("| 指标 | 值 |\n|--|--|\n| 解析 | 42 ms |\n\n后文\n"))
        let s = r.attributed.string
        let range = (s as NSString).range(of: "解析\t42 ms")
        XCTAssertNotEqual(range.location, NSNotFound, "表格文本在 textStorage 里（可被 ⌘F 找到）")
        let attrs = r.attributed.attributes(at: range.location, effectiveRange: nil)
        XCTAssertEqual((attrs[.font] as? NSFont)?.pointSize ?? 1, 0.01, accuracy: 0.001)
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, .clear)
        // 镜像与附件在同一段落（同一行片段），后文仍独立
        XCTAssertTrue(s.contains("\u{FFFC}指标\t值\u{2028}解析\t42 ms\n"))
    }
}
