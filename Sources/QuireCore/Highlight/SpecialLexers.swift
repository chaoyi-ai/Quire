import Foundation

// 共用小工具
@inline(__always) private func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D }
@inline(__always) private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(__always) private func isAlpha(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80 }
@inline(__always) private func isNameChar(_ c: UInt8) -> Bool { isAlpha(c) || isDigit(c) || c == 0x2D || c == 0x2E || c == 0x3A }

/// 扫描双/单引号字符串（支持反斜杠转义），返回结束偏移（含引号）
private func scanQuoted(_ b: [UInt8], _ i: Int, quote: UInt8, stopAtNewline: Bool = true) -> Int {
    var j = i + 1
    while j < b.count {
        if b[j] == 0x5C { j += 2; continue }
        if b[j] == quote { return j + 1 }
        if stopAtNewline, b[j] == 0x0A { return j }
        j += 1
    }
    return b.count
}
private func lineEnd(_ b: [UInt8], _ i: Int) -> Int { var j = i; while j < b.count, b[j] != 0x0A { j += 1 }; return j }
private func scanNumber(_ b: [UInt8], _ i: Int) -> Int {
    var j = i
    if j < b.count, b[j] == 0x2D || b[j] == 0x2B { j += 1 }
    while j < b.count, isDigit(b[j]) || b[j] == 0x2E || b[j] == 0x65 || b[j] == 0x45 || b[j] == 0x5F || b[j] == 0x78 || (b[j] >= 0x61 && b[j] <= 0x66) || (b[j] >= 0x41 && b[j] <= 0x46) { j += 1 }
    return j
}

// MARK: - JSON

public struct JSONLexer: Lexer {
    public init() {}
    public func tokenize(_ b: [UInt8]) -> [ByteToken] {
        var out: [ByteToken] = []
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c == 0x22 {
                let e = scanQuoted(b, i, quote: 0x22)
                // 键：后面（跳过空白）是冒号
                var k = e; while k < n, isSpace(b[k]) { k += 1 }
                out.append(ByteToken(i, e, k < n && b[k] == 0x3A ? .attribute : .string))
                i = e; continue
            }
            if c == 0x2F, i + 1 < n, b[i + 1] == 0x2F { let e = lineEnd(b, i); out.append(ByteToken(i, e, .comment)); i = e; continue }
            if c == 0x2F, i + 1 < n, b[i + 1] == 0x2A {
                var j = i + 2; while j + 1 < n, !(b[j] == 0x2A && b[j + 1] == 0x2F) { j += 1 }
                let e = min(j + 2, n); out.append(ByteToken(i, e, .comment)); i = e; continue
            }
            if isDigit(c) || c == 0x2D { let e = scanNumber(b, i); out.append(ByteToken(i, e, .number)); i = max(e, i + 1); continue }
            if isAlpha(c) {
                var j = i; while j < n, isAlpha(b[j]) { j += 1 }
                let w = String(decoding: b[i..<j], as: UTF8.self)
                out.append(ByteToken(i, j, (w == "true" || w == "false" || w == "null") ? .constant : .invalid))
                i = j; continue
            }
            if c == 0x7B || c == 0x7D || c == 0x5B || c == 0x5D || c == 0x2C || c == 0x3A { out.append(ByteToken(i, i + 1, .punctuation)) }
            i += 1
        }
        return out
    }
}

// MARK: - HTML / XML

public struct MarkupLexer: Lexer {
    public init() {}
    public func tokenize(_ b: [UInt8]) -> [ByteToken] {
        var out: [ByteToken] = []
        var i = 0
        let n = b.count
        func starts(_ s: String, _ p: Int) -> Bool {
            let u = Array(s.utf8); guard p + u.count <= n else { return false }
            for k in 0..<u.count where b[p + k] != u[k] { return false }; return true
        }
        while i < n {
            guard b[i] == 0x3C else { i += 1; continue } // <
            if starts("<!--", i) {
                var j = i + 4; while j + 2 < n, !(b[j] == 0x2D && b[j + 1] == 0x2D && b[j + 2] == 0x3E) { j += 1 }
                let e = min(j + 3, n); out.append(ByteToken(i, e, .comment)); i = e; continue
            }
            if starts("<![CDATA[", i) {
                var j = i + 9; while j + 2 < n, !(b[j] == 0x5D && b[j + 1] == 0x5D && b[j + 2] == 0x3E) { j += 1 }
                let e = min(j + 3, n); out.append(ByteToken(i, e, .string)); i = e; continue
            }
            if starts("<!", i) || starts("<?", i) {
                var j = i; while j < n, b[j] != 0x3E { j += 1 }
                let e = min(j + 1, n); out.append(ByteToken(i, e, .meta)); i = e; continue
            }
            // 标签
            var j = i + 1
            if j < n, b[j] == 0x2F { j += 1 }
            let nameStart = j
            while j < n, isNameChar(b[j]) { j += 1 }
            guard j > nameStart else { i += 1; continue }
            out.append(ByteToken(i, i + 1, .punctuation))
            out.append(ByteToken(nameStart, j, .tag))
            let tagName = String(decoding: b[nameStart..<j], as: UTF8.self).lowercased()
            // 属性
            while j < n, b[j] != 0x3E {
                if b[j] == 0x2F, j + 1 < n, b[j + 1] == 0x3E { j += 1; break }
                if isSpace(b[j]) || b[j] == 0x0A { j += 1; continue }
                if b[j] == 0x22 || b[j] == 0x27 { let e = scanQuoted(b, j, quote: b[j], stopAtNewline: false); out.append(ByteToken(j, e, .string)); j = e; continue }
                if b[j] == 0x3D { out.append(ByteToken(j, j + 1, .operator)); j += 1; continue }
                if b[j] == 0x7B { // JSX {expr}
                    var d = 0; var k = j
                    while k < n { if b[k] == 0x7B { d += 1 } else if b[k] == 0x7D { d -= 1; if d == 0 { k += 1; break } }; k += 1 }
                    out.append(ByteToken(j, k, .variable)); j = k; continue
                }
                let s = j; while j < n, !isSpace(b[j]), b[j] != 0x3D, b[j] != 0x3E, b[j] != 0x0A, !(b[j] == 0x2F && j + 1 < n && b[j + 1] == 0x3E) { j += 1 }
                if j > s { out.append(ByteToken(s, j, .attribute)) } else { j += 1 }
            }
            if j < n { out.append(ByteToken(j, j + 1, .punctuation)); j += 1 }
            i = j
            // <script>/<style> 内容交给对应词法器
            if tagName == "script" || tagName == "style" {
                let closeTag = tagName == "script" ? "</script" : "</style"
                var k = i
                while k < n, !starts(closeTag, k) { k += 1 }
                let inner = Array(b[i..<k])
                let lexer: any Lexer = tagName == "script" ? GenericLexer(spec: .javascript) : CSSLexer()
                for t in lexer.tokenize(inner) { out.append(ByteToken(t.start + i, t.end + i, t.kind)) }
                i = k
            }
        }
        return out
    }
}

// MARK: - CSS

public struct CSSLexer: Lexer {
    public init() {}
    @inline(__always) private func isSel(_ c: UInt8) -> Bool { isAlpha(c) || isDigit(c) || c == 0x2D }
    public func tokenize(_ b: [UInt8]) -> [ByteToken] {
        var out: [ByteToken] = []
        var i = 0
        let n = b.count
        var depth = 0          // { } 深度：0 = 选择器区，>0 = 声明区
        while i < n {
            let c = b[i]
            if c == 0x2F, i + 1 < n, b[i + 1] == 0x2A {
                var j = i + 2; while j + 1 < n, !(b[j] == 0x2A && b[j + 1] == 0x2F) { j += 1 }
                let e = min(j + 2, n); out.append(ByteToken(i, e, .comment)); i = e; continue
            }
            if c == 0x2F, i + 1 < n, b[i + 1] == 0x2F { let e = lineEnd(b, i); out.append(ByteToken(i, e, .comment)); i = e; continue } // scss
            if c == 0x22 || c == 0x27 { let e = scanQuoted(b, i, quote: c); out.append(ByteToken(i, e, .string)); i = e; continue }
            if c == 0x7B { depth += 1; out.append(ByteToken(i, i + 1, .punctuation)); i += 1; continue }
            if c == 0x7D { depth = max(0, depth - 1); out.append(ByteToken(i, i + 1, .punctuation)); i += 1; continue }
            if c == 0x40 { // @media
                var j = i + 1; while j < n, isNameChar(b[j]) { j += 1 }
                out.append(ByteToken(i, j, .keyword)); i = j; continue
            }
            if depth == 0 {
                // 选择器
                if c == 0x2E || c == 0x23 { var j = i + 1; while j < n, isSel(b[j]) { j += 1 }; out.append(ByteToken(i, j, c == 0x2E ? .type : .constant)); i = j; continue }
                if c == 0x3A { var j = i + 1; while j < n, isSel(b[j]) || b[j] == 0x3A { j += 1 }; if j < n, b[j] == 0x28 { while j < n, b[j] != 0x29 { j += 1 }; j = min(j + 1, n) }; out.append(ByteToken(i, j, .attribute)); i = j; continue }
                if isAlpha(c) { var j = i; while j < n, isSel(b[j]) { j += 1 }; out.append(ByteToken(i, j, .tag)); i = j; continue }
                if c == 0x5B { var j = i; while j < n, b[j] != 0x5D { j += 1 }; out.append(ByteToken(i, min(j + 1, n), .attribute)); i = min(j + 1, n); continue }
                i += 1; continue
            }
            // 声明区
            if c == 0x24 || (c == 0x2D && i + 1 < n && b[i + 1] == 0x2D) { var j = i + 1; while j < n, isSel(b[j]) { j += 1 }; out.append(ByteToken(i, j, .variable)); i = j; continue }
            if isAlpha(c) || c == 0x2D {
                var j = i; while j < n, isSel(b[j]) { j += 1 }
                var k = j; while k < n, isSpace(b[k]) { k += 1 }
                if k < n, b[k] == 0x3A { out.append(ByteToken(i, j, .attribute)) }          // property
                else if k < n, b[k] == 0x28 { out.append(ByteToken(i, j, .function)) }      // rgb(
                else { out.append(ByteToken(i, j, .keyword)) }                                // value keyword
                i = j; continue
            }
            if c == 0x23 { var j = i + 1; while j < n, isSel(b[j]) { j += 1 }; out.append(ByteToken(i, j, .number)); i = j; continue } // color
            if isDigit(c) || (c == 0x2E && i + 1 < n && isDigit(b[i + 1])) {
                var j = scanNumber(b, i); while j < n, isAlpha(b[j]) || b[j] == 0x25 { j += 1 } // 单位
                out.append(ByteToken(i, j, .number)); i = j; continue
            }
            if c == 0x21 { var j = i + 1; while j < n, isAlpha(b[j]) { j += 1 }; out.append(ByteToken(i, j, .keyword)); i = j; continue } // !important
            if c == 0x3A || c == 0x3B || c == 0x2C { out.append(ByteToken(i, i + 1, .punctuation)) }
            i += 1
        }
        return out
    }
}

// MARK: - YAML

public struct YAMLLexer: Lexer {
    public init() {}
    public func tokenize(_ b: [UInt8]) -> [ByteToken] {
        var out: [ByteToken] = []
        var i = 0
        let n = b.count
        while i < n {
            // 逐行处理
            let ls = i
            let le = lineEnd(b, i)
            var j = ls
            while j < le, isSpace(b[j]) { j += 1 }
            if j < le, b[j] == 0x2D, j + 1 < le, isSpace(b[j + 1]) { out.append(ByteToken(j, j + 1, .punctuation)); j += 2; while j < le, isSpace(b[j]) { j += 1 } }
            if j < le, b[j] == 0x2D, j + 2 < le, b[j + 1] == 0x2D, b[j + 2] == 0x2D { out.append(ByteToken(j, le, .meta)); i = le + 1; continue }
            if j < le, b[j] == 0x23 { out.append(ByteToken(j, le, .comment)); i = le + 1; continue }
            // key:
            var k = j
            if k < le, b[k] == 0x22 || b[k] == 0x27 { k = scanQuoted(b, k, quote: b[k]) }
            else { while k < le, b[k] != 0x3A, b[k] != 0x23 { k += 1 } }
            if k < le, b[k] == 0x3A, (k + 1 >= le || isSpace(b[k + 1])) {
                out.append(ByteToken(j, k, .attribute)); out.append(ByteToken(k, k + 1, .punctuation))
                j = k + 1
            }
            // value
            while j < le, isSpace(b[j]) { j += 1 }
            if j < le {
                let c = b[j]
                if c == 0x23 { out.append(ByteToken(j, le, .comment)) }
                else if c == 0x22 || c == 0x27 { let e = scanQuoted(b, j, quote: c); out.append(ByteToken(j, e, .string)); if e < le { let h = b[e...].firstIndex(of: 0x23) ?? le; if h < le { out.append(ByteToken(h, le, .comment)) } } }
                else if c == 0x26 || c == 0x2A || c == 0x21 { var e = j + 1; while e < le, !isSpace(b[e]) { e += 1 }; out.append(ByteToken(j, e, .meta)) } // &anchor *alias !!tag
                else if c == 0x7C || c == 0x3E { out.append(ByteToken(j, le, .operator)) } // | >
                else if c == 0x5B || c == 0x7B { out.append(ByteToken(j, le, .string)) } // flow
                else {
                    var e = j; while e < le, b[e] != 0x23 { e += 1 }
                    var ve = e; while ve > j, isSpace(b[ve - 1]) { ve -= 1 }
                    let v = String(decoding: b[j..<ve], as: UTF8.self)
                    let kind: TokenKind
                    if ["true", "false", "null", "~", "yes", "no", "on", "off", "True", "False", "Null", "TRUE", "FALSE", "NULL"].contains(v) { kind = .constant }
                    else if let f = v.first, isDigit(f.asciiValue ?? 0) || f == "-" || f == "+" || f == ".", Double(v.replacingOccurrences(of: "_", with: "")) != nil { kind = .number }
                    else { kind = .string }
                    if ve > j { out.append(ByteToken(j, ve, kind)) }
                    if e < le { out.append(ByteToken(e, le, .comment)) }
                }
            }
            i = le + 1
        }
        return out
    }
}

// MARK: - TOML / INI

public struct TOMLLexer: Lexer {
    public init() {}
    public func tokenize(_ b: [UInt8]) -> [ByteToken] {
        var out: [ByteToken] = []
        var i = 0
        let n = b.count
        while i < n {
            let ls = i, le = lineEnd(b, i)
            var j = ls; while j < le, isSpace(b[j]) { j += 1 }
            if j < le, b[j] == 0x23 || b[j] == 0x3B { out.append(ByteToken(j, le, .comment)); i = le + 1; continue }
            if j < le, b[j] == 0x5B { out.append(ByteToken(j, le, .tag)); i = le + 1; continue } // [table]
            // key = value
            var k = j
            if k < le, b[k] == 0x22 || b[k] == 0x27 { k = scanQuoted(b, k, quote: b[k]) } else { while k < le, b[k] != 0x3D { k += 1 } }
            if k < le, b[k] == 0x3D {
                var ke = k; while ke > j, isSpace(b[ke - 1]) { ke -= 1 }
                out.append(ByteToken(j, ke, .attribute)); out.append(ByteToken(k, k + 1, .operator))
                j = k + 1
            }
            // value(s)
            while j < le {
                while j < le, isSpace(b[j]) { j += 1 }
                guard j < le else { break }
                let c = b[j]
                if c == 0x23 { out.append(ByteToken(j, le, .comment)); break }
                if c == 0x22 || c == 0x27 {
                    if j + 2 < n, b[j + 1] == c, b[j + 2] == c { // 多行 """
                        var e = j + 3; while e + 2 < n, !(b[e] == c && b[e + 1] == c && b[e + 2] == c) { e += 1 }
                        let end = min(e + 3, n); out.append(ByteToken(j, end, .string)); i = end; j = end
                        // 继续下一轮外层：从当前位置找行尾
                        if end >= le { break }
                        continue
                    }
                    let e = scanQuoted(b, j, quote: c); out.append(ByteToken(j, e, .string)); j = e; continue
                }
                if isDigit(c) || c == 0x2D || c == 0x2B { var e = j + 1; while e < le, isDigit(b[e]) || b[e] == 0x2E || b[e] == 0x5F || b[e] == 0x3A || b[e] == 0x2D || b[e] == 0x54 || b[e] == 0x5A || b[e] == 0x78 || b[e] == 0x65 { e += 1 }; out.append(ByteToken(j, e, .number)); j = e; continue }
                if isAlpha(c) { var e = j; while e < le, isAlpha(b[e]) { e += 1 }; let w = String(decoding: b[j..<e], as: UTF8.self); out.append(ByteToken(j, e, ["true", "false", "inf", "nan"].contains(w) ? .constant : .string)); j = e; continue }
                if c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2C { out.append(ByteToken(j, j + 1, .punctuation)) }
                j += 1
            }
            i = max(le + 1, i + 1)
        }
        return out
    }
}

// MARK: - Markdown（代码块内展示 Markdown 源码）

public struct MarkdownCodeLexer: Lexer {
    public init() {}
    public func tokenize(_ b: [UInt8]) -> [ByteToken] {
        var out: [ByteToken] = []
        var i = 0
        let n = b.count
        var inFence = false
        while i < n {
            let ls = i, le = lineEnd(b, i)
            var j = ls; while j < le, isSpace(b[j]) { j += 1 }
            if j + 2 < le || j + 2 == le, j + 2 <= n, b[j] == 0x60, j + 1 < n, b[j + 1] == 0x60, j + 2 < n, b[j + 2] == 0x60 {
                inFence.toggle(); out.append(ByteToken(j, le, .meta)); i = le + 1; continue
            }
            if inFence { out.append(ByteToken(ls, le, .string)); i = le + 1; continue }
            if j < le, b[j] == 0x23 { out.append(ByteToken(j, le, .tag)); i = le + 1; continue }
            if j < le, b[j] == 0x3E { out.append(ByteToken(j, j + 1, .punctuation)); }
            if j < le, (b[j] == 0x2D || b[j] == 0x2A || b[j] == 0x2B), j + 1 < le, isSpace(b[j + 1]) { out.append(ByteToken(j, j + 1, .keyword)) }
            if j < le, isDigit(b[j]) { var e = j; while e < le, isDigit(b[e]) { e += 1 }; if e < le, b[e] == 0x2E || b[e] == 0x29 { out.append(ByteToken(j, e + 1, .keyword)) } }
            // 行内：`code` **bold** *em* [text](url)
            var k = j
            while k < le {
                let c = b[k]
                if c == 0x60 { var e = k + 1; while e < le, b[e] != 0x60 { e += 1 }; out.append(ByteToken(k, min(e + 1, le), .string)); k = e + 1; continue }
                if c == 0x2A || c == 0x5F { out.append(ByteToken(k, k + 1, .keyword)); k += 1; continue }
                if c == 0x5B { var e = k; while e < le, b[e] != 0x5D { e += 1 }
                    if e + 1 < le, b[e + 1] == 0x28 { var u = e + 1; while u < le, b[u] != 0x29 { u += 1 }; out.append(ByteToken(k, e + 1, .attribute)); out.append(ByteToken(e + 1, min(u + 1, le), .string)); k = u + 1; continue }
                }
                if c == 0x3C { var e = k; while e < le, b[e] != 0x3E { e += 1 }; out.append(ByteToken(k, min(e + 1, le), .tag)); k = e + 1; continue }
                k += 1
            }
            i = le + 1
        }
        return out
    }
}

// MARK: - Diff

public struct DiffLexer: Lexer {
    public init() {}
    public func tokenize(_ b: [UInt8]) -> [ByteToken] {
        var out: [ByteToken] = []
        var i = 0
        let n = b.count
        while i < n {
            let le = lineEnd(b, i)
            if i < le {
                let c = b[i]
                if c == 0x2B, !(i + 2 < le && b[i + 1] == 0x2B && b[i + 2] == 0x2B) { out.append(ByteToken(i, le, .string)) }         // + 新增（绿）
                else if c == 0x2D, !(i + 2 < le && b[i + 1] == 0x2D && b[i + 2] == 0x2D) { out.append(ByteToken(i, le, .invalid)) }  // - 删除（红）
                else if c == 0x40 { out.append(ByteToken(i, le, .number)) }                                                            // @@ hunk
                else if c == 0x2B || c == 0x2D || (c == 0x64 && i + 3 < le && b[i + 1] == 0x69 && b[i + 2] == 0x66 && b[i + 3] == 0x66) || (c == 0x69 && i + 4 < le && b[i + 1] == 0x6E && b[i + 2] == 0x64) { out.append(ByteToken(i, le, .meta)) } // +++ --- diff index
            }
            i = le + 1
        }
        return out
    }
}
