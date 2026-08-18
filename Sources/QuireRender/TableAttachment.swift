import AppKit
import QuireCore

/// 表格附件：携带模型 + 预先渲染好的单元格属性字符串（后台生成）。
/// 尺寸由 `attachmentBounds` 按行片段宽度计算；绘制由 `BlockLayoutFragment` 直接在片段里完成（不用子视图：
/// TextKit 2 的 NSTextView 不会替我们管理 NSTextAttachmentViewProvider 的视图，而直接绘制还天然支持打印 / PDF）。
public final class TableAttachment: NSTextAttachment {
    public let model: TableModel
    public let header: [NSAttributedString]
    public let rows: [[NSAttributedString]]
    public let style: RenderStyle

    private var layoutCache: [Int: TableLayout] = [:]
    /// 最近一次布局（片段绘制时使用）
    public private(set) var currentLayout: TableLayout?
    private let lock = NSLock()

    public init(model: TableModel, header: [NSAttributedString], rows: [[NSAttributedString]], style: RenderStyle) {
        self.model = model
        self.header = header
        self.rows = rows
        self.style = style
        super.init(data: nil, ofType: nil)
        let rowH = style.lineHeight + style.tableCellPadding.vertical * 2
        bounds = CGRect(x: 0, y: 0, width: 400, height: rowH * CGFloat(rows.count + 1))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// TextKit 2 布局时调用：按可用宽度算列宽/行高
    public override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        var available = proposedLineFragment.width
        if let ps = attributes[.paragraphStyle] as? NSParagraphStyle { available -= ps.headIndent + max(0, -ps.tailIndent) }
        available = max(120, available.rounded(.down))
        let l = layout(available: available)
        return CGRect(x: 0, y: 0, width: min(available, l.width), height: l.height)
    }

    public func layout(available: CGFloat) -> TableLayout {
        let key = Int(available)
        lock.lock(); defer { lock.unlock() }
        if let l = layoutCache[key] { currentLayout = l; return l }
        let l = TableRenderer.computeLayout(self, available: available)
        layoutCache[key] = l
        currentLayout = l
        return l
    }

    // 附件本身不画图片（由片段绘制）
    public override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> NSImage? { nil }
}

// MARK: - 布局算法（纯计算，可测试）

/// 表格列宽 / 行高计算。
public struct TableLayout: Equatable, Sendable {
    public var columnWidths: [CGFloat]
    public var rowHeights: [CGFloat]      // [0] 是表头
    /// 每个单元格文字的实际高度（[行][列]，与 rowHeights 同序）：绘制时用来垂直居中——
    /// 行高至少 lineHeight + 内边距，而单行文字的自然高度（字体 ascent+descent）比 lineHeight 小，
    /// 顶对齐会显得上窄下宽。
    public var textHeights: [[CGFloat]] = []
    public var width: CGFloat { columnWidths.reduce(0, +) }
    public var height: CGFloat { rowHeights.reduce(0, +) }

    /// - Parameters:
    ///   - natural: 每列自然宽度（单行不换行的最大内容宽 + 内边距）
    ///   - minimum: 每列最小宽度（最长单词宽 + 内边距，已裁到上限）
    ///   - available: 可用宽度
    /// 算法：总自然宽 ≤ 可用 → 用自然宽；否则先给最小宽，再把剩余空间按 (自然 − 最小) 比例分配；
    /// 最小宽之和仍超出 → 按比例整体压缩（单元格按字符换行兜底）。
    public static func distribute(natural: [CGFloat], minimum: [CGFloat], available: CGFloat) -> [CGFloat] {
        let n = natural.count
        guard n > 0 else { return [] }
        let totalNatural = natural.reduce(0, +)
        if totalNatural <= available { return natural }
        let mins = zip(minimum, natural).map { min($0, $1) }
        let totalMin = mins.reduce(0, +)
        if totalMin >= available {
            let k = available / max(totalMin, 1)
            return mins.map { ($0 * k).rounded(.down) }
        }
        let extra = available - totalMin
        // 弹性权重：自然宽超过可用宽 55% 的列按 55% 计，避免一列长文本把其他列挤到最小
        let cap = available * 0.55
        let flex = zip(natural, mins).map { max(0, min($0, cap) - $1) }
        let totalFlex = flex.reduce(0, +)
        if totalFlex <= 0 { return mins }
        var out = (0..<n).map { (mins[$0] + extra * flex[$0] / totalFlex).rounded(.down) }
        // 权重封顶后可能有剩余：再按自然宽比例分掉
        let used = out.reduce(0, +)
        if available - used > CGFloat(n), totalNatural > 0 {
            let rest = available - used
            for i in 0..<n where natural[i] > out[i] { out[i] += (rest * natural[i] / totalNatural).rounded(.down) }
        }
        return out
    }
}

// MARK: - 测量与绘制

public enum TableRenderer {
    static let measureOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static func computeLayout(_ att: TableAttachment, available: CGFloat) -> TableLayout {
        let style = att.style
        let cols = att.model.columnCount
        let padH = style.tableCellPadding.horizontal, padV = style.tableCellPadding.vertical
        var natural = [CGFloat](repeating: padH * 2 + 8, count: cols)
        var minimum = [CGFloat](repeating: padH * 2 + 8, count: cols)
        let allRows = [att.header] + att.rows
        for row in allRows {
            for (c, cell) in row.enumerated() where c < cols {
                let w = cell.size().width
                natural[c] = max(natural[c], (w + padH * 2 + 1).rounded(.up))
                minimum[c] = max(minimum[c], min(longestWord(cell) + padH * 2 + 1, 220).rounded(.up))
            }
        }
        // 最小宽下限：约 5 em（除非内容本来就更窄），避免 CJK 列被压成单字竖排
        for c in 0..<cols { minimum[c] = max(minimum[c], min(natural[c], (style.baseSize * 5 + padH * 2).rounded())) }
        let widths = TableLayout.distribute(natural: natural, minimum: minimum, available: available)
        var heights: [CGFloat] = []
        var textHeights: [[CGFloat]] = []
        for row in allRows {
            var h: CGFloat = style.lineHeight + padV * 2
            var th: [CGFloat] = []
            for (c, cell) in row.enumerated() where c < cols {
                let inner = max(10, widths[c] - padH * 2)
                let r = cell.boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude), options: measureOptions)
                th.append(r.height.rounded(.up))
                h = max(h, (r.height + padV * 2).rounded(.up))
            }
            heights.append(h)
            textHeights.append(th)
        }
        return TableLayout(columnWidths: widths, rowHeights: heights, textHeights: textHeights)
    }

    /// 最长"单词"宽度（按空白切分；CJK 连续文本视为可任意断行，取单字宽）
    static func longestWord(_ s: NSAttributedString) -> CGFloat {
        let str = s.string
        var best: CGFloat = 0
        var start = str.startIndex
        func measure(_ r: Range<String.Index>) {
            guard !r.isEmpty else { return }
            let sub = s.attributedSubstring(from: NSRange(r, in: str))
            if sub.string.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) {
                var maxChar: CGFloat = 0
                sub.string.enumerateSubstrings(in: sub.string.startIndex..., options: .byComposedCharacterSequences) { _, r2, _, _ in
                    maxChar = max(maxChar, sub.attributedSubstring(from: NSRange(r2, in: sub.string)).size().width)
                }
                best = max(best, maxChar)
            } else {
                best = max(best, sub.size().width)
            }
        }
        for i in str.indices where str[i].isWhitespace { measure(start..<i); start = str.index(after: i) }
        measure(start..<str.endIndex)
        return best
    }

    /// 在翻转坐标系（TextKit 片段绘制上下文）里把整张表画到 `origin` 处
    static func draw(_ att: TableAttachment, layout: TableLayout, at origin: CGPoint, maxWidth: CGFloat, in context: CGContext) {
        let style = att.style
        let padH = style.tableCellPadding.horizontal, padV = style.tableCellPadding.vertical
        let totalW = min(maxWidth, layout.width)
        let totalH = layout.height
        let radius: CGFloat = 6
        let outer = CGRect(x: origin.x + 0.5, y: origin.y + 0.5, width: totalW - 1, height: totalH - 1)
        let clip = CGPath(roundedRect: outer, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.addPath(clip); context.clip()

        // 行背景
        var y = origin.y
        for (r, h) in layout.rowHeights.enumerated() {
            let rect = CGRect(x: origin.x, y: y, width: totalW, height: h)
            if r == 0 { context.setFillColor(style.tableHeaderBackground.cgColor); context.fill(rect) }
            else if (r - 1) % 2 == 1 { context.setFillColor(style.tableStripe.cgColor); context.fill(rect) }
            y += h
        }
        // 网格线
        context.setFillColor(style.tableBorder.cgColor)
        y = origin.y
        for (r, h) in layout.rowHeights.enumerated() {
            y += h
            if r < layout.rowHeights.count - 1 { context.fill(CGRect(x: origin.x, y: y - 0.5, width: totalW, height: 1)) }
        }
        var x = origin.x
        for (c, w) in layout.columnWidths.enumerated() {
            x += w
            if c < layout.columnWidths.count - 1 { context.fill(CGRect(x: x - 0.5, y: origin.y, width: 1, height: totalH)) }
        }

        // 文字（NSAttributedString.draw 需要 NSGraphicsContext，且当前上下文为翻转坐标）
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let allRows = [att.header] + att.rows
        y = origin.y
        for (r, row) in allRows.enumerated() {
            let h = layout.rowHeights[r]
            x = origin.x
            for c in 0..<att.model.columnCount {
                let w = layout.columnWidths[c]
                if c < row.count {
                    let cell = aligned(row[c], alignment: c < att.model.alignments.count ? att.model.alignments[c] : .none)
                    // 垂直居中：单元格文字比行高矮时（单行、或同一行里别的单元格更高）
                    let th = (r < layout.textHeights.count && c < layout.textHeights[r].count) ? layout.textHeights[r][c] : h - padV * 2
                    let dy = max(0, ((h - padV * 2 - th) / 2).rounded())
                    let inner = CGRect(x: x + padH, y: y + padV + dy, width: max(10, w - padH * 2), height: h - padV * 2 - dy)
                    cell.draw(with: inner, options: measureOptions)
                }
                x += w
            }
            y += h
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()

        // 外框
        context.addPath(clip)
        context.setStrokeColor(style.tableBorder.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    private static func aligned(_ s: NSAttributedString, alignment: TableModel.Alignment) -> NSAttributedString {
        guard alignment == .center || alignment == .right else { return s }
        let m = NSMutableAttributedString(attributedString: s)
        let ps = NSMutableParagraphStyle()
        ps.alignment = alignment == .center ? .center : .right
        ps.lineBreakMode = .byWordWrapping
        m.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: m.length))
        return m
    }
}
