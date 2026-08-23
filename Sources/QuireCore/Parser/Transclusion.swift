import Foundation

/// 内容块（transclusion）：独占一段的 `![[file]]` 在渲染时展开成目标文件的内容（Obsidian 风格；与 wikilink 同族）。
///
/// - `.md / .markdown / .txt` 等文本：按 Markdown 解析后内联（可嵌套，深度 ≤ `maxDepth`，循环包含会被拦下）
/// - `.csv / .tsv`：首行为表头的表格
/// - 图片：图片块
///
/// 解析器本身不碰文件系统：调用方给 `Loader`（在根目录内就近找文件、限制大小），这里只做展开与守卫。
/// 展开出来的块全部带上指令那一行的 `sourceRange`，滚动同步 / 点击回源码仍落在 `![[…]]` 上。
public enum Transclusion {
    public static let maxDepth = 6
    public static let maxBytes = 2 * 1024 * 1024

    /// 加载结果
    public enum Content: Sendable {
        case markdown(String)
        case csv(String)
        case image(path: String, alt: String)
        /// 找不到 / 越界 / 类型不支持 / 太大
        case unavailable(String)
    }
    /// `(目标, 当前文件路径)` → 内容 + 解析出的绝对路径（用于循环检测与监视）
    public typealias Loader = @Sendable (_ target: String, _ fromPath: String?) -> (path: String, content: Content)?

    public struct Result: Sendable {
        public var document: Document
        /// 被内联的文件（绝对路径，去重）：调用方可监视它们的变化
        public var includedPaths: [String]
    }

    /// 识别独占一段的 `![[target]]`（wikilinks 开时段落是 `!` + link；关时是纯文本）
    static func directive(in inlines: [Inline]) -> String? {
        switch inlines.count {
        case 1:
            if case .text(let t) = inlines[0] { return parse(t.trimmingCharacters(in: .whitespaces)) }
        case 2:
            if case .text(let bang) = inlines[0], bang == "!", case .link(let dest, _, _) = inlines[1], let dest, WikiLink.isWikiLink(dest) {
                return WikiLink.target(dest)
            }
        default: break
        }
        return nil
    }

    static func parse(_ s: String) -> String? {
        guard s.hasPrefix("![["), s.hasSuffix("]]"), s.count > 5 else { return nil }
        let inner = s.dropFirst(3).dropLast(2)
        guard !inner.contains("]"), !inner.contains("["), !inner.contains("\n") else { return nil }
        let target = inner.split(separator: "|", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
        return target.isEmpty ? nil : target
    }

    public static func isDirective(_ paragraph: String) -> Bool { parse(paragraph.trimmingCharacters(in: .whitespaces)) != nil }

    /// 展开文档里的内容块；没有指令时原样返回（零开销：只扫段落首个 inline）
    public static func expand(_ doc: Document, parser: MarkdownParser, fromPath: String?, loader: Loader) -> Result {
        var included: [String] = []
        var stack: [String] = fromPath.map { [$0] } ?? []
        let blocks = expand(doc.blocks, parser: parser, loader: loader, stack: &stack, included: &included, depth: 0)
        if blocks.count == doc.blocks.count, zip(blocks, doc.blocks).allSatisfy({ $0.kind == $1.kind }) { return Result(document: doc, includedPaths: []) }
        return Result(document: Document(blocks: blocks, outline: MarkdownParser.makeOutline(blocks)), includedPaths: included)
    }

    private static func expand(_ blocks: [Block], parser: MarkdownParser, loader: Loader, stack: inout [String], included: inout [String], depth: Int) -> [Block] {
        var out: [Block] = []
        out.reserveCapacity(blocks.count)
        for b in blocks {
            guard case .paragraph(let inlines) = b.kind, let target = directive(in: inlines) else { out.append(b); continue }
            out.append(contentsOf: expandOne(target, range: b.sourceRange, original: b, parser: parser, loader: loader, stack: &stack, included: &included, depth: depth))
        }
        return out
    }

    private static func note(_ original: Block, _ message: String) -> Block {
        var inl: [Inline] = []
        if case .paragraph(let i) = original.kind { inl = i }
        inl.append(.text("  ⚠︎ " + message))
        return Block(kind: .paragraph(inl), sourceRange: original.sourceRange)
    }

    private static func expandOne(_ target: String, range: SourceRange?, original: Block, parser: MarkdownParser, loader: Loader, stack: inout [String], included: inout [String], depth: Int) -> [Block] {
        guard depth < maxDepth else { return [note(original, "嵌套太深")] }
        guard let (path, content) = loader(target, stack.last) else { return [note(original, "找不到 \(target)")] }
        if stack.contains(path) { return [note(original, "循环包含 \(target)")] }
        if !included.contains(path) { included.append(path) }
        func stamp(_ bs: [Block]) -> [Block] { bs.map { var b = $0; b.sourceRange = range; return b } }
        switch content {
        case .unavailable(let why): return [note(original, why)]
        case .image(let p, let alt): return [Block(kind: .image(source: p, title: nil, alt: alt), sourceRange: range)]
        case .csv(let text):
            guard let table = CSV.table(text) else { return [note(original, "空表格")] }
            return [Block(kind: .table(table), sourceRange: range)]
        case .markdown(let src):
            var inner = parser.parse(src).blocks
            // 被包含文件的 front matter 不显示
            if case .frontMatter = inner.first?.kind { inner.removeFirst() }
            stack.append(path)
            let expanded = expand(inner, parser: parser, loader: loader, stack: &stack, included: &included, depth: depth + 1)
            stack.removeLast()
            // 被包含文件里的相对图片路径按它自己所在目录解析
            let dir = (path as NSString).deletingLastPathComponent
            return stamp(dir.isEmpty ? expanded : rebaseImages(expanded, dir: dir))
        }
    }

    static func rebaseImages(_ blocks: [Block], dir: String) -> [Block] {
        func src(_ s: String?) -> String? {
            guard let s, !s.isEmpty, !s.hasPrefix("/"), !s.hasPrefix("~"), !s.hasPrefix("data:"),
                  !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://"), !s.lowercased().hasPrefix("file:") else { return s }
            return ((dir as NSString).appendingPathComponent(s.removingPercentEncoding ?? s) as NSString).standardizingPath
        }
        func inl(_ xs: [Inline]) -> [Inline] {
            xs.map { x in
                switch x {
                case .image(let s, let t, let a): return .image(source: src(s), title: t, alt: a)
                case .emphasis(let c): return .emphasis(inl(c))
                case .strong(let c): return .strong(inl(c))
                case .strikethrough(let c): return .strikethrough(inl(c))
                case .link(let d, let t, let c): return .link(destination: d, title: t, children: inl(c))
                case .highlight(let c): return .highlight(inl(c))
                case .subscript(let c): return .subscript(inl(c))
                case .superscript(let c): return .superscript(inl(c))
                case .underline(let c): return .underline(inl(c))
                default: return x
                }
            }
        }
        func blk(_ b: Block) -> Block {
            let k: BlockKind
            switch b.kind {
            case .image(let s, let t, let a): k = .image(source: src(s), title: t, alt: a)
            case .paragraph(let i): k = .paragraph(inl(i))
            case .heading(let l, let i, let id): k = .heading(level: l, inlines: inl(i), id: id)
            case .blockQuote(let bs): k = .blockQuote(bs.map(blk))
            case .list(let o, let st, let items): k = .list(ordered: o, start: st, items: items.map { ListItem(checkbox: $0.checkbox, blocks: $0.blocks.map(blk)) })
            case .table(let t): k = .table(TableModel(alignments: t.alignments, header: t.header.map(inl), rows: t.rows.map { $0.map(inl) }))
            case .footnoteDefinition(let l, let bs): k = .footnoteDefinition(label: l, blocks: bs.map(blk))
            default: return b
            }
            return Block(kind: k, sourceRange: b.sourceRange)
        }
        return blocks.map(blk)
    }
}

/// 极简 CSV / TSV：逗号或制表符分隔（按首行哪个多），双引号包裹可含分隔符与 `""` 转义；首行为表头
public enum CSV {
    public static func rows(_ text: String) -> [[String]] {
        // 按 unicodeScalar 走：Swift 的 Character 会把 "\r\n" 合成一个字素
        let firstLine = text.unicodeScalars.prefix { $0 != "\n" && $0 != "\r" }
        let sep: Unicode.Scalar = firstLine.filter { $0 == "\t" }.count > firstLine.filter { $0 == "," }.count ? "\t" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var it = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? { if let p = pending { pending = nil; return p }; return it.next() }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() { if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n } } else { inQuotes = false }
                } else { field.unicodeScalars.append(c) }
            } else if c == "\"", field.isEmpty { inQuotes = true }
            else if c == sep { row.append(field); field = "" }
            else if c == "\n" || c == "\r" {
                if c == "\r", let n = next(), n != "\n" { pending = n }
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { field.unicodeScalars.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    public static func table(_ text: String) -> TableModel? {
        var r = rows(text)
        guard !r.isEmpty else { return nil }
        let cols = r.map(\.count).max() ?? 0
        guard cols > 0 else { return nil }
        func cell(_ s: String) -> [Inline] { s.isEmpty ? [] : [.text(s)] }
        let header = r.removeFirst()
        let pad: ([String]) -> [[Inline]] = { row in (0..<cols).map { $0 < row.count ? cell(row[$0]) : [] } }
        // 全列都是数字的右对齐
        var aligns = [TableModel.Alignment](repeating: .none, count: cols)
        for c in 0..<cols where !r.isEmpty {
            let numeric = r.allSatisfy { row in c >= row.count || row[c].isEmpty || Double(row[c].replacingOccurrences(of: ",", with: "")) != nil }
            if numeric { aligns[c] = .right }
        }
        return TableModel(alignments: aligns, header: pad(header), rows: r.map(pad))
    }
}
