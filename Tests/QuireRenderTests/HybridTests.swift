import XCTest
import AppKit
@testable import QuireRender
@testable import QuireCore

/// Spike #85：混合实时预览的核心闭环
@MainActor
final class HybridTests: XCTestCase {
    func make(_ src: String) -> (HybridTextView, RenderedDocument) {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let style = RenderStyle(theme: theme)
        let view = HybridTextView(style: style)
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); sv.documentView = view
        let doc = DocumentRenderer(style: style).render(MarkdownParser().parse(src))
        view.source = src
        view.setRendered(doc, style: style)
        view.isHybridEnabled = true
        return (view, doc)
    }

    func testActivateShowsSourceAndRoundTripsBytes() {
        let src = "# 标题\n\n这是 **粗体** 段落。\n\n| a | b |\n|--|--|\n| 1 | 2 |\n\n- 项一\n- 项二\n"
        let (v, doc) = make(src)
        XCTAssertEqual(doc.blocks.count, 4)
        var edits: [(Int, String, ClosedRange<Int>)] = []
        v.onSourceEdit = { edits.append(($0, $1, $2)) }
        // 激活段落（块 1）：渲染串里该段变成源码原文
        XCTAssertTrue(v.activate(block: 1))
        XCTAssertEqual(v.activeSource, "这是 **粗体** 段落。\n")
        XCTAssertTrue(v.isEditable)
        // 表格块（附件）激活后就是 Markdown 表格源码
        XCTAssertTrue(v.activate(block: 2))
        XCTAssertEqual(v.activeSource, "| a | b |\n|--|--|\n| 1 | 2 |\n")
        XCTAssertTrue(edits.isEmpty, "只激活不编辑：不产生源码变更")
        // 其余块仍是渲染态：标题文字存在且不含 '#'
        let s = v.textStorage!.string
        XCTAssertTrue(s.contains("标题")); XCTAssertFalse(s.contains("# 标题"))
        XCTAssertTrue(s.contains("项一"))
    }

    func testEditInsideActiveBlockUpdatesSource() {
        let src = "第一段\n\n第二段\n"
        let (v, _) = make(src)
        var last: (Int, String, ClosedRange<Int>)?
        v.onSourceEdit = { last = ($0, $1, $2) }
        XCTAssertTrue(v.activate(block: 1))
        let r = v.activeRange
        v.setSelectedRange(NSRange(location: r.location + 3, length: 0))
        v.insertText("！", replacementRange: NSRange(location: r.location + 3, length: 0))
        XCTAssertEqual(last?.0, 1)
        XCTAssertEqual(last?.1, "第二段！\n")
        XCTAssertEqual(last?.2, 3...3)
        XCTAssertEqual(v.activeRange.length, 5)
        // 不能改到激活块之外
        XCTAssertFalse(v.shouldChangeText(in: NSRange(location: 0, length: 1), replacementString: "x"))
        // 退出
        var deactivated = false
        v.onDeactivate = { deactivated = true }
        v.deactivate(commit: true)
        XCTAssertTrue(deactivated); XCTAssertFalse(v.isEditable); XCTAssertNil(v.activeBlock)
    }

    func testDisabledBehavesLikeReader() {
        let (v, _) = make("段落\n")
        v.isHybridEnabled = false
        XCTAssertFalse(v.activate(block: 0))
        XCTAssertFalse(v.isEditable)
    }
}

@MainActor
final class HybridRerenderTests: XCTestCase {
    func testRerenderAfterEditLeavesNoResidue() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let style = RenderStyle(theme: theme)
        let parser = MarkdownParser(), renderer = DocumentRenderer(style: style)
        let src = "# T\n\n第二段\n\n- 项\n"
        let view = HybridTextView(style: style)
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); sv.documentView = view
        let r0 = renderer.render(parser.parse(src))
        view.source = src; view.setRendered(r0, style: style); view.isHybridEnabled = true
        XCTAssertTrue(view.activate(block: 1))
        let r = view.activeRange
        view.insertText("加长加长加长", replacementRange: NSRange(location: r.location + 3, length: 0))
        view.deactivate(commit: false)   // 真实流程：先退出编辑，宿主再异步重渲染
        // 宿主重解析 + 增量重渲染
        let newSrc = "# T\n\n第二段加长加长加长\n\n- 项\n"
        let (r1, diff) = renderer.render(parser.parse(newSrc), reusing: r0)
        view.source = newSrc
        view.replaceBlocks(with: r1, diff: diff, previous: r0)
        // 整个 textStorage 应与全量渲染完全一致，没有残片
        let full = renderer.render(parser.parse(newSrc))
        XCTAssertEqual(view.textStorage!.string, full.attributed.string)
        XCTAssertNil(view.activeBlock); XCTAssertFalse(view.isEditable)
    }

    /// 只激活不编辑就退出：diff 为空、宿主不走 replaceBlocks，块必须已经是渲染态（以前永远停在源码态）
    func testDeactivateWithoutEditRestoresRenderedForm() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let style = RenderStyle(theme: theme)
        let parser = MarkdownParser(), renderer = DocumentRenderer(style: style)
        let src = "# T\n\n**粗** 段\n\n- 项\n"
        let view = HybridTextView(style: style)
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); sv.documentView = view
        let r0 = renderer.render(parser.parse(src))
        view.source = src; view.setRendered(r0, style: style); view.isHybridEnabled = true
        XCTAssertTrue(view.activate(block: 1))
        XCTAssertTrue(view.textStorage!.string.contains("**粗**"))
        view.deactivate(commit: true)
        XCTAssertEqual(view.textStorage!.string, r0.attributed.string)
        view.updateRendered(r0)   // 宿主：diff 为空
        XCTAssertEqual(view.textStorage!.string, r0.attributed.string)
        // 关掉混合模式也一样
        XCTAssertTrue(view.activate(block: 2))
        view.isHybridEnabled = false
        XCTAssertEqual(view.textStorage!.string, r0.attributed.string)
        // 点击位置换算：激活块之后的块在退出后没有残余平移
        XCTAssertEqual(view.blockIndex(atCharacter: r0.ranges[2].location), 2)
    }

    /// 编辑块 1 → 立刻点到块 2 → 块 1 的重渲染这时才到：块 2 应保持激活、光标不丢
    func testAsyncRerenderKeepsNewlyActivatedBlock() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let style = RenderStyle(theme: theme)
        let parser = MarkdownParser(), renderer = DocumentRenderer(style: style)
        let src = "# T\n\n第二段\n\n第三段\n"
        let view = HybridTextView(style: style)
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); sv.documentView = view
        let r0 = renderer.render(parser.parse(src))
        view.source = src; view.setRendered(r0, style: style); view.isHybridEnabled = true
        XCTAssertTrue(view.activate(block: 1))
        view.insertText("XY", replacementRange: NSRange(location: view.activeRange.location + 3, length: 0))
        let newSrc = "# T\n\n第二段XY\n\n第三段\n"
        view.source = newSrc
        XCTAssertTrue(view.activate(block: 2, caretAt: 2))   // 用户已经点到下一块
        XCTAssertEqual(view.activeSource, "第三段\n")
        let (r1, diff) = renderer.render(parser.parse(newSrc), reusing: r0)
        view.replaceBlocks(with: r1, diff: diff, previous: r0)   // 块 1 的重渲染此时到达
        XCTAssertEqual(view.activeBlock, 2)
        XCTAssertTrue(view.isEditable)
        XCTAssertEqual(view.activeSource, "第三段\n")
        XCTAssertEqual(view.selectedRange().location, view.activeRange.location + 2)
        // 除了激活块以外，内容与全量渲染一致
        view.deactivate(commit: false)
        XCTAssertEqual(view.textStorage!.string, renderer.render(parser.parse(newSrc)).attributed.string)
    }
}

@MainActor
final class HybridPolishTests: XCTestCase {
    func make(_ src: String) -> (HybridTextView, RenderedDocument, DocumentRenderer) {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let style = RenderStyle(theme: theme)
        let renderer = DocumentRenderer(style: style)
        let view = HybridTextView(style: style)
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); sv.documentView = view
        let doc = renderer.render(MarkdownParser().parse(src))
        view.source = src; view.setRendered(doc, style: style); view.isHybridEnabled = true
        view.renderPreview = { s in renderer.render(MarkdownParser().parse(s)).attributed }
        return (view, doc, renderer)
    }

    func testAttachmentBlockKeepsPreviewBelowSource() {
        let (v, _, _) = make("段落\n\n| a | b |\n|--|--|\n| 1 | 2 |\n\n尾\n")
        XCTAssertTrue(v.activate(block: 1))
        let s = v.textStorage!.string
        XCTAssertTrue(s.contains("| a | b |"), "源码在")
        XCTAssertTrue(s.contains("\u{FFFC}"), "预览（表格附件）也在")
        // 编辑源码后预览刷新（150 ms）
        let r = v.activeRange
        v.insertText("3", replacementRange: NSRange(location: r.location + r.length - 3, length: 0))
        let exp = expectation(description: "preview")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(v.textStorage!.string.components(separatedBy: "23").count, 3, "源码里一次 + 预览镜像里一次")
        // 退出 + 重渲染后没有残片
        v.deactivate(commit: false)
        XCTAssertNil(v.activeBlock)
    }

    func testSourceOffsetFromRenderedPrefix() {
        let src = "这是 **粗体** 和 *斜体* 的段落。\n"
        XCTAssertEqual(HybridTextView.sourceOffset(forRenderedPrefix: "这是 粗体", in: src), ("这是 **粗体" as NSString).length)
        XCTAssertEqual(HybridTextView.sourceOffset(forRenderedPrefix: "", in: src), 0)
    }

    func testSourceIsHighlighted() {
        let (v, _, _) = make("# 标题\n\n**粗** 字\n")
        XCTAssertTrue(v.activate(block: 0))
        let ts = v.textStorage!
        let attrs = ts.attributes(at: v.activeRange.location, effectiveRange: nil)   // "#" 标记
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, v.style.theme.colors.editor.markdownMarker.nsColor)
    }
}

/// 混合模式回写：区间替换要与"整篇按行拆再拼"逐字节一致
final class SourceLineSplicerTests: XCTestCase {
    /// 旧实现（参照）
    func reference(_ source: String, lines: ClosedRange<Int>, text: String) -> String? {
        var all = source.components(separatedBy: "\n")
        let newLines = text.hasSuffix("\n") ? String(text.dropLast()).components(separatedBy: "\n") : text.components(separatedBy: "\n")
        guard lines.lowerBound >= 1, lines.upperBound <= all.count else { return nil }
        all.replaceSubrange((lines.lowerBound - 1)...(lines.upperBound - 1), with: newLines)
        return all.joined(separator: "\n")
    }

    func testMatchesReferenceAcrossKeystrokes() {
        let src = "# 标题\n\n第一段。\n\n- a\n- b\n\n结尾段\n"
        let sp = SourceLineSplicer()
        var cur = src
        var lines = 5...6
        for text in ["- a\n- bb\n", "- a\n- bb\n- c\n", "- a\n- bb\n- c\n- 🎉d\n", "- x\n"] {
            let (out, n) = sp.replace(lines: lines, in: cur, with: text)!
            XCTAssertEqual(out, reference(cur, lines: lines, text: text))
            XCTAssertEqual(n, text.dropLast().filter { $0 == "\n" }.count + 1)
            cur = out; lines = 5...(5 + n - 1)
        }
    }

    func testFirstAndLastLineAndNoTrailingNewline() {
        let sp = SourceLineSplicer()
        // 第一行
        XCTAssertEqual(sp.replace(lines: 1...1, in: "a\nb\nc\n", with: "A\n")!.0, "A\nb\nc\n")
        sp.reset()
        // 最后一行、文末没有换行：不能凭空多一个换行
        XCTAssertEqual(sp.replace(lines: 3...3, in: "a\nb\nc", with: "C\n")!.0, reference("a\nb\nc", lines: 3...3, text: "C\n"))
        sp.reset()
        // 最后一行、文末有换行
        XCTAssertEqual(sp.replace(lines: 3...3, in: "a\nb\nc\n", with: "C\n")!.0, "a\nb\nC\n")
        sp.reset()
        // 文末换行之后算一个空行（与 components(separatedBy:) 一致）；再往后越界
        XCTAssertEqual(sp.replace(lines: 4...4, in: "a\nb\nc\n", with: "x\n")!.0, reference("a\nb\nc\n", lines: 4...4, text: "x\n"))
        sp.reset()
        XCTAssertNil(sp.replace(lines: 5...5, in: "a\nb\nc\n", with: "x\n"))
        XCTAssertNil(sp.replace(lines: 0...1, in: "a\n", with: "x\n"))
        // 单行文档
        sp.reset()
        XCTAssertEqual(sp.replace(lines: 1...1, in: "only", with: "ONLY\n")!.0, "ONLY")
    }

    func testRegionInvalidatesWhenBlockChanges() {
        let sp = SourceLineSplicer()
        var cur = "a\nb\nc\n"
        cur = sp.replace(lines: 1...1, in: cur, with: "A\n")!.0
        cur = sp.replace(lines: 3...3, in: cur, with: "C\n")!.0   // 换了块：重新定位
        XCTAssertEqual(cur, "A\nb\nC\n")
    }
}
