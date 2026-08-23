import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// cmark-gfm（C API 直调）→ Quire 块模型。
/// 线程安全、无状态；可在任意后台队列调用。每次 parse 独立创建 cmark_parser。
///
/// 为什么不用 swift-markdown：它的中间 AST 层占解析时间约 45%（实测），且不暴露 footnotes 扩展。见 ADR-12。
public struct MarkdownParser: Sendable {
    public struct Options: Sendable {
        /// 识别 YAML front matter（文件开头 `---` … `---`）
        public var frontMatter = true
        /// 把独占一段的单张图片提升为 `.image` 块
        public var promoteStandaloneImages = true
        /// 把 ```mermaid 围栏识别为 `.mermaid`
        public var mermaid = true
        /// `$$…$$` 段落 → `.math`；`$…$`（Pandoc 规则：开头 `$` 后无空白、结尾 `$` 前无空白且后面不是数字）→ `.inlineMath`
        public var math = true
        /// 独占段落 `[TOC]`（也认 `[[TOC]]` / `{{TOC}}` / `[toc]`）→ 按标题生成嵌套链接列表
        public var toc = true
        /// 智能标点（cmark `CMARK_OPT_SMART`）：直引号 → 弯引号、`--` → 短破折、`---` → 长破折、`...` → 省略号
        public var smartPunctuation = false
        /// 扩展行内语法（默认全关）
        public var extendedInline = ExtendedInlineOptions()
        /// 自动识别裸 URL（http/https/www.）为链接。自研扫描器：遇到 CJK 标点即停止（比 GFM autolink 更适合中文文本）
        public var autolink = true
        /// 脚注 `[^1]`
        public var footnotes = true
        public init() {}
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    /// 全局扩展注册（一次）
    private static let extensionsRegistered: Bool = {
        cmark_gfm_core_extensions_ensure_registered()
        return true
    }()

    public func parse(_ source: String) -> Document {
        _ = Self.extensionsRegistered
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

        var cmarkOptions = CMARK_OPT_DEFAULT | CMARK_OPT_SOURCEPOS | CMARK_OPT_VALIDATE_UTF8 | CMARK_OPT_UNSAFE
        if options.footnotes { cmarkOptions |= CMARK_OPT_FOOTNOTES }
        if options.smartPunctuation { cmarkOptions |= CMARK_OPT_SMART }
        guard let parser = cmark_parser_new(cmarkOptions) else { return .empty }
        for name in ["table", "strikethrough", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        var ctx = Context(options: options, lineOffset: lineOffset)
        ctx.fullSource = source
        // 只有源码里出现 `$$` 才做数学块相关的额外工作（按行切分 1 MB 要 ~40 ms，绝大多数文档用不上）
        let hasDisplayMath = options.math && source.utf8.withContiguousStorageIfAvailable { buf -> Bool in
            guard buf.count >= 2 else { return false }
            for i in 0..<(buf.count - 1) where buf[i] == 0x24 && buf[i + 1] == 0x24 { return true }
            return false
        } ?? source.contains("$$")
        if hasDisplayMath { ctx.sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false) }
        // `$$` 独占行的数学块先改写成 ```math 围栏再喂 cmark：否则块内的 `=` / `-` 行会被当 setext 标题、`\` 会被转义。行数不变，源码位置照旧。
        if hasDisplayMath {
            InlineMath.rewriteDisplayBlocks(String(body)).withCString { cstr in cmark_parser_feed(parser, cstr, strlen(cstr)) }
        } else {
            body.withCString { cstr in cmark_parser_feed(parser, cstr, strlen(cstr)) }
        }
        if let root = cmark_parser_finish(parser) {
            var child = cmark_node_first_child(root)
            while let node = child {
                blocks.append(contentsOf: ctx.convertBlock(node))
                child = cmark_node_next(node)
            }
            cmark_node_free(root)
        }
        cmark_parser_free(parser)

        // 大纲
        var entries: [Outline.Entry] = []
        for (i, b) in blocks.enumerated() {
            if case .heading(let level, let inlines, let id) = b.kind {
                entries.append(.init(id: id, level: level, title: inlines.plainText.trimmingCharacters(in: .whitespaces),
                                     blockIndex: i, line: b.sourceRange?.start.line))
            }
        }
        let outline = Outline(entries: entries)
        if options.toc { Self.expandTOC(&blocks, outline: outline) }
        return Document(blocks: blocks, outline: outline)
    }

    /// `[TOC]` 段落 → 嵌套的链接列表（只含 `[TOC]` 之外的标题；层级按标题级别相对缩进）
    static func expandTOC(_ blocks: inout [Block], outline: Outline) {
        let markers: Set<String> = ["[toc]", "[[toc]]", "{{toc}}"]
        for (i, b) in blocks.enumerated() {
            guard case .paragraph(let inl) = b.kind, inl.count == 1, case .text(let t) = inl[0],
                  markers.contains(t.trimmingCharacters(in: .whitespaces).lowercased()) else { continue }
            let entries = outline.entries.filter { $0.blockIndex != i }
            guard !entries.isEmpty else { blocks[i] = Block(kind: .paragraph([]), sourceRange: b.sourceRange); continue }
            blocks[i] = Block(kind: tocList(entries[...], minLevel: entries.map(\.level).min() ?? 1), sourceRange: b.sourceRange)
        }
    }

    private static func tocList(_ entries: ArraySlice<Outline.Entry>, minLevel: Int) -> BlockKind {
        var items: [ListItem] = []
        var k = entries.startIndex
        while k < entries.endIndex {
            let e = entries[k]
            let level = max(e.level, minLevel)
            // 该项的子项：后续级别更深的连续条目
            var j = k + 1
            while j < entries.endIndex, entries[j].level > level { j += 1 }
            var blocks: [Block] = [Block(kind: .paragraph([.link(destination: "#" + e.id, title: nil, children: [.text(e.title)])]))]
            if j > k + 1 {
                let childMin = entries[(k + 1)..<j].map(\.level).min() ?? level + 1
                blocks.append(Block(kind: tocList(entries[(k + 1)..<j], minLevel: childMin)))
            }
            items.append(ListItem(checkbox: nil, blocks: blocks))
            k = j
        }
        return .list(ordered: false, start: 1, items: items)
    }

    // MARK: - Conversion

    private struct Context {
        let options: Options
        let lineOffset: Int
        var ids = HeadingIDGenerator()
        var footnoteOrdinal = 0

        func range(_ n: UnsafeMutablePointer<cmark_node>) -> SourceRange? {
            let sl = Int(cmark_node_get_start_line(n))
            guard sl > 0 else { return nil }
            return SourceRange(start: .init(line: sl + lineOffset, column: Int(cmark_node_get_start_column(n))),
                               end: .init(line: Int(cmark_node_get_end_line(n)) + lineOffset, column: Int(cmark_node_get_end_column(n))))
        }

        @inline(__always) func literal(_ n: UnsafeMutablePointer<cmark_node>) -> String {
            cmark_node_get_literal(n).map { String(cString: $0) } ?? ""
        }
        @inline(__always) func typeString(_ n: UnsafeMutablePointer<cmark_node>) -> String {
            String(cString: cmark_node_get_type_string(n))
        }

        mutating func convertChildren(_ n: UnsafeMutablePointer<cmark_node>) -> [Block] {
            var out: [Block] = []
            var child = cmark_node_first_child(n)
            while let c = child { out.append(contentsOf: convertBlock(c)); child = cmark_node_next(c) }
            return out
        }

        mutating func convertBlock(_ n: UnsafeMutablePointer<cmark_node>) -> [Block] {
            let r = range(n)
            switch cmark_node_get_type(n) {
            case CMARK_NODE_HEADING:
                let inlines = convertInlines(n)
                let id = ids.next(for: inlines.plainText)
                return [Block(kind: .heading(level: Int(cmark_node_get_heading_level(n)), inlines: inlines, id: id), sourceRange: r)]

            case CMARK_NODE_PARAGRAPH:
                if options.math, !sourceLines.isEmpty, let r, let math = mathBlock(lines: r.start.line...r.end.line) {
                    return [Block(kind: .math(math), sourceRange: r)]
                }
                let inlines = convertInlines(n)
                if options.promoteStandaloneImages, inlines.count == 1,
                   case .image(let src, let title, let alt) = inlines[0] {
                    return [Block(kind: .image(source: src, title: title, alt: alt), sourceRange: r)]
                }
                return [Block(kind: .paragraph(inlines), sourceRange: r)]

            case CMARK_NODE_CODE_BLOCK:
                let info = cmark_node_get_fence_info(n).map { String(cString: $0) }?.trimmingCharacters(in: .whitespaces)
                var code = literal(n)
                if code.hasSuffix("\n") { code.removeLast() }
                if options.mermaid, info?.lowercased() == "mermaid" {
                    return [Block(kind: .mermaid(source: code), sourceRange: r)]
                }
                if options.math, info?.lowercased() == "math" {   // 自己改写的 `$$` 块，或 GitLab 风格的 ```math
                    let src = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    return src.isEmpty ? [] : [Block(kind: .math(src), sourceRange: r)]
                }
                return [Block(kind: .codeBlock(language: (info?.isEmpty ?? true) ? nil : info, code: code), sourceRange: r)]

            case CMARK_NODE_BLOCK_QUOTE:
                return [Block(kind: .blockQuote(convertChildren(n)), sourceRange: r)]

            case CMARK_NODE_LIST:
                let ordered = cmark_node_get_list_type(n) == CMARK_ORDERED_LIST
                let start = ordered ? Int(cmark_node_get_list_start(n)) : 1
                var items: [ListItem] = []
                var child = cmark_node_first_child(n)
                while let item = child {
                    let checkbox: ListItem.Checkbox? = typeString(item) == "tasklist"
                        ? (cmark_gfm_extensions_get_tasklist_item_checked(item) ? .checked : .unchecked) : nil
                    items.append(ListItem(checkbox: checkbox, blocks: convertChildren(item)))
                    child = cmark_node_next(item)
                }
                return [Block(kind: .list(ordered: ordered, start: start, items: items), sourceRange: r)]

            case CMARK_NODE_THEMATIC_BREAK:
                return [Block(kind: .thematicBreak, sourceRange: r)]

            case CMARK_NODE_HTML_BLOCK:
                var html = literal(n)
                if html.hasSuffix("\n") { html.removeLast() }
                return [Block(kind: .html(html), sourceRange: r)]

            case CMARK_NODE_FOOTNOTE_DEFINITION:
                // cmark-gfm 会把引用重编号为 1、2、3… 并把定义按序挪到文末；这里给定义同样的序号，保证引用 ↔ 定义一致
                footnoteOrdinal += 1
                return [Block(kind: .footnoteDefinition(label: String(footnoteOrdinal), blocks: convertChildren(n)), sourceRange: r)]

            case CMARK_NODE_CUSTOM_BLOCK, CMARK_NODE_ITEM:
                return convertChildren(n)

            default:
                // 扩展节点：按类型名判断
                if typeString(n) == "table" { return [Block(kind: .table(convertTable(n)), sourceRange: r)] }
                // 未知块：子块展开或退化为段落
                let children = convertChildren(n)
                if !children.isEmpty { return children }
                let inlines = convertInlines(n)
                return inlines.isEmpty ? [] : [Block(kind: .paragraph(inlines), sourceRange: r)]
            }
        }

        mutating func convertTable(_ n: UnsafeMutablePointer<cmark_node>) -> TableModel {
            let cols = Int(cmark_gfm_extensions_get_table_columns(n))
            var aligns: [TableModel.Alignment] = []
            if let a = cmark_gfm_extensions_get_table_alignments(n) {
                for i in 0..<cols {
                    switch a[i] {
                    case UInt8(ascii: "l"): aligns.append(.left)
                    case UInt8(ascii: "c"): aligns.append(.center)
                    case UInt8(ascii: "r"): aligns.append(.right)
                    default: aligns.append(.none)
                    }
                }
            }
            var header: [[Inline]] = []
            var rows: [[[Inline]]] = []
            var row = cmark_node_first_child(n)
            while let rn = row {
                var cells: [[Inline]] = []
                var cell = cmark_node_first_child(rn)
                while let cn = cell { cells.append(convertInlines(cn)); cell = cmark_node_next(cn) }
                if cmark_gfm_extensions_get_table_row_is_header(rn) != 0 && header.isEmpty { header = cells } else { rows.append(cells) }
                row = cmark_node_next(rn)
            }
            return TableModel(alignments: aligns, header: header, rows: rows)
        }

        var sourceLines: [Substring] = []
        var fullSource: String = ""
        var lazyLines: [Substring]?
        /// 按需切行（只在需要看原文的扩展语法路径上用）
        mutating func line(_ n: Int) -> Substring? {
            if lazyLines == nil { lazyLines = sourceLines.isEmpty ? fullSource.split(separator: "\n", omittingEmptySubsequences: false) : sourceLines }
            guard let ls = lazyLines, n >= 1, n <= ls.count else { return nil }
            return ls[n - 1]
        }
        /// `~x~`（单波浪线）在 GFM 里也是删除线；下标选项开着时按原文区分：开头是 `~~` 才算删除线
        mutating func isSingleTilde(_ n: UnsafeMutablePointer<cmark_node>) -> Bool {
            guard let r = range(n), let l = line(r.start.line) else { return false }
            let u = Array(l.utf8)
            let col = r.start.column - 1
            guard col >= 0, col < u.count, u[col] == 0x7E else { return false }
            return !(col + 1 < u.count && u[col + 1] == 0x7E)
        }

        /// 段落原文（按行范围取，不经 cmark 的转义 / 强调解析）是否是 `$$ … $$`
        func mathBlock(lines: ClosedRange<Int>) -> String? {
            guard lines.lowerBound >= 1, lines.upperBound <= sourceLines.count else { return nil }
            let raw = sourceLines[(lines.lowerBound - 1)...(lines.upperBound - 1)].joined(separator: "\n")
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("$$"), t.hasSuffix("$$"), t.count >= 4 else { return nil }
            let inner = t.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }

        mutating func convertInlines(_ n: UnsafeMutablePointer<cmark_node>) -> [Inline] {
            var out: [Inline] = []
            var child = cmark_node_first_child(n)
            while let c = child { convertInline(c, into: &out); child = cmark_node_next(c) }
            return options.extendedInline.any ? ExtendedInline.apply(out, options: options.extendedInline) : out
        }

        mutating func convertInline(_ n: UnsafeMutablePointer<cmark_node>, into out: inout [Inline]) {
            switch cmark_node_get_type(n) {
            case CMARK_NODE_TEXT:
                let s = literal(n)
                if options.math, s.utf8.contains(0x24) {   // 有 $ 才切行内数学（1 MB 文档十万个文本节点，不能每个都走 String.contains）
                    for piece in InlineMath.split(s) {
                        if case .text(let t) = piece, options.autolink { Autolink.scan(t, into: &out) } else { out.append(piece) }
                    }
                } else if options.autolink { Autolink.scan(s, into: &out) } else { out.append(.text(s)) }
            case CMARK_NODE_EMPH: out.append(.emphasis(convertInlines(n)))
            case CMARK_NODE_STRONG: out.append(.strong(convertInlines(n)))
            case CMARK_NODE_CODE: out.append(.code(literal(n)))
            case CMARK_NODE_LINK:
                let url = cmark_node_get_url(n).map { String(cString: $0) }
                let title = cmark_node_get_title(n).map { String(cString: $0) }
                out.append(.link(destination: url, title: (title?.isEmpty ?? true) ? nil : title, children: convertInlines(n)))
            case CMARK_NODE_IMAGE:
                let url = cmark_node_get_url(n).map { String(cString: $0) }
                let title = cmark_node_get_title(n).map { String(cString: $0) }
                let alt = convertInlines(n).plainText
                out.append(.image(source: url, title: (title?.isEmpty ?? true) ? nil : title, alt: alt))
            case CMARK_NODE_SOFTBREAK: out.append(.softBreak)
            case CMARK_NODE_LINEBREAK: out.append(.lineBreak)
            case CMARK_NODE_HTML_INLINE: out.append(.html(literal(n)))
            case CMARK_NODE_FOOTNOTE_REFERENCE: out.append(.footnoteReference(label: literal(n)))
            case CMARK_NODE_CUSTOM_INLINE:
                out.append(contentsOf: convertInlines(n))
            default:
                if typeString(n) == "strikethrough" {
                    if options.extendedInline.subscriptText, isSingleTilde(n) { out.append(.subscript(convertInlines(n))) }
                    else { out.append(.strikethrough(convertInlines(n))) }
                }
                else { out.append(contentsOf: convertInlines(n)) }
            }
        }
    }
}

// MARK: - Front matter

enum FrontMatter {
    struct Split { let yaml: String; let body: Substring; let lineCount: Int }

    /// 文件必须以 `---\n` 开头，第二个仅含 `---`（或 `...`）的行结束。只扫描开头，不触碰正文。
    static func split(_ source: String) -> Split? {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return nil }
        let utf8 = source.utf8
        guard let firstNL = utf8.firstIndex(of: 0x0A) else { return nil }
        var idx = utf8.index(after: firstNL)
        let yamlStart = idx
        var lineNo = 1
        while idx < utf8.endIndex {
            let lineEnd = utf8[idx...].firstIndex(of: 0x0A) ?? utf8.endIndex
            var content = utf8[idx..<lineEnd]
            if content.last == 0x0D { content = content.dropLast() }
            lineNo += 1
            if content.elementsEqual("---".utf8) || content.elementsEqual("...".utf8) {
                let yaml = String(source[yamlStart..<idx]).trimmingCharacters(in: .newlines)
                let bodyStart = lineEnd < utf8.endIndex ? utf8.index(after: lineEnd) : utf8.endIndex
                return Split(yaml: yaml, body: source[bodyStart...], lineCount: lineNo)
            }
            if lineNo > 200 { return nil } // 防御：front matter 不该这么长
            idx = lineEnd < utf8.endIndex ? utf8.index(after: lineEnd) : utf8.endIndex
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
