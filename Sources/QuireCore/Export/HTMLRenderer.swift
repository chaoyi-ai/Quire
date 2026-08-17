import Foundation

/// Document → 独立 HTML（内联主题 CSS，代码高亮为 span，Mermaid 保留为 `<pre class="mermaid">` 并可选引入 mermaid CDN）。
public struct HTMLRenderer: Sendable {
    public struct Options: Sendable {
        public var title: String = "Document"
        /// 是否在页尾引入 mermaid（CDN）以渲染图；关闭则原样显示源码
        public var includeMermaidScript = true
        public var highlighter = SyntaxHighlighter()
        public init() {}
    }

    public let theme: Theme
    public var options: Options

    public init(theme: Theme, options: Options = Options()) {
        self.theme = theme
        self.options = options
    }

    public func render(_ doc: Document) -> String {
        var body = ""
        for b in doc.blocks { body += block(b) }
        return """
        <!doctype html>
        <html lang="zh">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(options.title))</title>
        <meta name="generator" content="Quire">
        <style>
        \(css())
        </style>
        </head>
        <body>
        <article class="quire">
        \(body)
        </article>
        \(options.includeMermaidScript && doc.blocks.contains(where: { if case .mermaid = $0.kind { true } else { false } }) ? mermaidScript : "")
        </body>
        </html>
        """
    }

    // MARK: - CSS

    func css() -> String {
        let c = theme.colors, t = theme.typography, l = theme.layout
        func font(_ list: [String]) -> String {
            list.map {
                switch $0.lowercased() {
                case "system", "-apple-system", "system-ui": return "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
                case "system-serif": return "ui-serif, Georgia, serif"
                case "system-rounded": return "ui-rounded, -apple-system, sans-serif"
                case "system-mono", "monospace": return "ui-monospace, SFMono-Regular, Menlo, monospace"
                default: return "\"\($0)\""
                }
            }.joined(separator: ", ")
        }
        var syntax = ""
        for k in TokenKind.allCases where k != .plain {
            syntax += ".tok-\(k.rawValue){color:\(c.syntaxColor(k).hexString)}\n"
        }
        return """
        html{background:\(c.background.hexString)}
        body{margin:0;padding:\(Int(l.verticalPadding))px \(Int(l.horizontalPadding))px;color:\(c.foreground.hexString);background:\(c.background.hexString);font-family:\(font(t.bodyFont));font-size:\(t.baseSize)px;line-height:\(t.lineHeight)}
        .quire{max-width:\(l.maxContentWidth > 0 ? "\(Int(l.maxContentWidth))px" : "none");margin:0 auto}
        p{margin:0 0 \(t.paragraphSpacing)em}
        h1,h2,h3,h4,h5,h6{color:\(c.heading.hexString);font-weight:\(cssWeight(t.headingWeight));margin:\(t.headingSpacingBefore)em 0 0.6em;line-height:1.3}
        h1{font-size:\(t.headingScale[safe: 0] ?? 2)em;border-bottom:1px solid \(c.border.hexString);padding-bottom:.3em}
        h2{font-size:\(t.headingScale[safe: 1] ?? 1.5)em;border-bottom:1px solid \(c.border.hexString);padding-bottom:.3em}
        h3{font-size:\(t.headingScale[safe: 2] ?? 1.25)em}h4{font-size:\(t.headingScale[safe: 3] ?? 1)em}h5{font-size:\(t.headingScale[safe: 4] ?? 0.875)em}h6{font-size:\(t.headingScale[safe: 5] ?? 0.85)em;color:\(c.muted.hexString)}
        a{color:\(c.accent.hexString);text-decoration:none}a:hover{text-decoration:underline}
        code{font-family:\(font(t.codeFont));font-size:\(t.codeSize)em;background:\(c.code.inlineBackground.hexString);color:\(c.code.inlineForeground.hexString);padding:.15em .35em;border-radius:4px}
        pre{background:\(c.code.background.hexString);color:\(c.code.foreground.hexString);border-radius:\(Int(l.codeBlockRadius))px;padding:\(Int(l.codeBlockPadding))px;overflow-x:auto;line-height:1.5;margin:0 0 \(t.paragraphSpacing)em;border:1px solid \(c.code.border.hexString)}
        pre code{background:transparent;color:inherit;padding:0;font-size:\(t.codeSize)em}
        blockquote{margin:0 0 \(t.paragraphSpacing)em;padding:.1em 0 .1em 1em;border-left:\(Int(l.blockquoteBarWidth))px solid \(c.blockquote.border.hexString);color:\(c.blockquote.foreground.hexString);background:\(c.blockquote.background.hexString)}
        ul,ol{margin:0 0 \(t.paragraphSpacing)em;padding-left:1.75em}li{margin:.2em 0}li.task{list-style:none;margin-left:-1.5em}li.task input{margin-right:.5em;accent-color:\(c.accent.hexString)}
        hr{border:0;border-top:1px solid \(c.border.hexString);margin:1.5em 0}
        table{border-collapse:collapse;margin:0 0 \(t.paragraphSpacing)em;max-width:100%;display:block;overflow-x:auto}
        th,td{border:1px solid \(c.table.border.hexString);padding:\(Int(l.tableCellPadding.first ?? 6))px \(Int(l.tableCellPadding[safe: 1] ?? 12))px;text-align:left}
        th{background:\(c.table.headerBackground.hexString);font-weight:600}tr:nth-child(even) td{background:\(c.table.stripe.hexString)}
        img{max-width:100%;height:auto}figure{margin:0 0 \(t.paragraphSpacing)em;text-align:center}figcaption{color:\(c.muted.hexString);font-size:.85em;margin-top:.3em}
        .front-matter{color:\(c.muted.hexString);font-size:.85em}
        .footnotes{font-size:.85em;color:\(c.muted.hexString);border-top:1px solid \(c.border.hexString);margin-top:2em;padding-top:1em}
        sup.fn a{padding:0 .15em}
        .mermaid{background:transparent;text-align:center}
        \(syntax)
        """
    }

    private func cssWeight(_ w: Theme.Typography.Weight) -> Int {
        switch w { case .regular: 400; case .medium: 500; case .semibold: 600; case .bold: 700; case .heavy: 800 }
    }

    private var mermaidScript: String {
        """
        <script type="module">
        import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@\(HTMLRenderer.mermaidVersion)/dist/mermaid.esm.min.mjs";
        mermaid.initialize({ startOnLoad: true, theme: "\(theme.mermaid.theme)" });
        </script>
        """
    }
    public static let mermaidVersion = "11.16.1"

    // MARK: - Blocks

    func block(_ b: Block) -> String {
        switch b.kind {
        case .heading(let level, let inl, let id):
            return "<h\(level) id=\"\(esc(id))\">\(inlines(inl))</h\(level)>\n"
        case .paragraph(let inl):
            return "<p>\(inlines(inl))</p>\n"
        case .codeBlock(let lang, let code):
            let cls = lang.map { " class=\"language-\(esc($0))\"" } ?? ""
            return "<pre><code\(cls)>\(highlighted(code, language: lang))</code></pre>\n"
        case .mermaid(let src):
            return "<pre class=\"mermaid\">\(esc(src))</pre>\n"
        case .html(let raw):
            return raw + "\n"
        case .frontMatter(let yaml):
            return "<pre class=\"front-matter\"><code>\(esc(yaml))</code></pre>\n"
        case .blockQuote(let blocks):
            return "<blockquote>\n\(blocks.map(block).joined())</blockquote>\n"
        case .list(let ordered, let start, let items):
            let tag = ordered ? "ol" : "ul"
            let startAttr = ordered && start != 1 ? " start=\"\(start)\"" : ""
            var s = "<\(tag)\(startAttr)>\n"
            for it in items {
                if let cb = it.checkbox {
                    s += "<li class=\"task\"><input type=\"checkbox\" disabled\(cb == .checked ? " checked" : "")>"
                } else { s += "<li>" }
                s += listItemBody(it.blocks)
                s += "</li>\n"
            }
            return s + "</\(tag)>\n"
        case .table(let t):
            var s = "<table>\n<thead><tr>"
            for (i, h) in t.header.enumerated() { s += "<th\(align(t, i))>\(inlines(h))</th>" }
            s += "</tr></thead>\n<tbody>\n"
            for row in t.rows {
                s += "<tr>"
                for i in 0..<t.columnCount { s += "<td\(align(t, i))>\(i < row.count ? inlines(row[i]) : "")</td>" }
                s += "</tr>\n"
            }
            return s + "</tbody>\n</table>\n"
        case .thematicBreak:
            return "<hr>\n"
        case .image(let src, let title, let alt):
            let cap = title.map { "<figcaption>\(esc($0))</figcaption>" } ?? ""
            return "<figure><img src=\"\(esc(src ?? ""))\" alt=\"\(esc(alt))\"\(title.map { " title=\"\(esc($0))\"" } ?? "")>\(cap)</figure>\n"
        case .footnoteDefinition(let label, let blocks):
            return "<div class=\"footnotes\" id=\"fn-\(esc(label))\"><sup>\(esc(label))</sup> \(blocks.map(block).joined())</div>\n"
        }
    }

    private func align(_ t: TableModel, _ i: Int) -> String {
        guard i < t.alignments.count else { return "" }
        switch t.alignments[i] {
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        default: return ""
        }
    }

    /// 单段列表项不包 <p>（紧凑）
    private func listItemBody(_ blocks: [Block]) -> String {
        if blocks.count == 1, case .paragraph(let inl) = blocks[0].kind { return inlines(inl) }
        return blocks.map(block).joined()
    }

    private func highlighted(_ code: String, language: String?) -> String {
        let tokens = options.highlighter.highlight(code, language: language)
        guard !tokens.isEmpty else { return esc(code) }
        let ns = code as NSString
        var out = ""
        var pos = 0
        for t in tokens.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where t.kind != .plain {
            let lo = max(pos, t.range.lowerBound), hi = min(ns.length, t.range.upperBound)
            guard hi > lo else { continue }
            if lo > pos { out += esc(ns.substring(with: NSRange(location: pos, length: lo - pos))) }
            out += "<span class=\"tok-\(t.kind.rawValue)\">\(esc(ns.substring(with: NSRange(location: lo, length: hi - lo))))</span>"
            pos = hi
        }
        if pos < ns.length { out += esc(ns.substring(from: pos)) }
        return out
    }

    // MARK: - Inlines

    func inlines(_ list: [Inline]) -> String { list.map(inline).joined() }

    func inline(_ i: Inline) -> String {
        switch i {
        case .text(let s): return esc(s)
        case .emphasis(let c): return "<em>\(inlines(c))</em>"
        case .strong(let c): return "<strong>\(inlines(c))</strong>"
        case .strikethrough(let c): return "<del>\(inlines(c))</del>"
        case .code(let s): return "<code>\(esc(s))</code>"
        case .link(let dest, let title, let c):
            return "<a href=\"\(esc(dest ?? ""))\"\(title.map { " title=\"\(esc($0))\"" } ?? "")>\(inlines(c))</a>"
        case .image(let src, let title, let alt):
            return "<img src=\"\(esc(src ?? ""))\" alt=\"\(esc(alt))\"\(title.map { " title=\"\(esc($0))\"" } ?? "")>"
        case .softBreak: return "\n"
        case .lineBreak: return "<br>\n"
        case .html(let raw): return raw
        case .footnoteReference(let label): return "<sup class=\"fn\"><a href=\"#fn-\(esc(label))\">\(esc(label))</a></sup>"
        }
    }

    func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
