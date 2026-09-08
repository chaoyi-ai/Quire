import XCTest
import AppKit
@testable import QuireRender
@testable import QuireCore

/// 回归：在行尾连续输入，字符必须留在同一行、光标每次只前进一个字符（0.8.5 时曾变成每个字符掉到下一行行首）
@MainActor
final class EditorCaretTests: XCTestCase {
    func make(_ src: String, split: Bool = false) -> EditorTextView {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let e = EditorTextView(style: RenderStyle(theme: theme))
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500)); sv.documentView = e
        e.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        e.setSource(src)
        return e
    }

    func typeAtEnd(ofLine line: Int, in e: EditorTextView, _ text: String) -> Int {
        let ns = e.string as NSString
        var l = 1, pos = 0
        while l < line, pos < ns.length { if ns.character(at: pos) == 0x0A { l += 1 }; pos += 1 }
        var end = pos; while end < ns.length, ns.character(at: end) != 0x0A { end += 1 }
        e.setSelectedRange(NSRange(location: end, length: 0))
        for ch in text { e.insertText(String(ch), replacementRange: e.selectedRange()) }
        return end
    }

    func testTypingAtLineEndStaysOnLine() {
        let src = "# 标题\n\n> 引用一行，后面还有一行\n下一行\n\n- 列表项\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n\n最后一行"
        for line in [1, 3, 4, 6, 8, 10, 13, 16] {
            let e = make(src)
            let end = typeAtEnd(ofLine: line, in: e, "ABC")
            let ns = e.string as NSString
            XCTAssertEqual(e.selectedRange().location, end + 3, "第 \(line) 行：光标应正好在插入的 3 个字符之后")
            XCTAssertEqual(ns.substring(with: NSRange(location: end, length: 3)), "ABC", "第 \(line) 行：三个字符要连在一起")
            XCTAssertEqual(e.lineCount, (src as NSString).components(separatedBy: "\n").count, "第 \(line) 行：不能多出行")
        }
    }

    func testTypingAtLineEndAfterWrappedLongLine() {
        let long = String(repeating: "一二三四五六七八九十", count: 12)
        let e = make("段落开头。\n\(long)\n下一行\n")
        let end = typeAtEnd(ofLine: 2, in: e, "ABCDEFG")
        XCTAssertEqual(e.selectedRange().location, end + 7)
        XCTAssertEqual((e.string as NSString).substring(with: NSRange(location: end, length: 7)), "ABCDEFG")
    }
}

@MainActor
final class EditorCaretMoreTests: XCTestCase {
    func make(_ src: String) -> EditorTextView {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let e = EditorTextView(style: RenderStyle(theme: theme))
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500)); sv.documentView = e
        e.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        e.setSource(src)
        return e
    }

    func testInsertInMiddleAndDeleteAtEnd() {
        let e = make("第一行文字\n第二行\n")
        e.setSelectedRange(NSRange(location: 2, length: 0))
        e.insertText("X", replacementRange: e.selectedRange())
        XCTAssertEqual(e.string, "第一X行文字\n第二行\n"); XCTAssertEqual(e.selectedRange().location, 3)
        // 行尾退格
        e.setSelectedRange(NSRange(location: 6, length: 0))
        e.deleteBackward(nil)
        XCTAssertEqual(e.string, "第一X行文\n第二行\n"); XCTAssertEqual(e.selectedRange().location, 5)
        // 行尾删除换行（合并下一行）
        e.deleteForward(nil)
        XCTAssertEqual(e.string, "第一X行文第二行\n"); XCTAssertEqual(e.selectedRange().location, 5)
    }

    func testPasteMultilineAtLineEnd() {
        let e = make("a\nb\n")
        e.setSelectedRange(NSRange(location: 1, length: 0))
        e.insertText("X\nY", replacementRange: e.selectedRange())
        XCTAssertEqual(e.string, "aX\nY\nb\n"); XCTAssertEqual(e.selectedRange().location, 4)
        XCTAssertEqual(e.lineCount, 4)
    }

    func testTypingAtEndOfDocumentWithoutTrailingNewline() {
        let e = make("# 标题\n\n最后一行")
        e.setSelectedRange(NSRange(location: (e.string as NSString).length, length: 0))
        for ch in "ABC" { e.insertText(String(ch), replacementRange: e.selectedRange()) }
        XCTAssertTrue(e.string.hasSuffix("最后一行ABC")); XCTAssertEqual(e.selectedRange().location, (e.string as NSString).length)
    }

    func testMarkedTextCompositionAtLineEnd() {
        // 中文输入法：先 marked text 再上屏
        let e = make("你好\n下一行\n")
        e.setSelectedRange(NSRange(location: 2, length: 0))
        e.setMarkedText("shi", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(e.hasMarkedText())
        e.insertText("世界", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(e.string, "你好世界\n下一行\n"); XCTAssertEqual(e.selectedRange().location, 4)
        XCTAssertFalse(e.hasMarkedText())
    }

    func testTypingKeepsHighlightAndFenceState() {
        let e = make("```swift\nlet a = 1\n```\n\n正文\n")
        e.setSelectedRange(NSRange(location: 18, length: 0))   // "let a = 1" 行尾
        e.insertText("2", replacementRange: e.selectedRange())
        XCTAssertEqual(e.selectedRange().location, 19)
        let code = e.style.theme.colors.editor.markdownCode.nsColor
        XCTAssertEqual(e.textStorage!.attribute(.foregroundColor, at: 18, effectiveRange: nil) as? NSColor, code, "围栏内新打的字仍按代码着色")
    }
}

/// 混合模式：激活块里在源码末尾连续输入，光标也必须每次只前进一个字符
@MainActor
final class HybridCaretTests: XCTestCase {
    func testTypingAtEndOfActiveBlock() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let style = RenderStyle(theme: theme)
        let view = HybridTextView(style: style)
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); sv.documentView = view
        let src = "# 标题\n\n这是一段。\n\n- 项一\n"
        let doc = DocumentRenderer(style: style).render(MarkdownParser().parse(src))
        view.source = src; view.setRendered(doc, style: style); view.isHybridEnabled = true
        var edits: [String] = []
        view.onSourceEdit = { _, text, _ in edits.append(text) }
        XCTAssertTrue(view.activate(block: 1))
        // 激活块的源码 "这是一段。\n"，光标放到换行之前
        let r = view.activeRange
        view.setSelectedRange(NSRange(location: r.location + r.length - 1, length: 0))
        for ch in "ABC" { view.insertText(String(ch), replacementRange: view.selectedRange()) }
        XCTAssertEqual(view.activeSource, "这是一段。ABC\n")
        XCTAssertEqual(view.selectedRange().location, view.activeRange.location + view.activeRange.length - 1, "光标在三个字符之后、换行之前")
        XCTAssertEqual(edits.last, "这是一段。ABC\n")
    }
}
