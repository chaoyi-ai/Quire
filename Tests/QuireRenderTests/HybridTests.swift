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
}
