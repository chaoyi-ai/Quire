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

    /// 在围栏内 / front matter 内编辑一行：增量高亮要拿到正确的行首状态（不能把围栏内的文字当正文重新着色）
    func testEditInsideFenceKeepsCodeState() {
        editor.setSource("---\ntitle: x\n---\n\n# 标题\n\n```swift\nlet a = 1\nlet b = 2\n```\n\n尾段 **粗**\n")
        let code = editor.style.theme.colors.editor.markdownCode.nsColor
        XCTAssertEqual(attrs("let b = 2")[.foregroundColor] as? NSColor, code)
        // 在围栏内第二行末尾输入
        let loc = (editor.source as NSString).range(of: "let b = 2").upperBound
        editor.setSelectedRange(NSRange(location: loc, length: 0))
        editor.insertText(" // c", replacementRange: NSRange(location: loc, length: 0))
        XCTAssertEqual(attrs("let b = 2 // c")[.foregroundColor] as? NSColor, code)
        XCTAssertEqual(attrs("let a = 1")[.foregroundColor] as? NSColor, code)
        // 围栏外仍是正文/粗体
        XCTAssertTrue((attrs("粗")[.font] as! NSFont).fontDescriptor.symbolicTraits.contains(.bold))
        // 在 front matter 里编辑：不当作标题
        let fm = (editor.source as NSString).range(of: "title: x").upperBound
        editor.insertText("y", replacementRange: NSRange(location: fm, length: 0))
        XCTAssertNotEqual(attrs("title: xy")[.foregroundColor] as? NSColor, editor.style.theme.colors.editor.markdownHeading.nsColor)
        XCTAssertEqual(attrs("标题")[.foregroundColor] as? NSColor, editor.style.theme.colors.editor.markdownHeading.nsColor)
        // 行索引仍正确
        XCTAssertEqual(editor.lineNumber(at: (editor.source as NSString).range(of: "尾段").location), 12)
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
        XCTAssertEqual(editor.source, "x[\(RL("链接文字"))](url)")   // 占位文字随界面语言
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

@MainActor
final class TextViewSizingTests: XCTestCase {
    /// 回归：代码创建的 NSTextView 默认 maxSize == 初始 frame，会把长文档卡在首屏
    func testTextViewsCanGrowBeyondInitialFrame() {
        let style = RenderStyle(theme: ThemeStore.loadBuiltIn().theme(id: "github-light")!)
        let reader = ReaderTextView(style: style)
        XCTAssertGreaterThan(reader.maxSize.height, 1_000_000)
        let editor = EditorTextView(style: style)
        XCTAssertGreaterThan(editor.maxSize.height, 1_000_000)
        // 长文档：frame 高度必须随内容增长
        let long = String(repeating: "段落文字 paragraph text.\n\n", count: 400)
        let doc = MarkdownParser().parse(long)
        reader.setRendered(DocumentRenderer(style: style).render(doc), style: style)
        reader.textLayoutManager?.ensureLayout(for: reader.textLayoutManager!.documentRange)
        reader.sizeToFit()
        XCTAssertGreaterThan(reader.frame.height, 2000, "长文档文本视图应远高于初始 600pt")
    }
}

@MainActor
final class HangingMarkerTests: XCTestCase {
    func testMarkerPrefix() {
        func p(_ s: String) -> (Int, Int) { EditorTextView.markerPrefix(s as NSString, NSRange(location: 0, length: (s as NSString).length)) }
        XCTAssertEqual(p("# 标题").0, 0); XCTAssertEqual(p("# 标题").1, 2)
        XCTAssertEqual(p("### h3").1, 4)
        XCTAssertEqual(p("#no").1, 0)
        XCTAssertEqual(p("- item").1, 2)
        XCTAssertEqual(p("  - nested").0, 2); XCTAssertEqual(p("  - nested").1, 2)
        XCTAssertEqual(p("10. ten").1, 4)
        XCTAssertEqual(p("1) one").1, 3)
        XCTAssertEqual(p("> > quote").1, 4)
        XCTAssertEqual(p(">quote").1, 1)
        XCTAssertEqual(p("plain").1, 0)
        XCTAssertEqual(p("    code").1, 0, "4 空格缩进代码不算")
    }

    func testHangingIndentsApplied() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let editor = EditorTextView(style: RenderStyle(theme: theme))
        editor.hangingMarkers = true
        editor.setSource("# 标题\n正文段落\n- 列表项\n  - 嵌套\n")
        let ns = editor.textStorage!.string as NSString
        func ps(_ snippet: String) -> NSParagraphStyle {
            editor.textStorage!.attribute(.paragraphStyle, at: ns.range(of: snippet).location, effectiveRange: nil) as! NSParagraphStyle
        }
        let col = ps("正文段落").headIndent
        XCTAssertGreaterThan(col, 0, "普通段落退到列宽")
        XCTAssertEqual(ps("正文段落").firstLineHeadIndent, col)
        XCTAssertEqual(ps("# 标题").headIndent, col)
        XCTAssertLessThan(ps("# 标题").firstLineHeadIndent, col, "标题的 # 出挑")
        XCTAssertEqual(ps("- 列表项").headIndent, col)
        XCTAssertGreaterThan(ps("  - 嵌套").headIndent, col, "嵌套项正文更深")
        XCTAssertEqual(ps("  - 嵌套").headIndent - ps("  - 嵌套").firstLineHeadIndent, ps("- 列表项").headIndent - ps("- 列表项").firstLineHeadIndent, "标记宽一致")
        // 关掉：全部回到 0
        editor.hangingMarkers = false
        XCTAssertEqual(ps("# 标题").firstLineHeadIndent, 0)
        XCTAssertEqual(ps("正文段落").headIndent, 0)
    }
}

@MainActor
final class FocusModeTests: XCTestCase {
    func testSentenceAndParagraphRanges() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let editor = EditorTextView(style: RenderStyle(theme: theme))
        editor.setSource("第一句。第二句！Third sentence here. Fourth?\n\n下一段。\n")
        let ns = editor.textStorage!.string as NSString
        // 光标在"第二句"中
        editor.setSelectedRange(NSRange(location: ns.range(of: "第二句").location + 1, length: 0))
        let s = editor.focusRange(for: .sentence)!
        XCTAssertEqual(ns.substring(with: s).trimmingCharacters(in: .whitespaces), "第二句！")
        let p = editor.focusRange(for: .paragraph)!
        XCTAssertEqual(ns.substring(with: p), "第一句。第二句！Third sentence here. Fourth?")
        // 光标在英文句子中
        editor.setSelectedRange(NSRange(location: ns.range(of: "sentence").location, length: 0))
        XCTAssertEqual(ns.substring(with: editor.focusRange(for: .sentence)!).trimmingCharacters(in: .whitespaces), "Third sentence here.")
        // 下一段
        editor.setSelectedRange(NSRange(location: ns.range(of: "下一段").location, length: 0))
        XCTAssertEqual(ns.substring(with: editor.focusRange(for: .paragraph)!), "下一段。")
    }

    func testDimDoesNotTouchStorage() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let editor = EditorTextView(style: RenderStyle(theme: theme))
        let src = "A sentence. Another one.\n\nPara two.\n"
        editor.setSource(src)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let before = editor.textStorage!.copy() as! NSAttributedString
        editor.focusMode = .sentence
        XCTAssertTrue(editor.textStorage!.isEqual(to: before), "淡化只走渲染属性，不改 textStorage")
        XCTAssertEqual(editor.source, src)
        editor.focusMode = .off
        XCTAssertTrue(editor.textStorage!.isEqual(to: before))
    }
}

@MainActor
final class ClipboardTests: XCTestCase {
    func testPasteConvertsRichHTML() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let editor = EditorTextView(style: RenderStyle(theme: theme))
        editor.setSource("")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("<h2>Hi</h2><p>a <b>b</b></p>", forType: .html)
        pb.setString("Hi\na b", forType: .string)
        editor.paste(nil)
        XCTAssertEqual(editor.source, "## Hi\n\na **b**\n")
        // ⇧⌘V：纯文本
        editor.setSource("")
        editor.pasteAsPlainText(nil)
        XCTAssertEqual(editor.source, "Hi\na b")
        // 关掉自动转换：走纯文本
        editor.setSource("")
        editor.convertsHTMLOnPaste = false
        editor.paste(nil)
        XCTAssertEqual(editor.source, "Hi\na b")
        pb.clearContents()
    }

    func testCodeEditorHTMLIsNotConverted() {
        XCTAssertFalse(EditorTextView.looksLikeRichHTML("<meta charset=\"utf-8\"><pre style=\"x\">let a = 1</pre>"))
        XCTAssertTrue(EditorTextView.looksLikeRichHTML("<p>hello <a href=\"x\">y</a></p>"))
    }
}
