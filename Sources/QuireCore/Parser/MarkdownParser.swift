import Foundation
import Markdown

/// swift-markdown（cmark-gfm）→ Quire 块模型。
/// 线程安全、无状态；可在任意后台队列调用。
public struct MarkdownParser: Sendable {
    public struct Options: Sendable {
        /// 识别 YAML front matter（文件开头 `---` … `---`）
        public var frontMatter = true
        /// 把独占一段的单张图片提升为 `.image` 块
        public var promoteStandaloneImages = true
        /// 把 ```mermaid 围栏识别为 `.mermaid`
        public var mermaid = true
        /// 自动识别裸 URL（http/https/www.）为链接
        public var autolink = true
        public init() {}
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    public func parse(_ source: String) -> Document {
        var lineOffset = 0
        var blocks: [Block] = []
        var body = Substring(source)

        if options.frontMatter, let fm = FrontMatter.split(source) {
            blocks.append(Block(kind: .frontMatter(fm.yaml),
                                sourceRange: SourceRange(start: .init(line: 1, column: 1),
                                                         end: .init(line: fm.lineCount, column: 1))))
            lineOffset = fm.lineCount
            body = fm.body
        }

        let md = Markdown.Document(parsing: String(body), options: [.disableSmartOpts])
        var ctx = Context(options: options, lineOffset: lineOffset)
        for child in md.children {
            blocks.append(contentsOf: ctx.convertBlock(child))
        }

        // 大纲
        var entries: [Outline.Entry] = []
        for (i, b) in blocks.enumerated() {
            if case .heading(let level, let inlines, let id) = b.kind {
                entries.append(.init(id: id, level: level, title: inlines.plainText.trimmingCharacters(in: .whitespaces),
                                     blockIndex: i, line: b.sourceRange?.start.line))
            }
        }
        let lineCount = source.utf8.reduce(into: 1) { if $1 == 0x0A { $0 += 1 } }
        return Document(blocks: blocks, outline: Outline(entries: entries), lineCount: lineCount)
    }

    // MARK: - Conversion

    private struct Context {
        let options: Options
        let lineOffset: Int
        var ids = HeadingIDGenerator()

        func range(_ m: Markup) -> SourceRange? {
            guard let r = m.range else { return nil }
            return SourceRange(start: .init(line: r.lowerBound.line + lineOffset, column: r.lowerBound.column),
                               end: .init(line: r.upperBound.line + lineOffset, column: r.upperBound.column))
        }

        mutating func convertBlocks(_ children: MarkupChildren) -> [Block] {
            var out: [Block] = []
            for c in children { out.append(contentsOf: convertBlock(c)) }
            return out
        }

        mutating func convertBlock(_ m: Markup) -> [Block] {
            let r = range(m)
            switch m {
            case let h as Heading:
                let inlines = convertInlines(h.children)
                let id = ids.next(for: inlines.plainText)
                return [Block(kind: .heading(level: h.level, inlines: inlines, id: id), sourceRange: r)]

            case let p as Paragraph:
                let inlines = convertInlines(p.children)
                if options.promoteStandaloneImages, inlines.count == 1,
                   case .image(let src, let title, let alt) = inlines[0] {
                    return [Block(kind: .image(source: src, title: title, alt: alt), sourceRange: r)]
                }
                return [Block(kind: .paragraph(inlines), sourceRange: r)]

            case let c as CodeBlock:
                let lang = c.language?.trimmingCharacters(in: .whitespaces)
                let langLower = lang?.lowercased()
                var code = c.code
                if code.hasSuffix("\n") { code.removeLast() }
                if options.mermaid, langLower == "mermaid" {
                    return [Block(kind: .mermaid(source: code), sourceRange: r)]
                }
                return [Block(kind: .codeBlock(language: (lang?.isEmpty ?? true) ? nil : lang, code: code), sourceRange: r)]

            case let q as BlockQuote:
                return [Block(kind: .blockQuote(convertBlocks(q.children)), sourceRange: r)]

            case let l as UnorderedList:
                return [Block(kind: .list(ordered: false, start: 1, items: convertItems(l.children)), sourceRange: r)]

            case let l as OrderedList:
                return [Block(kind: .list(ordered: true, start: Int(l.startIndex), items: convertItems(l.children)), sourceRange: r)]

            case let t as Table:
                return [Block(kind: .table(convertTable(t)), sourceRange: r)]

            case is ThematicBreak:
                return [Block(kind: .thematicBreak, sourceRange: r)]

            case let h as HTMLBlock:
                var html = h.rawHTML
                if html.hasSuffix("\n") { html.removeLast() }
                return [Block(kind: .html(html), sourceRange: r)]

            case let other as BlockMarkup:
                // 未知块（BlockDirective 等）：退化为段落文本
                let inlines = convertInlines(other.children)
                return inlines.isEmpty ? [] : [Block(kind: .paragraph(inlines), sourceRange: r)]

            default:
                return []
            }
        }

        mutating func convertItems(_ children: MarkupChildren) -> [ListItem] {
            var items: [ListItem] = []
            for c in children {
                guard let li = c as? Markdown.ListItem else { continue }
                let cb: ListItem.Checkbox? = switch li.checkbox {
                    case .checked?: .checked
                    case .unchecked?: .unchecked
                    case nil: nil
                }
                items.append(ListItem(checkbox: cb, blocks: convertBlocks(li.children)))
            }
            return items
        }

        mutating func convertTable(_ t: Table) -> TableModel {
            let aligns: [TableModel.Alignment] = t.columnAlignments.map {
                switch $0 {
                case .left?: .left
                case .center?: .center
                case .right?: .right
                case nil: .none
                }
            }
            var header: [[Inline]] = []
            for cell in t.head.cells { header.append(convertInlines(cell.children)) }
            var rows: [[[Inline]]] = []
            for row in t.body.rows {
                var cells: [[Inline]] = []
                for cell in row.cells { cells.append(convertInlines(cell.children)) }
                rows.append(cells)
            }
            return TableModel(alignments: aligns, header: header, rows: rows)
        }

        mutating func convertInlines(_ children: MarkupChildren) -> [Inline] {
            var out: [Inline] = []
            for c in children { convertInline(c, into: &out) }
            return out
        }

        mutating func convertInline(_ m: Markup, into out: inout [Inline]) {
            switch m {
            case let t as Text:
                if options.autolink { Autolink.scan(t.string, into: &out) } else { out.append(.text(t.string)) }
            case let e as Emphasis: out.append(.emphasis(convertInlines(e.children)))
            case let s as Strong: out.append(.strong(convertInlines(s.children)))
            case let s as Strikethrough: out.append(.strikethrough(convertInlines(s.children)))
            case let c as InlineCode: out.append(.code(c.code))
            case let l as Link:
                out.append(.link(destination: l.destination, title: l.title, children: convertInlines(l.children)))
            case let i as Image:
                out.append(.image(source: i.source, title: i.title, alt: i.children.compactMap { ($0 as? Text)?.string ?? ($0 as? InlineCode)?.code }.joined()))
            case is SoftBreak: out.append(.softBreak)
            case is LineBreak: out.append(.lineBreak)
            case let h as InlineHTML: out.append(.html(h.rawHTML))
            case let other as InlineContainer:
                // InlineAttributes 等：展开子节点
                for c in other.children { convertInline(c, into: &out) }
            default:
                let s = m.format()
                if !s.isEmpty { out.append(.text(s)) }
            }
        }
    }
}

// MARK: - Front matter

enum FrontMatter {
    struct Split { let yaml: String; let body: Substring; let lineCount: Int }

    /// 文件必须以 `---\n` 开头，第二个仅含 `---` 的行结束。
    static func split(_ source: String) -> Split? {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return nil }
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return nil }
        lines.removeFirst()
        var yamlLines: [Substring] = []
        for (i, raw) in lines.enumerated() {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line == "---" || line == "..." {
                let consumed = i + 2 // 首行 --- + yaml + 结束行
                let bodyStartIndex: String.Index = {
                    var idx = source.startIndex
                    var n = 0
                    while n < consumed, let nl = source[idx...].firstIndex(of: "\n") {
                        idx = source.index(after: nl); n += 1
                    }
                    return idx
                }()
                return Split(yaml: yamlLines.joined(separator: "\n"), body: source[bodyStartIndex...], lineCount: consumed)
            }
            yamlLines.append(line)
            if i > 200 { return nil } // 防御：front matter 不该这么长
        }
        return nil
    }
}

// MARK: - Autolink

enum Autolink {
    /// 在纯文本里识别 `http://` `https://` `www.` 开头的裸链接。单趟扫描，无正则。
    static func scan(_ s: String, into out: inout [Inline]) {
        // 快速路径：绝大多数文本没有链接
        guard s.utf8.contains(0x3A) /* : */ || s.contains("www.") else { out.append(.text(s)); return }
        var rest = Substring(s)
        var plain = ""
        while !rest.isEmpty {
            guard let (start, isWWW) = findStart(rest) else { plain.append(contentsOf: rest); break }
            plain.append(contentsOf: rest[rest.startIndex..<start])
            // 到空白 / 尖括号 / 任何非 ASCII 字符（中文标点、CJK 文本）为止
            var end = rest[start...].firstIndex(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || !$0.isASCII }) ?? rest.endIndex
            // 去掉尾部标点；括号平衡
            while end > start {
                let ch = rest[rest.index(before: end)]
                if ".,:;!?'\"*_~".contains(ch) { end = rest.index(before: end); continue }
                if ch == ")" {
                    let seg = rest[start..<end]
                    let opens = seg.filter { $0 == "(" }.count, closes = seg.filter { $0 == ")" }.count
                    if closes > opens { end = rest.index(before: end); continue }
                }
                break
            }
            let url = String(rest[start..<end])
            // 域名至少要有一个点，且不是纯 "www."
            let hostOK = url.dropFirst(isWWW ? 4 : (url.hasPrefix("https") ? 8 : 7)).contains(".")
            if hostOK, url.count > (isWWW ? 5 : 10) {
                if !plain.isEmpty { out.append(.text(plain)); plain = "" }
                let dest = isWWW ? "http://" + url : url
                out.append(.link(destination: dest, title: nil, children: [.text(url)]))
                rest = rest[end...]
            } else {
                plain.append(contentsOf: rest[start..<end])
                rest = rest[end...]
            }
        }
        if !plain.isEmpty { out.append(.text(plain)) }
    }

    private static func findStart(_ s: Substring) -> (Substring.Index, Bool)? {
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "h" || c == "w" {
                let prevOK = i == s.startIndex || !(s[s.index(before: i)].isLetter || s[s.index(before: i)].isNumber || s[s.index(before: i)] == "/")
                if prevOK {
                    let tail = s[i...]
                    if tail.hasPrefix("http://") || tail.hasPrefix("https://") { return (i, false) }
                    if tail.hasPrefix("www.") { return (i, true) }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
