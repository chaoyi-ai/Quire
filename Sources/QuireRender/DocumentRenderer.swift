import AppKit
import QuireCore

/// 一个已渲染的顶级块
public struct RenderedBlock: @unchecked Sendable {
    public let block: Block
    public let attributed: NSAttributedString
    public var length: Int { attributed.length }
}

/// 整份已渲染文档：块列表 + 拼接结果 + 每块在拼接串中的范围
public struct RenderedDocument: @unchecked Sendable {
    public let theme: Theme
    public let blocks: [RenderedBlock]
    public let attributed: NSAttributedString
    public let ranges: [NSRange]

    public static func empty(theme: Theme) -> RenderedDocument {
        RenderedDocument(theme: theme, blocks: [], attributed: NSAttributedString(), ranges: [])
    }

    /// 字符位置 → 块下标（二分）
    public func blockIndex(at location: Int) -> Int? {
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = ranges[mid]
            if location < r.location { hi = mid - 1 }
            else if location >= r.location + r.length { lo = mid + 1 }
            else { return mid }
        }
        return ranges.isEmpty ? nil : min(max(lo, 0), ranges.count - 1)
    }

    /// 源码行 → 首个覆盖该行的块下标（用于滚动同步）
    public func blockIndex(forLine line: Int) -> Int? {
        var best: Int?
        for (i, b) in blocks.enumerated() {
            guard let r = b.block.sourceRange else { continue }
            if r.lineRange.contains(line) { return i }
            if r.start.line > line { return best ?? i }
            best = i
        }
        return best
    }
}

/// 文档渲染器：Document → RenderedDocument。可在后台线程调用；持有 style + builder。
public final class DocumentRenderer: @unchecked Sendable {
    public let style: RenderStyle
    public let builder: AttributedStringBuilder

    public init(theme: Theme, scale: CGFloat = 1, highlighter: SyntaxHighlighter = SyntaxHighlighter()) {
        style = RenderStyle(theme: theme, scale: scale)
        builder = AttributedStringBuilder(style: style, highlighter: highlighter)
    }

    public init(style: RenderStyle, highlighter: SyntaxHighlighter = SyntaxHighlighter()) {
        self.style = style
        builder = AttributedStringBuilder(style: style, highlighter: highlighter)
    }

    /// 全量渲染
    public func render(_ document: Document) -> RenderedDocument {
        let rendered = render(blocks: document.blocks)
        return assemble(rendered)
    }

    /// 渲染一组块（增量路径用）
    public func render(blocks: [Block]) -> [RenderedBlock] {
        var out: [RenderedBlock] = []
        out.reserveCapacity(blocks.count)
        for (i, b) in blocks.enumerated() {
            out.append(RenderedBlock(block: b, attributed: builder.build(b, index: i)))
        }
        return out
    }

    /// 增量：复用 `previous` 中未变化的块，只重建 diff 范围内的块
    public func render(_ document: Document, reusing previous: RenderedDocument) -> (RenderedDocument, BlockDiff) {
        let diff = BlockDiff.compute(old: previous.blocks.map(\.block), new: document.blocks)
        if diff.isEmpty, previous.theme.id == style.theme.id { return (previous, diff) }
        var blocks: [RenderedBlock] = []
        blocks.reserveCapacity(document.blocks.count)
        blocks.append(contentsOf: previous.blocks[0..<diff.oldChanged.lowerBound])
        for (k, b) in document.blocks[diff.newChanged].enumerated() {
            blocks.append(RenderedBlock(block: b, attributed: builder.build(b, index: diff.newChanged.lowerBound + k)))
        }
        blocks.append(contentsOf: previous.blocks[diff.oldChanged.upperBound...])
        return (assemble(blocks), diff)
    }

    /// 主题切换：同一文档换 style 全量重建（不重解析）
    public func rerender(_ previous: RenderedDocument, document: Document) -> RenderedDocument {
        render(document)
    }

    private func assemble(_ blocks: [RenderedBlock]) -> RenderedDocument {
        let total = NSMutableAttributedString()
        var ranges: [NSRange] = []
        ranges.reserveCapacity(blocks.count)
        for rb in blocks {
            ranges.append(NSRange(location: total.length, length: rb.attributed.length))
            total.append(rb.attributed)
        }
        return RenderedDocument(theme: style.theme, blocks: blocks, attributed: total, ranges: ranges)
    }
}
