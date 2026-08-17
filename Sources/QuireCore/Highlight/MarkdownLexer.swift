import Foundation

/// 源码编辑器用的 Markdown 词法（不是解析器）：按行识别标记与行内样式，输出 UTF-16 偏移的 token。
/// 设计目标：快（> 50 MB/s）、可从任意行带状态续扫（围栏代码块状态）。
public struct MarkdownLexer: Sendable {
    public enum Kind: UInt8, Sendable, CaseIterable {
        case marker         // # - * > 1. ``` | --- 等结构标记
        case heading        // 标题文字
        case codeSpan       // `code`
        case codeBlock      // 围栏内内容
        case fenceInfo      // ```swift 的语言
        case emphasis       // *x* _x_
        case strong         // **x**
        case strike         // ~~x~~
        case linkText       // [text]
        case linkURL        // (url) / <url> / 裸链接
        case image          // ![alt]
        case html           // <tag> / 注释
        case quote          // > 后的引用正文（弱化）
        case frontMatter    // --- 块
        case escape         // \*
        case footnote       // [^1]
        case tableDelim     // | 与 --- 分隔行
    }

    public struct Token: Hashable, Sendable {
        public var range: Range<Int>   // UTF-16
        public var kind: Kind
        public init(range: Range<Int>, kind: Kind) { self.range = range; self.kind = kind }
    }

    /// 行间状态：是否在围栏代码块里（以及围栏字符/长度，用于匹配闭合）；是否在 front matter
    public struct State: Hashable, Sendable {
        public var fenceChar: UInt8 = 0     // 0 = 不在围栏；否则 '`' 或 '~'
        public var fenceLen: Int = 0
        public var inFrontMatter = false
        public var lineNumber = 0
        public init() {}
        public static let initial = State()
        public var inFence: Bool { fenceChar != 0 }
    }

    public init() {}

    /// 对整段文本（可以是整个文档或若干完整行）扫描。`state` 传入起始状态，返回结束状态。
    /// `base` 为文本在文档中的 UTF-16 起点，token 偏移会加上它。
    public func tokenize(_ text: String, base: Int = 0, state: inout State) -> [Token] {
        var out: [Token] = []
        let utf16 = Array(text.utf16)
        let n = utf16.count
        var i = 0
        while i < n {
            var e = i
            while e < n, utf16[e] != 0x0A { e += 1 }
            tokenizeLine(utf16, i, e, base: base, state: &state, into: &out)
            state.lineNumber += 1
            i = e + 1
        }
        return out
    }

    // MARK: - 行

    private func tokenizeLine(_ u: [UInt16], _ s: Int, _ e: Int, base: Int, state: inout State, into out: inout [Token]) {
        @inline(__always) func c(_ k: Int) -> UInt16 { k < e ? u[k] : 0 }
        var i = s
        while i < e, u[i] == 0x20 || u[i] == 0x09 { i += 1 }
        let indent = i - s
        let lineEmpty = i >= e

        // front matter：仅文档第一行为 --- 时进入
        if state.lineNumber == 0, isRule(u, i, e, char: 0x2D), indent == 0 {
            state.inFrontMatter = true
            out.append(Token(range: base + s..<base + e, kind: .marker)); return
        }
        if state.inFrontMatter {
            if isRule(u, i, e, char: 0x2D) || (c(i) == 0x2E && c(i + 1) == 0x2E && c(i + 2) == 0x2E) {
                state.inFrontMatter = false
                out.append(Token(range: base + s..<base + e, kind: .marker))
            } else {
                out.append(Token(range: base + s..<base + e, kind: .frontMatter))
            }
            return
        }

        // 围栏代码块
        if state.inFence {
            if indent < 4, let (ch, len) = fence(u, i, e), ch == state.fenceChar, len >= state.fenceLen, onlyFence(u, i, e) {
                state.fenceChar = 0; state.fenceLen = 0
                out.append(Token(range: base + s..<base + e, kind: .marker))
            } else if !lineEmpty {
                out.append(Token(range: base + s..<base + e, kind: .codeBlock))
            }
            return
        }
        if indent < 4, let (ch, len) = fence(u, i, e) {
            state.fenceChar = ch; state.fenceLen = len
            out.append(Token(range: base + i..<base + i + len, kind: .marker))
            var k = i + len
            while k < e, u[k] == 0x20 { k += 1 }
            if k < e { out.append(Token(range: base + k..<base + e, kind: .fenceInfo)) }
            return
        }
        if lineEmpty { return }

        // 缩进代码块（4 空格 / tab，且非列表延续 —— 词法层不追踪列表，简单按缩进）
        if indent >= 4 || (u[s] == 0x09) {
            out.append(Token(range: base + s..<base + e, kind: .codeBlock)); return
        }

        // 引用 > 可叠加
        var contentStart = i
        var quoteDepth = 0
        while contentStart < e, u[contentStart] == 0x3E {
            quoteDepth += 1
            out.append(Token(range: base + contentStart..<base + contentStart + 1, kind: .marker))
            contentStart += 1
            while contentStart < e, u[contentStart] == 0x20 { contentStart += 1 }
        }
        i = contentStart

        // 标题
        if c(i) == 0x23 {
            var k = i; while k < e, u[k] == 0x23, k - i < 6 { k += 1 }
            if k >= e || u[k] == 0x20 || u[k] == 0x09 {
                out.append(Token(range: base + i..<base + k, kind: .marker))
                var t = k; while t < e, u[t] == 0x20 { t += 1 }
                // 去掉结尾 #
                var tEnd = e
                while tEnd > t, u[tEnd - 1] == 0x20 { tEnd -= 1 }
                var hEnd = tEnd
                while hEnd > t, u[hEnd - 1] == 0x23 { hEnd -= 1 }
                if hEnd < tEnd, hEnd > t, u[hEnd - 1] == 0x20 { out.append(Token(range: base + hEnd..<base + tEnd, kind: .marker)); tEnd = hEnd }
                if t < tEnd { out.append(Token(range: base + t..<base + tEnd, kind: .heading)) }
                inlines(u, t, tEnd, base: base, into: &out)
                return
            }
        }
        // 分割线 / 表格分隔行
        if isRule(u, i, e, char: 0x2D) || isRule(u, i, e, char: 0x2A) || isRule(u, i, e, char: 0x5F) {
            out.append(Token(range: base + i..<base + e, kind: .marker)); return
        }
        if isTableDelimiterRow(u, i, e) {
            out.append(Token(range: base + i..<base + e, kind: .tableDelim)); return
        }
        // 列表标记
        if (u[i] == 0x2D || u[i] == 0x2A || u[i] == 0x2B), (c(i + 1) == 0x20 || c(i + 1) == 0x09) {
            out.append(Token(range: base + i..<base + i + 1, kind: .marker))
            i += 2
            // 任务框
            while i < e, u[i] == 0x20 { i += 1 }
            if c(i) == 0x5B, (c(i + 1) == 0x20 || c(i + 1) == 0x78 || c(i + 1) == 0x58), c(i + 2) == 0x5D, (c(i + 3) == 0x20 || i + 3 >= e) {
                out.append(Token(range: base + i..<base + i + 3, kind: .marker)); i += 3
            }
        } else {
            var k = i; while k < e, u[k] >= 0x30, u[k] <= 0x39, k - i < 9 { k += 1 }
            if k > i, (c(k) == 0x2E || c(k) == 0x29), (c(k + 1) == 0x20 || k + 1 >= e) {
                out.append(Token(range: base + i..<base + k + 1, kind: .marker)); i = k + 1
            }
        }
        // 表格行的竖线
        var hasPipe = false
        for k in i..<e where u[k] == 0x7C { hasPipe = true; break }
        if hasPipe {
            for k in i..<e where u[k] == 0x7C && (k == 0 || u[k - 1] != 0x5C) { out.append(Token(range: base + k..<base + k + 1, kind: .tableDelim)) }
        }
        // 引用正文弱化标记（整行）
        if quoteDepth > 0, i < e { out.append(Token(range: base + i..<base + e, kind: .quote)) }
        inlines(u, i, e, base: base, into: &out)
    }

    // MARK: - 行内

    private func inlines(_ u: [UInt16], _ s: Int, _ e: Int, base: Int, into out: inout [Token]) {
        var i = s
        @inline(__always) func c(_ k: Int) -> UInt16 { k < e ? u[k] : 0 }
        while i < e {
            let ch = u[i]
            switch ch {
            case 0x5C: // \x
                if i + 1 < e { out.append(Token(range: base + i..<base + i + 2, kind: .escape)); i += 2; continue }
            case 0x60: // `code`
                var run = 1; while c(i + run) == 0x60 { run += 1 }
                var k = i + run
                while k < e {
                    if u[k] == 0x60 {
                        var r2 = 1; while c(k + r2) == 0x60 { r2 += 1 }
                        if r2 == run { out.append(Token(range: base + i..<base + k + r2, kind: .codeSpan)); i = k + r2; break }
                        k += r2
                    } else { k += 1 }
                }
                if k >= e { i += run }  // 未闭合
                continue
            case 0x2A, 0x5F: // * _
                let double = c(i + 1) == ch
                let len = double ? 2 : 1
                // 找闭合
                var k = i + len
                var found = -1
                while k < e {
                    if u[k] == ch, (!double || c(k + 1) == ch), k > i + len, u[k - 1] != 0x20 { found = k; break }
                    if u[k] == 0x60 { break }
                    k += 1
                }
                if found > 0, c(i + len) != 0x20 {
                    let end = found + len
                    out.append(Token(range: base + i..<base + i + len, kind: .marker))
                    out.append(Token(range: base + i + len..<base + found, kind: double ? .strong : .emphasis))
                    out.append(Token(range: base + found..<base + end, kind: .marker))
                    inlines(u, i + len, found, base: base, into: &out)   // 嵌套（如 ***x***）
                    i = end; continue
                }
            case 0x7E: // ~~x~~
                if c(i + 1) == 0x7E {
                    var k = i + 2; var found = -1
                    while k + 1 < e { if u[k] == 0x7E, u[k + 1] == 0x7E, k > i + 2 { found = k; break }; k += 1 }
                    if found > 0 {
                        out.append(Token(range: base + i..<base + i + 2, kind: .marker))
                        out.append(Token(range: base + i + 2..<base + found, kind: .strike))
                        out.append(Token(range: base + found..<base + found + 2, kind: .marker))
                        i = found + 2; continue
                    }
                }
            case 0x21, 0x5B: // ![alt](src)  [text](url)  [^1]  [text][ref]
                let isImage = ch == 0x21
                let b = isImage ? i + 1 : i
                if c(b) == 0x5B {
                    if !isImage, c(b + 1) == 0x5E { // 脚注
                        var k = b + 2; while k < e, u[k] != 0x5D { k += 1 }
                        if k < e { out.append(Token(range: base + i..<base + k + 1, kind: .footnote)); i = k + 1; continue }
                    }
                    var depth = 0; var k = b
                    var close = -1
                    while k < e {
                        if u[k] == 0x5B { depth += 1 } else if u[k] == 0x5D { depth -= 1; if depth == 0 { close = k; break } }
                        else if u[k] == 0x60 { break }
                        k += 1
                    }
                    if close > 0 {
                        out.append(Token(range: base + i..<base + close + 1, kind: isImage ? .image : .linkText))
                        if !isImage { inlines(u, b + 1, close, base: base, into: &out) }
                        var k2 = close + 1
                        if c(k2) == 0x28 { // (url)
                            var d = 1; var m = k2 + 1
                            while m < e { if u[m] == 0x28 { d += 1 } else if u[m] == 0x29 { d -= 1; if d == 0 { break } }; m += 1 }
                            if m < e { out.append(Token(range: base + k2..<base + m + 1, kind: .linkURL)); k2 = m + 1 }
                        } else if c(k2) == 0x5B { // [ref]
                            var m = k2 + 1; while m < e, u[m] != 0x5D { m += 1 }
                            if m < e { out.append(Token(range: base + k2..<base + m + 1, kind: .linkURL)); k2 = m + 1 }
                        }
                        i = k2; continue
                    }
                }
            case 0x3C: // <url> / <tag> / <!-- -->
                var k = i + 1
                if c(k) == 0x21, c(k + 1) == 0x2D, c(k + 2) == 0x2D {
                    while k + 2 < e, !(u[k] == 0x2D && u[k + 1] == 0x2D && u[k + 2] == 0x3E) { k += 1 }
                    let end = min(k + 3, e)
                    out.append(Token(range: base + i..<base + end, kind: .html)); i = end; continue
                }
                while k < e, u[k] != 0x3E, u[k] != 0x20 || isURLish(u, i + 1, k) { if u[k] == 0x3E { break }; k += 1 }
                if k < e, u[k] == 0x3E, k > i + 1 {
                    let isURL = isURLish(u, i + 1, k)
                    out.append(Token(range: base + i..<base + k + 1, kind: isURL ? .linkURL : .html)); i = k + 1; continue
                }
            case 0x68, 0x77: // http(s):// www.
                if (i == s || !isAlnum(u[i - 1])) {
                    if matches(u, i, e, "https://") || matches(u, i, e, "http://") || matches(u, i, e, "www.") {
                        var k = i; while k < e, u[k] != 0x20, u[k] != 0x3C, u[k] != 0x29, u[k] != 0x5D, u[k] < 0x80 { k += 1 }
                        while k > i, ".,;:!?'\"".utf16.contains(u[k - 1]) { k -= 1 }
                        if k - i > 8 { out.append(Token(range: base + i..<base + k, kind: .linkURL)); i = k; continue }
                    }
                }
            default: break
            }
            i += 1
        }
    }

    // MARK: - helpers

    private func fence(_ u: [UInt16], _ i: Int, _ e: Int) -> (UInt8, Int)? {
        guard i < e, u[i] == 0x60 || u[i] == 0x7E else { return nil }
        let ch = u[i]
        var k = i; while k < e, u[k] == ch { k += 1 }
        guard k - i >= 3 else { return nil }
        // 反引号围栏的 info 里不能再有反引号
        if ch == 0x60 { for m in k..<e where u[m] == 0x60 { return nil } }
        return (UInt8(ch), k - i)
    }
    private func onlyFence(_ u: [UInt16], _ i: Int, _ e: Int) -> Bool {
        var k = i; while k < e, u[k] == u[i] { k += 1 }
        while k < e { if u[k] != 0x20, u[k] != 0x09 { return false }; k += 1 }
        return true
    }
    private func isRule(_ u: [UInt16], _ i: Int, _ e: Int, char: UInt16) -> Bool {
        var count = 0
        for k in i..<e {
            if u[k] == char { count += 1 } else if u[k] != 0x20, u[k] != 0x09 { return false }
        }
        return count >= 3
    }
    private func isTableDelimiterRow(_ u: [UInt16], _ i: Int, _ e: Int) -> Bool {
        var hasDash = false, hasPipe = false
        for k in i..<e {
            switch u[k] {
            case 0x7C: hasPipe = true
            case 0x2D: hasDash = true
            case 0x3A, 0x20, 0x09: break
            default: return false
            }
        }
        return hasDash && hasPipe
    }
    private func isURLish(_ u: [UInt16], _ s: Int, _ e: Int) -> Bool {
        var k = s
        while k < e, u[k] != 0x3A { if u[k] == 0x20 { return false }; k += 1 }
        return k < e && k > s && k + 1 < e
    }
    private func isAlnum(_ c: UInt16) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    private func matches(_ u: [UInt16], _ i: Int, _ e: Int, _ s: String) -> Bool {
        let p = Array(s.utf16)
        guard i + p.count <= e else { return false }
        for k in 0..<p.count where u[i + k] != p[k] { return false }
        return true
    }
}
