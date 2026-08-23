import AppKit
import QuireCore

/// 一个已渲染的顶级块
public struct RenderedBlock: @unchecked Sendable {
    public let block: Block
    public let attributed: NSAttributedString
    /// 含图片 / Mermaid 附件（需要异步加载）
    public let hasLoadableAttachments: Bool
    public var length: Int { attributed.length }
    public init(block: Block, attributed: NSAttributedString, hasLoadableAttachments: Bool = false) {
        self.block = block; self.attributed = attributed; self.hasLoadableAttachments = hasLoadableAttachments
    }
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

    /// 源码行 → 覆盖该行的块下标；行落在块间空白时取其前一块（用于滚动同步）。块按源码顺序排列 → 二分。
    public func blockIndex(forLine line: Int) -> Int? {
        guard !blocks.isEmpty else { return nil }
        var lo = 0, hi = blocks.count - 1
        var best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            guard let r = blocks[mid].block.sourceRange else {
                // 极少数无位置的块：退化为向后线性
                if let i = blocks[mid...].firstIndex(where: { $0.block.sourceRange != nil }) { lo = i; continue }
                hi = mid - 1; continue
            }
            if r.lineRange.contains(line) { return mid }
            if r.start.line > line { hi = mid - 1 } else { best = mid; lo = mid + 1 }
        }
        return best ?? 0
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
        builder.headingNumbers = style.options.headingNumbers ? Self.headingNumbers(for: document) : [:]
        let rendered = render(blocks: document.blocks)
        return assemble(rendered)
    }

    /// 标题编号：按文档里出现的最小级别起算，跳级按 1 补；只编顶级块里的标题
    public static func headingNumbers(for doc: Document) -> [Int: String] {
        var counters = [Int](repeating: 0, count: 7)
        var out: [Int: String] = [:]
        let minLevel = doc.blocks.compactMap { if case .heading(let l, _, _) = $0.kind { l } else { nil } }.min() ?? 1
        for (i, b) in doc.blocks.enumerated() {
            guard case .heading(let level, _, _) = b.kind else { continue }
            let depth = max(1, level - minLevel + 1)
            counters[depth] += 1
            for d in (depth + 1)..<7 { counters[d] = 0 }
            out[i] = (1...depth).map { String(max(1, counters[$0])) }.joined(separator: ".")
        }
        return out
    }

    /// 渲染一组块（增量路径用）
    public func render(blocks: [Block]) -> [RenderedBlock] {
        var out: [RenderedBlock] = []
        out.reserveCapacity(blocks.count)
        for (i, b) in blocks.enumerated() {
            let r: (attributed: NSAttributedString, hasLoadableAttachments: Bool) = builder.build(b, index: i)
            out.append(RenderedBlock(block: b, attributed: r.attributed, hasLoadableAttachments: r.hasLoadableAttachments))
        }
        return out
    }

    /// 增量：复用 `previous` 中未变化的块，只重建 diff 范围内的块
    public func render(_ document: Document, reusing previous: RenderedDocument) -> (RenderedDocument, BlockDiff) {
        let diff = BlockDiff.compute(old: previous.blocks.map(\.block), new: document.blocks)
        // 块相等性只看内容不看位置：复用的块必须换成新解析的 Block（行号变了），否则混合模式 / 复制为 Markdown / 滚动同步
        // 都会拿着旧行号去切源码。diff 为空时也一样——上面插入一行，下面所有块的行号都变了
        func rebased(_ rb: RenderedBlock, _ newBlock: Block) -> RenderedBlock {
            RenderedBlock(block: newBlock, attributed: rb.attributed, hasLoadableAttachments: rb.hasLoadableAttachments)
        }
        if diff.isEmpty, previous.theme.id == style.theme.id {
            if previous.blocks.count == document.blocks.count, zip(previous.blocks, document.blocks).allSatisfy({ $0.block.sourceRange == $1.sourceRange }) { return (previous, diff) }
            let blocks = zip(previous.blocks, document.blocks).map { rebased($0, $1) }
            return (RenderedDocument(theme: previous.theme, blocks: blocks, attributed: previous.attributed, ranges: previous.ranges), diff)
        }
        // 标题编号跨块联动：有改动就整篇重建（编号是可选项，1 MB 全量 130 ms 可接受）
        if style.options.headingNumbers { return (render(document), BlockDiff(oldChanged: 0..<previous.blocks.count, newChanged: 0..<document.blocks.count)) }
        var blocks: [RenderedBlock] = []
        blocks.reserveCapacity(document.blocks.count)
        for i in 0..<diff.oldChanged.lowerBound { blocks.append(rebased(previous.blocks[i], document.blocks[i])) }
        for (k, b) in document.blocks[diff.newChanged].enumerated() {
            let r: (attributed: NSAttributedString, hasLoadableAttachments: Bool) = builder.build(b, index: diff.newChanged.lowerBound + k)
            blocks.append(RenderedBlock(block: b, attributed: r.attributed, hasLoadableAttachments: r.hasLoadableAttachments))
        }
        let tail = previous.blocks.count - diff.oldChanged.upperBound
        for j in 0..<tail { blocks.append(rebased(previous.blocks[diff.oldChanged.upperBound + j], document.blocks[diff.newChanged.upperBound + j])) }
        return (assemble(blocks), diff)
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
