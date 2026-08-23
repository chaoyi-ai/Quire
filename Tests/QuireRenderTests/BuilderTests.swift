import XCTest
import AppKit
@testable import QuireRender
@testable import QuireCore

final class BuilderTests: XCTestCase {
    var style: RenderStyle!
    var renderer: DocumentRenderer!

    override func setUp() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        style = RenderStyle(theme: theme)
        renderer = DocumentRenderer(style: style)
    }

    func render(_ md: String) -> NSAttributedString {
        renderer.render(MarkdownParser().parse(md)).attributed
    }

    func attrs(_ s: NSAttributedString, of snippet: String) -> [NSAttributedString.Key: Any] {
        let r = (s.string as NSString).range(of: snippet)
        XCTAssertNotEqual(r.location, NSNotFound, "\(snippet) 不在输出中：\(s.string)")
        return s.attributes(at: r.location, effectiveRange: nil)
    }

    func testInlineStyles() {
        let s = render("普通 **粗** *斜* ~~删~~ `码` [链](https://a.b)")
        let bold = attrs(s, of: "粗")[.font] as! NSFont
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold), "粗体缺失")
        let italic = attrs(s, of: "斜")[.font] as! NSFont
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic), "斜体缺失：\(italic)")
        XCTAssertEqual(attrs(s, of: "删")[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(attrs(s, of: "码")[QuireAttribute.inlineCode] as? Bool, true)
        XCTAssertNil(attrs(s, of: "码")[.backgroundColor], "行内代码背景由片段自绘，不用 .backgroundColor")
        XCTAssertNotNil(attrs(s, of: "链")[.link])
        XCTAssertEqual(attrs(s, of: "链")[.foregroundColor] as? NSColor, style.accent)
        // 普通文字：正文字体与前景色，且带段落样式与角色
        let plain = attrs(s, of: "普通")
        XCTAssertEqual(plain[.font] as? NSFont, style.bodyFont)
        XCTAssertEqual(plain[QuireAttribute.blockRole] as? Int, BlockRole.body.rawValue)
        XCTAssertNotNil(plain[.paragraphStyle])
    }

    func testHeadingAndCode() {
        let s = render("# 标题\n\n```swift\nlet x = 1 // c\n```\n")
        let h = attrs(s, of: "标题")
        XCTAssertEqual(h[QuireAttribute.blockRole] as? Int, BlockRole.heading.rawValue)
        XCTAssertEqual(h[QuireAttribute.headingLevel] as? Int, 1)
        XCTAssertEqual((h[.font] as? NSFont)?.pointSize, style.headingFont(level: 1).pointSize)
        let kw = attrs(s, of: "let")
        XCTAssertEqual(kw[.foregroundColor] as? NSColor, style.syntaxColor(.keyword))
        XCTAssertEqual(kw[QuireAttribute.blockRole] as? Int, BlockRole.codeBlock.rawValue)
        XCTAssertEqual(kw[QuireAttribute.codeLanguage] as? String, "swift")
        XCTAssertEqual(attrs(s, of: "// c")[.foregroundColor] as? NSColor, style.syntaxColor(.comment))
        // 代码块内换行是 U+2028
        XCTAssertFalse(s.string.contains("let x = 1 // c\n\n"))
    }

    func testListMarkerCarriesParagraphStyle() {
        let s = render("- a\n  - b\n")
        let m = attrs(s, of: "•")
        let ps = m[.paragraphStyle] as? NSParagraphStyle
        XCTAssertNotNil(ps, "列表标记必须带段落样式")
        XCTAssertEqual(ps?.headIndent ?? 0, (style.baseSize * 1.75).rounded())
        let nested = attrs(s, of: "◦")[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(nested?.headIndent ?? 0, (style.baseSize * 1.75).rounded() * 2)
    }

    func testRangesAndIncremental() {
        let doc = MarkdownParser().parse("# A\n\np1\n\np2\n\np3\n")
        let r = renderer.render(doc)
        XCTAssertEqual(r.blocks.count, 4)
        XCTAssertEqual(r.ranges.map(\.length).reduce(0, +), r.attributed.length)
        XCTAssertEqual(r.blockIndex(at: r.ranges[2].location + 1), 2)
        let doc2 = MarkdownParser().parse("# A\n\np1\n\np2 changed\n\np3\n")
        let (r2, diff) = renderer.render(doc2, reusing: r)
        XCTAssertEqual(diff.oldChanged, 2..<3)
        XCTAssertTrue(r2.blocks[1].attributed === r.blocks[1].attributed, "未变化块应复用")
        XCTAssertEqual(r2.attributed.string, renderer.render(doc2).attributed.string)
    }

    func testThemeSwitchKeepsText() {
        let doc = MarkdownParser().parse("# A\n\n**b** `c`\n")
        let light = renderer.render(doc)
        let dark = DocumentRenderer(theme: ThemeStore.loadBuiltIn().theme(id: "github-dark")!).render(doc)
        XCTAssertEqual(light.attributed.string, dark.attributed.string)
        XCTAssertNotEqual(attrs(light.attributed, of: "b")[.foregroundColor] as? NSColor, attrs(dark.attributed, of: "b")[.foregroundColor] as? NSColor)
    }
}

extension BuilderTests {
    func testStrikeAfterFootnoteRendered() {
        let s = render("正文[^1] 以及 ~~删除~~ 与 *斜体*。\n\n[^1]: 脚注内容。\n")
        let a = attrs(s, of: "删除")
        XCTAssertEqual(a[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue, "\(a)")
    }
}

final class DropSupportTests: XCTestCase {
    func testRelativePath() {
        let doc = URL(fileURLWithPath: "/Users/me/notes/a/doc.md")
        XCTAssertEqual(DropSupport.relativePath(of: URL(fileURLWithPath: "/Users/me/notes/a/img/x y.png"), to: doc), "img/x%20y.png")
        XCTAssertEqual(DropSupport.relativePath(of: URL(fileURLWithPath: "/Users/me/notes/b/x.png"), to: doc), "../b/x.png")
        XCTAssertEqual(DropSupport.relativePath(of: URL(fileURLWithPath: "/tmp/x.png"), to: nil), "/tmp/x.png")
        XCTAssertTrue(DropSupport.isMarkdown(URL(fileURLWithPath: "/a/b.MD")))
        XCTAssertTrue(DropSupport.isImage(URL(fileURLWithPath: "/a/b.webp")))
    }
}

final class FontOverrideTests: XCTestCase {
    func testRenderOptionsOverrideFonts() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let base = RenderStyle(theme: theme)
        var o = RenderOptions(); o.bodyFontFamily = "Georgia"; o.codeFontFamily = "Courier New"; o.baseFontSize = 20
        let s = RenderStyle(theme: theme, options: o)
        XCTAssertEqual(s.bodyFont.familyName, "Georgia")
        XCTAssertEqual(s.codeFont.familyName, "Courier New")
        XCTAssertEqual(s.baseSize, 20)
        XCTAssertEqual(s.headingFonts[0].familyName, "Georgia")
        // 不存在的字体族 → 落回主题
        var bad = RenderOptions(); bad.bodyFontFamily = "No Such Font Family 123"
        XCTAssertEqual(RenderStyle(theme: theme, options: bad).bodyFont.familyName, base.bodyFont.familyName)
    }
}

final class ImageWidthTests: XCTestCase {
    func testParseImgTag() {
        let r = AttributedStringBuilder.parseImgTag("<p align=\"center\">\n<img src=\"docs/a.png\" width=\"300\" alt=\"图\">\n</p>")
        XCTAssertEqual(r?.src, "docs/a.png"); XCTAssertEqual(r?.alt, "图"); XCTAssertEqual(r?.width, .points(300))
        XCTAssertEqual(AttributedStringBuilder.parseImgTag("<img src=x.png width=50%>")?.width, .fraction(0.5))
        XCTAssertNil(AttributedStringBuilder.parseImgTag("<div>text <img src=\"a.png\"></div>"), "有别的内容不算")
        XCTAssertNil(AttributedStringBuilder.parseImgTag("<img src=\"a.png\"><img src=\"b.png\">"))
    }
    func testWidthAttributeAfterImage() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let r = DocumentRenderer(theme: theme).render(MarkdownParser().parse("看图 ![alt](a.png){width=50%} 后面\n\n<img src=\"b.png\" width=\"120px\">\n"))
        var widths: [ImageAttachment.RequestedWidth?] = []
        r.attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: r.attributed.length)) { v, _, _ in if let a = v as? ImageAttachment { widths.append(a.requestedWidth) } }
        XCTAssertEqual(widths.count, 2)
        XCTAssertEqual(widths[0], .fraction(0.5)); XCTAssertEqual(widths[1], .points(120))
        XCTAssertFalse(r.attributed.string.contains("{width"), "属性不显示")
        XCTAssertTrue(r.attributed.string.contains(" 后面"))
    }
}
