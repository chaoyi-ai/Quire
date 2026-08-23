import Foundation

/// 源码位置（1-based 行，1-based 列，列以 UTF-8 字节计，与 cmark 一致）。
public struct SourcePosition: Hashable, Sendable, Comparable {
    public var line: Int
    public var column: Int
    public init(line: Int, column: Int) { self.line = line; self.column = column }
    public static func < (a: SourcePosition, b: SourcePosition) -> Bool {
        a.line != b.line ? a.line < b.line : a.column < b.column
    }
}

/// 源码范围。`end` 为闭区间末尾（cmark 语义）。
public struct SourceRange: Hashable, Sendable {
    public var start: SourcePosition
    public var end: SourcePosition
    public init(start: SourcePosition, end: SourcePosition) { self.start = start; self.end = end }
    public var lineRange: ClosedRange<Int> { start.line...end.line }
}

/// 行内元素。
public indirect enum Inline: Hashable, Sendable {
    case text(String)
    case emphasis([Inline])
    case strong([Inline])
    case strikethrough([Inline])
    case code(String)
    case link(destination: String?, title: String?, children: [Inline])
    case image(source: String?, title: String?, alt: String)
    case softBreak
    case lineBreak
    case html(String)
    /// `[^label]` 脚注引用（后处理产生）
    case footnoteReference(label: String)
    /// `$…$` 行内数学（Pandoc 规则，后处理产生）
    case inlineMath(String)

    /// 纯文本（用于标题 id、大纲、辅助功能）
    public var plainText: String {
        switch self {
        case .text(let s), .code(let s): return s
        case .emphasis(let c), .strong(let c), .strikethrough(let c): return c.plainText
        case .link(_, _, let c): return c.plainText
        case .image(_, _, let alt): return alt
        case .softBreak, .lineBreak: return " "
        case .html: return ""
        case .footnoteReference(let l): return "[\(l)]"
        case .inlineMath(let s): return s
        }
    }
}

extension Array where Element == Inline {
    public var plainText: String { map(\.plainText).joined() }
}

/// 列表项。
public struct ListItem: Hashable, Sendable {
    public enum Checkbox: Hashable, Sendable { case checked, unchecked }
    public var checkbox: Checkbox?
    public var blocks: [Block]
    public init(checkbox: Checkbox? = nil, blocks: [Block]) { self.checkbox = checkbox; self.blocks = blocks }
}

/// GFM 表格。
public struct TableModel: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable { case none, left, center, right }
    public var alignments: [Alignment]
    public var header: [[Inline]]
    public var rows: [[[Inline]]]
    public init(alignments: [Alignment], header: [[Inline]], rows: [[[Inline]]]) {
        self.alignments = alignments; self.header = header; self.rows = rows
    }
    public var columnCount: Int { max(alignments.count, header.count, rows.map(\.count).max() ?? 0) }
}

/// 块级元素类型。
public indirect enum BlockKind: Hashable, Sendable {
    case heading(level: Int, inlines: [Inline], id: String)
    case paragraph([Inline])
    case codeBlock(language: String?, code: String)
    case mermaid(source: String)
    case blockQuote([Block])
    case list(ordered: Bool, start: Int, items: [ListItem])
    case table(TableModel)
    case thematicBreak
    case html(String)
    case image(source: String?, title: String?, alt: String)
    case frontMatter(String)
    case footnoteDefinition(label: String, blocks: [Block])
    /// `$$ … $$` 数学块（LaTeX）
    case math(String)
}

/// 块 = 类型 + 源码范围。**相等性与哈希只看内容**，不看位置，以便增量 diff 识别"未变化但移动了"的块。
public struct Block: Hashable, Sendable {
    public var kind: BlockKind
    public var sourceRange: SourceRange?
    /// 内容哈希（构造时计算一次，diff 时 O(1)）
    public let contentHash: Int

    public init(kind: BlockKind, sourceRange: SourceRange? = nil) {
        self.kind = kind
        self.sourceRange = sourceRange
        var h = Hasher()
        kind.hash(into: &h)
        self.contentHash = h.finalize()
    }

    public static func == (a: Block, b: Block) -> Bool { a.contentHash == b.contentHash && a.kind == b.kind }
    public func hash(into hasher: inout Hasher) { hasher.combine(contentHash) }
}

/// 解析后的文档：不可变值类型。
public struct Document: Sendable {
    public var blocks: [Block]
    public var outline: Outline

    public init(blocks: [Block], outline: Outline) {
        self.blocks = blocks; self.outline = outline
    }
    public static let empty = Document(blocks: [], outline: Outline(entries: []))
}
