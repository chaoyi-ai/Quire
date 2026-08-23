import Foundation

/// HTML → Markdown（粘贴用）。用 Foundation 的 libxml2 HTML tidy 解析（`XMLDocument(.documentTidyHTML)`），
/// 不经 WebKit；覆盖常见标签：标题、段落、换行、粗斜、行内代码、代码块、链接、图片、列表（嵌套）、引用、表格、分割线、删除线。
/// 不认识的标签只保留其文本。
public enum HTMLToMarkdown {
    public static func convert(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: [.documentTidyHTML]) else { return html }
        var w = Writer()
        let body = doc.rootElement()?.elements(forName: "body").first ?? doc.rootElement()
        if let body { w.children(of: body) }
        return w.finish()
    }

    private struct Writer {
        var out = ""
        var listStack: [(ordered: Bool, index: Int)] = []
        var quoteDepth = 0
        var inPre = false

        mutating func finish() -> String {
            var s = out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? s : s + "\n"
        }

        mutating func children(of node: XMLNode) { for c in node.children ?? [] { visit(c) } }

        mutating func blockStart() {
            if !out.isEmpty, !out.hasSuffix("\n\n") { out += out.hasSuffix("\n") ? "\n" : "\n\n" }
            out += String(repeating: "> ", count: quoteDepth)
        }
        mutating func blockEnd() {
            while out.hasSuffix(" ") { out.removeLast() }   // tidy 会在块内文本末尾塞换行/空白
            if !out.hasSuffix("\n") { out += "\n" }
            out += "\n"
        }

        mutating func visit(_ node: XMLNode) {
            if node.kind == .text {
                let t = node.stringValue ?? ""
                out += inPre ? t : collapse(t)
                return
            }
            guard let el = node as? XMLElement, let name = el.name?.lowercased() else { return }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                blockStart(); out += String(repeating: "#", count: Int(name.dropFirst())!) + " "; children(of: el); blockEnd()
            case "p", "div", "section", "article":
                blockStart(); children(of: el); blockEnd()
            case "br": out += "  \n"
            case "hr": blockStart(); out += "---"; blockEnd()
            case "strong", "b": out += "**"; children(of: el); out += "**"
            case "em", "i": out += "*"; children(of: el); out += "*"
            case "del", "s", "strike": out += "~~"; children(of: el); out += "~~"
            case "code":
                if inPre { children(of: el) } else { out += "`"; children(of: el); out += "`" }
            case "pre":
                blockStart()
                let lang = (el.elements(forName: "code").first?.attribute(forName: "class")?.stringValue ?? "")
                    .split(separator: " ").first(where: { $0.hasPrefix("language-") || $0.hasPrefix("lang-") }).map { $0.replacingOccurrences(of: "language-", with: "").replacingOccurrences(of: "lang-", with: "") } ?? ""
                out += "```" + lang + "\n"
                inPre = true; children(of: el); inPre = false
                if !out.hasSuffix("\n") { out += "\n" }
                out += "```"; blockEnd()
            case "a":
                let href = el.attribute(forName: "href")?.stringValue ?? ""
                let start = out.count
                children(of: el)
                let text = String(out.dropFirst(start))
                if href.isEmpty || href.hasPrefix("javascript:") { return }
                out = String(out.prefix(start)) + "[\(text.isEmpty ? href : text)](\(href))"
            case "img":
                let src = el.attribute(forName: "src")?.stringValue ?? ""
                let alt = el.attribute(forName: "alt")?.stringValue ?? ""
                if !src.isEmpty { out += "![\(alt)](\(src))" }
            case "ul", "ol":
                listStack.append((name == "ol", Int(el.attribute(forName: "start")?.stringValue ?? "") ?? 1))
                if listStack.count == 1 { blockStart() } else if !out.hasSuffix("\n") { out += "\n" }
                children(of: el)
                listStack.removeLast()
                if listStack.isEmpty { blockEnd() }
            case "li":
                let depth = max(0, listStack.count - 1)
                if !out.hasSuffix("\n"), !out.isEmpty { out += "\n" }
                out += String(repeating: "> ", count: quoteDepth) + String(repeating: "  ", count: depth)
                if var top = listStack.last {
                    if top.ordered { out += "\(top.index). "; top.index += 1; listStack[listStack.count - 1] = top } else { out += "- " }
                } else { out += "- " }
                // 任务列表
                if let cb = el.elements(forName: "input").first, cb.attribute(forName: "type")?.stringValue == "checkbox" {
                    out += cb.attribute(forName: "checked") != nil ? "[x] " : "[ ] "
                }
                children(of: el)
            case "input": break
            case "blockquote":
                blockStart(); quoteDepth += 1
                let start = out.count
                children(of: el)
                // 引用内的块级开头已带 "> "，首行补上
                if String(out.dropFirst(start)).hasPrefix("\n") == false, !String(out.dropFirst(start)).hasPrefix("> ") {
                    out = String(out.prefix(start)) + "> " + String(out.dropFirst(start))
                }
                quoteDepth -= 1; blockEnd()
            case "table": table(el)
            case "thead", "tbody", "tfoot", "tr", "td", "th": children(of: el)
            case "span", "font", "u", "mark", "sup", "sub", "small", "body", "html", "header", "footer", "main", "nav", "figure", "figcaption", "center", "label":
                children(of: el)
            case "script", "style", "head", "meta", "link", "title", "noscript", "svg", "button", "select", "textarea", "form":
                break
            default:
                children(of: el)
            }
        }

        mutating func table(_ el: XMLElement) {
            var rows: [[String]] = []
            var headerCount = 0
            func cells(_ tr: XMLElement) -> [String] {
                tr.children?.compactMap { c -> String? in
                    guard let e = c as? XMLElement, let n = e.name?.lowercased(), n == "td" || n == "th" else { return nil }
                    var w = Writer(); w.children(of: e)
                    return w.out.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|").trimmingCharacters(in: .whitespaces)
                } ?? []
            }
            func walk(_ n: XMLNode, inHead: Bool) {
                for c in n.children ?? [] {
                    guard let e = c as? XMLElement, let name = e.name?.lowercased() else { continue }
                    if name == "tr" { let r = cells(e); rows.append(r); if inHead || e.elements(forName: "th").count == r.count, headerCount == 0, rows.count == 1 { headerCount = 1 } }
                    else { walk(e, inHead: inHead || name == "thead") }
                }
            }
            walk(el, inHead: false)
            guard let first = rows.first else { return }
            let cols = rows.map(\.count).max() ?? first.count
            blockStart()
            let header = headerCount == 1 ? rows.removeFirst() : Array(repeating: "", count: cols)
            func line(_ r: [String]) -> String { "| " + (0..<cols).map { $0 < r.count ? r[$0] : "" }.joined(separator: " | ") + " |" }
            out += line(header) + "\n" + "|" + String(repeating: " --- |", count: cols) + "\n"
            out += rows.map(line).joined(separator: "\n")
            blockEnd()
        }

        func collapse(_ t: String) -> String {
            // HTML 里的换行 / 连续空白折叠成一个空格；行首行尾处理交给上层
            var s = t.replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
            if out.hasSuffix("\n") || out.hasSuffix(" ") || out.hasSuffix("- ") || out.isEmpty { s = String(s.drop(while: { $0 == " " })) }
            return s
        }
    }
}
