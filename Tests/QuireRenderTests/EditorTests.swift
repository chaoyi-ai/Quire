import XCTest
import AppKit
@testable import QuireRender
@testable import QuireCore

@MainActor
final class EditorTests: XCTestCase {
    var editor: EditorTextView!

    override func setUp() async throws {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        editor = EditorTextView(style: RenderStyle(theme: theme))
    }

    func attrs(_ snippet: String) -> [NSAttributedString.Key: Any] {
        let ns = editor.textStorage!.string as NSString
        let r = ns.range(of: snippet)
        XCTAssertNotEqual(r.location, NSNotFound, "\(snippet) 不在编辑器中")
        return editor.textStorage!.attributes(at: r.location, effectiveRange: nil)
    }

    func testHighlightAfterSetSource() {
        editor.setSource("# 标题\n\n段落 **粗** *斜* `code`\n\n```swift\nlet a = 1\n```\n")
        let e = editor.style.theme.colors.editor
        XCTAssertEqual(attrs("标题")[.foregroundColor] as? NSColor, e.markdownHeading.nsColor)
        XCTAssertTrue((attrs("粗")[.font] as! NSFont).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue((attrs("斜")[.font] as! NSFont).fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertEqual(attrs("`code`")[.foregroundColor] as? NSColor, e.markdownCode.nsColor)
        XCTAssertEqual(attrs("let a = 1")[.foregroundColor] as? NSColor, e.markdownCode.nsColor)
        XCTAssertEqual(editor.lineCount, 8)
        XCTAssertEqual(editor.lineNumber(at: 0), 1)
        XCTAssertEqual(editor.lineNumber(at: (editor.source as NSString).range(of: "let a").location), 6)
    }

    func testIncrementalHighlightOnTyping() {
        editor.setSource("普通文字\n\n第二段\n")
        var changed = 0
        editor.onTextChange = { changed += 1 }
        // 在第一段末尾输入 **x**
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.insertText(" **强调**", replacementRange: NSRange(location: 4, length: 0))
        XCTAssertTrue((attrs("强调")[.font] as! NSFont).fontDescriptor.symbolicTraits.contains(.bold))
        // 第二段不受影响，仍是正文颜色
        XCTAssertEqual(attrs("第二段")[.foregroundColor] as? NSColor, editor.style.foreground)
        XCTAssertGreaterThan(changed, 0)
    }

    func testFenceTogglePropagates() {
        editor.setSource("a\n\nb\n\nc\n")
        // 在开头插入 ``` 行 → 后面全部变代码
        editor.insertText("```\n", replacementRange: NSRange(location: 0, length: 0))
        let code = editor.style.theme.colors.editor.markdownCode.nsColor
        XCTAssertEqual(attrs("b")[.foregroundColor] as? NSColor, code)
        XCTAssertEqual(attrs("c")[.foregroundColor] as? NSColor, code)
        // 再在末尾闭合：不影响前面
        let end = (editor.source as NSString).length
        editor.insertText("```\n", replacementRange: NSRange(location: end, length: 0))
        XCTAssertEqual(attrs("b")[.foregroundColor] as? NSColor, code)
    }

    func testListContinuation() {
        editor.setSource("- 项目一")
        editor.setSelectedRange(NSRange(location: (editor.source as NSString).length, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.source, "- 项目一\n- ")
        // 空项目回车结束列表
        editor.insertNewline(nil)
        XCTAssertEqual(editor.source, "- 项目一\n\n")
        editor.setSource("3. 三")
        editor.setSelectedRange(NSRange(location: (editor.source as NSString).length, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.source, "3. 三\n4. ")
        editor.setSource("- [x] 完成")
        editor.setSelectedRange(NSRange(location: (editor.source as NSString).length, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.source, "- [x] 完成\n- [ ] ")
    }

    func testFenceAutoClose() {
        editor.setSource("```swift")
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.source, "```swift\n\n```")
        XCTAssertEqual(editor.selectedRange().location, 9)
    }

    func testWrapSelection() {
        editor.setSource("hello world")
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        editor.toggleBold(nil)
        XCTAssertEqual(editor.source, "hello **world**")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 8, length: 5))
        editor.setSource("x")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.insertLink(nil)
        XCTAssertEqual(editor.source, "x[链接文字](url)")
    }

    func testIndent() {
        editor.setSource("a\nb\n")
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        editor.insertTab(nil)
        XCTAssertEqual(editor.source, "  a\n  b\n")
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.source, "a\nb\n")
    }
}

@MainActor
final class IncrementalReaderTests: XCTestCase {
    func testReplaceBlocksMatchesFullRender() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let style = RenderStyle(theme: theme)
        let renderer = DocumentRenderer(style: style)
        let parser = MarkdownParser()
        let reader = ReaderTextView(style: style)
        let cases: [(String, String)] = [
            ("# A\n\np1\n\np2\n\np3\n", "# A\n\np1\n\np2 改\n\np3\n"),                     // 修改中间
            ("# A\n\np1\n\np2\n", "# A\n\np1\n\n插入\n\np2\n"),                             // 插入
            ("# A\n\np1\n\np2\n\np3\n", "# A\n\np3\n"),                                     // 删除多块
            ("p1\n", "p1\n\n```swift\nlet a = 1\n```\n"),                                    // 追加代码块
            ("# A\n\n| a | b |\n|--|--|\n| 1 | 2 |\n\nend\n", "# A\n\n| a | b |\n|--|--|\n| 1 | 3 |\n\nend\n"), // 表格
            ("x\n", ""),                                                                     // 清空
            ("", "新内容\n"),                                                                 // 从空
        ]
        for (a, b) in cases {
            let ra = renderer.render(parser.parse(a))
            reader.setRendered(ra, style: style)
            let docB = parser.parse(b)
            let (rb, diff) = renderer.render(docB, reusing: ra)
            reader.replaceBlocks(with: rb, diff: diff, previous: ra)
            let full = renderer.render(docB).attributed.string
            XCTAssertEqual(reader.textStorage!.string, full, "增量结果应与全量一致：\(a.debugDescription) → \(b.debugDescription)")
            XCTAssertEqual(reader.rendered?.blocks.count, docB.blocks.count)
        }
    }
}
