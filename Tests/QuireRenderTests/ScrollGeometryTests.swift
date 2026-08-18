import XCTest
import AppKit
@testable import QuireRender
@testable import QuireCore

/// 滚动几何：工具栏 / 标签栏盖住的 contentInsets.top 不算可见区；侧栏"当前章节"按可见区上部取样
@MainActor
final class ScrollGeometryTests: XCTestCase {
    func makeReader(insetTop: CGFloat) -> (ReaderTextView, NSScrollView, RenderedDocument) {
        let style = RenderStyle(theme: ThemeStore.loadBuiltIn().theme(id: "github-light")!)
        var md = ""
        for i in 1...40 { md += "## 第 \(i) 章\n\n" + String(repeating: "正文段落，用来把章节撑长一些。\n\n", count: 6) }
        let doc = DocumentRenderer(style: style).render(MarkdownParser().parse(md))
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500 + insetTop))
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = NSEdgeInsets(top: insetTop, left: 0, bottom: 0, right: 0)
        let reader = ReaderTextView(style: style)
        sv.documentView = reader
        reader.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        reader.setRendered(doc, style: style)
        reader.textLayoutManager?.textViewportLayoutController.layoutViewport()
        return (reader, sv, doc)
    }

    func testScrollToBlockLandsBelowCoveredInset() {
        let (reader, sv, doc) = makeReader(insetTop: 88)
        let target = doc.blocks.firstIndex { if case .heading(let l, _, _) = $0.block.kind, l == 2, $0.block.kind.headingTitle == "第 20 章" { return true }; return false }!
        reader.scroll(toBlock: target, animated: false)
        // 目标块顶 = 可见区顶 + scrollTopMargin；可见区顶 = bounds.minY + 88
        XCTAssertEqual(reader.scrollOffset(withinBlock: target), -ReaderTextView.scrollTopMargin, accuracy: 1)
        let frag = reader.layoutFragment(atCharacter: doc.ranges[target].location)!
        let expectedMinY = frag.layoutFragmentFrame.minY + reader.textContainerInset.height - ReaderTextView.scrollTopMargin - 88
        XCTAssertEqual(sv.contentView.bounds.minY, expectedMinY, accuracy: 1)
        XCTAssertEqual(reader.topVisibleBlockIndex(), target)
        XCTAssertEqual(reader.sectionBlockIndex(), target, "顶上刚好是标题 → 以它为当前章节")
        // 回到块 0：bounds.minY 应是 -insetTop（内容顶贴在工具栏下方，而不是被盖住 88pt）
        reader.scroll(toBlock: 0, animated: false)
        XCTAssertEqual(sv.contentView.bounds.minY, -88, accuracy: 0.5)
    }

    func testSectionSwitchesWhenNextHeadingRisesAboveMiddle() {
        let (reader, sv, doc) = makeReader(insetTop: 88)
        let h20 = doc.blocks.firstIndex { $0.block.kind.headingTitle == "第 20 章" }!
        let h21 = doc.blocks.firstIndex { $0.block.kind.headingTitle == "第 21 章" }!
        reader.scroll(toBlock: h20, animated: false)
        let visibleH: CGFloat = 500
        // 把第 21 章标题放到可见区 60% 处：仍属第 20 章
        var off = reader.scrollOffset(withinBlock: h21)   // 负数：在可见顶下方
        var o = sv.contentView.bounds.origin; o.y += -off - visibleH * 0.6; sv.contentView.setBoundsOrigin(o)
        reader.textLayoutManager?.textViewportLayoutController.layoutViewport()
        XCTAssertEqual(reader.scrollOffset(withinBlock: h21), -visibleH * 0.6, accuracy: 1)
        XCTAssertLessThan(reader.sectionBlockIndex()!, h21)
        XCTAssertGreaterThanOrEqual(reader.sectionBlockIndex()!, h20)
        // 放到 30% 处：应算读到第 21 章
        off = reader.scrollOffset(withinBlock: h21)
        o = sv.contentView.bounds.origin; o.y += -off - visibleH * 0.3; sv.contentView.setBoundsOrigin(o)
        reader.textLayoutManager?.textViewportLayoutController.layoutViewport()
        XCTAssertGreaterThanOrEqual(reader.sectionBlockIndex()!, h21)
        XCTAssertLessThan(reader.topVisibleBlockIndex()!, h21, "顶部块仍是第 20 章的正文（滚动同步用）")
    }
}

private extension BlockKind {
    var headingTitle: String? {
        if case .heading(_, let inlines, _) = self { return inlines.plainText }
        return nil
    }
}
