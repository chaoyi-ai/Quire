import XCTest
import AppKit
@testable import QuireRender
@testable import QuireCore

/// 阅读版式（M8 #86 / #87）：版式覆盖主题、零值跟随主题、预设匹配、编解码
final class ReadingLayoutTests: XCTestCase {
    private var theme: Theme { ThemeStore.loadBuiltIn().theme(id: "github-light")! }

    func testFollowThemeChangesNothing() {
        let base = RenderStyle(theme: theme)
        let s = RenderStyle(theme: theme, options: RenderOptions().applying(.followTheme))
        XCTAssertEqual(s.lineHeight, base.lineHeight)
        XCTAssertEqual(s.paragraphSpacing, base.paragraphSpacing)
        XCTAssertEqual(s.maxContentWidth, base.maxContentWidth)
        XCTAssertEqual(s.bodyFont, base.bodyFont)
        XCTAssertFalse(s.justified)
        XCTAssertTrue(ReadingLayout.followTheme.isFollowingTheme)
    }

    func testExplicitValuesOverrideTheme() {
        let l = ReadingLayout(fontSize: 20, weight: .semibold, lineHeight: 2.0, paragraphSpacing: 1.5, contentWidth: 620, alignment: .justified)
        let s = RenderStyle(theme: theme, options: RenderOptions().applying(l))
        XCTAssertEqual(s.baseSize, 20)
        XCTAssertEqual(s.lineHeight, 40)
        XCTAssertEqual(s.paragraphSpacing, 30)
        XCTAssertEqual(s.maxContentWidth, 620)
        XCTAssertTrue(s.justified)
        // 系统字体有 semibold：正文字重应比常规重
        let w = (s.bodyFont.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? Double ?? 0
        XCTAssertGreaterThan(w, 0.1)
        // 不限宽
        XCTAssertEqual(RenderStyle(theme: theme, options: RenderOptions().applying(ReadingLayout(contentWidth: 0))).maxContentWidth, 0)
    }

    func testJustifiedOnlyForBodyParagraphs() {
        let l = ReadingLayout(alignment: .justified)
        let style = RenderStyle(theme: theme, options: RenderOptions().applying(l))
        let doc = DocumentRenderer(style: style).render(MarkdownParser().parse("# 标题\n\n一段正文。\n\n- 列表项\n\n> 引用段\n\n```\ncode\n```\n"))
        func alignment(ofBlock i: Int) -> NSTextAlignment? {
            (doc.attributed.attribute(.paragraphStyle, at: doc.ranges[i].location, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        }
        XCTAssertNotEqual(alignment(ofBlock: 0), .justified, "标题不两端对齐")
        XCTAssertEqual(alignment(ofBlock: 1), .justified, "正文段落两端对齐")
        XCTAssertNotEqual(alignment(ofBlock: 2), .justified, "列表项不两端对齐")
        XCTAssertEqual(alignment(ofBlock: 3), .justified, "引用里的段落两端对齐")
        XCTAssertNotEqual(alignment(ofBlock: 4), .justified, "代码块不两端对齐")
    }

    func testPresetsAndCodable() throws {
        XCTAssertEqual(ReadingLayoutPreset.matching(.followTheme, user: [])?.id, "standard")
        let large = ReadingLayoutPreset.builtIn.first { $0.id == "large" }!
        XCTAssertEqual(ReadingLayoutPreset.matching(large.layout, user: [])?.id, "large")
        let mine = ReadingLayoutPreset(id: "u1", name: "夜读", layout: ReadingLayout(fontSize: 18))
        XCTAssertEqual(ReadingLayoutPreset.matching(mine.layout, user: [mine])?.name, "夜读")
        XCTAssertNil(ReadingLayoutPreset.matching(ReadingLayout(fontSize: 19), user: [mine]))
        let data = try JSONEncoder().encode([large, mine])
        let back = try JSONDecoder().decode([ReadingLayoutPreset].self, from: data)
        XCTAssertEqual(back, [large, mine])
        // 旧版本存的 JSON 少字段也能读（新字段用默认值）
        let old = try JSONDecoder().decode(ReadingLayout.self, from: Data(#"{"bodyFontFamily":"Georgia","codeFontFamily":"","fontSize":17,"weight":0,"lineHeight":0,"paragraphSpacing":0,"contentWidth":-1,"alignment":0}"#.utf8))
        XCTAssertEqual(old.bodyFontFamily, "Georgia"); XCTAssertEqual(old.fontSize, 17); XCTAssertEqual(old.alignment, .theme)
    }
}
