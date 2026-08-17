import Foundation

/// 数据驱动的通用词法器：覆盖 C 系 / 脚本语言的关键字、类型、常量、注释、字符串、数字、标注、预处理。
public struct LanguageSpec: Sendable {
    public var name: String
    public var aliases: [String] = []
    public var keywords: Set<String> = []
    public var types: Set<String> = []
    public var constants: Set<String> = []          // true false nil null …
    public var builtins: Set<String> = []           // 内置函数 → function
    public var lineComments: [String] = ["//"]
    public var blockComments: [(open: String, close: String)] = [("/*", "*/")]
    public var nestedBlockComments = false          // Swift / Rust
    public var stringQuotes: Set<UInt8> = [0x22, 0x27]  // " '
    public var tripleQuotes = false                 // Python / Swift 多行
    public var backtickString: Bool = false         // JS 模板 / Go raw
    public var rawStringPrefixes: Set<String> = []  // r"…"  R"…"  b"…"
    public var identifierExtra: Set<UInt8> = []     // 允许出现在标识符里的额外字节：$ @
    public var variablePrefix: UInt8? = nil         // $ → variable（bash/php/perl）
    public var attributePrefix: UInt8? = nil        // @ → attribute（Swift/Java/Kotlin/Python 装饰器）
    public var preprocessorPrefix: UInt8? = nil     // 行首 # → meta（C/C++/ObjC）
    public var caseInsensitive = false              // SQL
    public var functionCallHeuristic = true         // ident( → function
    public var capitalizedTypeHeuristic = true      // Capitalized → type
    public var regexLiterals = false                // JS/TS 简单 /…/ 识别
    public var lifetimeQuote = false                // Rust 'a

    public init(name: String) { self.name = name }
}

public struct GenericLexer: Lexer {
    public let spec: LanguageSpec
    private let lineCommentBytes: [[UInt8]]
    private let blockCommentBytes: [(open: [UInt8], close: [UInt8])]

    public init(spec: LanguageSpec) {
        self.spec = spec
        self.lineCommentBytes = spec.lineComments.map { Array($0.utf8) }
        self.blockCommentBytes = spec.blockComments.map { (Array($0.open.utf8), Array($0.close.utf8)) }
    }

    public func tokenize(_ b: [UInt8]) -> [ByteToken] {
        var out: [ByteToken] = []
        out.reserveCapacity(b.count / 6)
        let n = b.count
        var i = 0
        var lineStart = true              // 用于预处理指令识别
        var lastSignificant: UInt8 = 0     // 上一个非空白字节（用于正则启发式）

        @inline(__always) func isIdentStart(_ c: UInt8) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80 || spec.identifierExtra.contains(c)
        }
        @inline(__always) func isIdent(_ c: UInt8) -> Bool { isIdentStart(c) || (c >= 0x30 && c <= 0x39) }
        @inline(__always) func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        @inline(__always) func hasPrefix(_ u: [UInt8], at p: Int) -> Bool {
            guard p + u.count <= n else { return false }
            for k in 0..<u.count where b[p + k] != u[k] { return false }
            return true
        }

        while i < n {
            let c = b[i]

            // 换行
            if c == 0x0A { lineStart = true; i += 1; continue }
            if c == 0x20 || c == 0x09 || c == 0x0D { i += 1; continue }

            // 预处理 / shebang
            if lineStart, let pp = spec.preprocessorPrefix, c == pp {
                var j = i
                while j < n, b[j] != 0x0A { if b[j] == 0x5C, j + 1 < n, b[j + 1] == 0x0A { j += 1 }; j += 1 }
                out.append(ByteToken(i, j, .meta)); i = j; continue
            }
            if lineStart, i == 0, c == 0x23, i + 1 < n, b[i + 1] == 0x21 { // #!
                var j = i; while j < n, b[j] != 0x0A { j += 1 }
                out.append(ByteToken(i, j, .meta)); i = j; continue
            }
            lineStart = false

            // 行注释
            var matched = false
            for lc in lineCommentBytes where hasPrefix(lc, at: i) {
                var j = i; while j < n, b[j] != 0x0A { j += 1 }
                out.append(ByteToken(i, j, .comment)); i = j; matched = true; break
            }
            if matched { continue }

            // 块注释
            for bc in blockCommentBytes where hasPrefix(bc.open, at: i) {
                var depth = 1
                var j = i + bc.open.count
                while j < n {
                    if spec.nestedBlockComments, hasPrefix(bc.open, at: j) { depth += 1; j += bc.open.count; continue }
                    if hasPrefix(bc.close, at: j) { depth -= 1; j += bc.close.count; if depth == 0 { break }; continue }
                    j += 1
                }
                out.append(ByteToken(i, j, .comment)); i = j; matched = true; break
            }
            if matched { continue }

            // 字符串
            if spec.stringQuotes.contains(c) || (spec.backtickString && c == 0x60) {
                // Rust 生命周期 'a：单引号后跟标识符且无闭合
                if spec.lifetimeQuote, c == 0x27, i + 1 < n, isIdentStart(b[i + 1]) {
                    var j = i + 1; while j < n, isIdent(b[j]) { j += 1 }
                    if j >= n || b[j] != 0x27 { out.append(ByteToken(i, j, .attribute)); i = j; lastSignificant = 0x27; continue }
                }
                let triple = spec.tripleQuotes && i + 2 < n && b[i + 1] == c && b[i + 2] == c
                let (end, escapes) = scanString(b, from: i, quote: c, triple: triple)
                out.append(ByteToken(i, end, .string))
                for e in escapes { out.append(ByteToken(e.0, e.1, .escape)) }
                i = end; lastSignificant = c; continue
            }

            // 原始字符串前缀 r"…"
            if !spec.rawStringPrefixes.isEmpty, isIdentStart(c) {
                var j = i; while j < n, isIdent(b[j]) { j += 1 }
                if j < n, spec.stringQuotes.contains(b[j]), let s = String(bytes: b[i..<j], encoding: .utf8), spec.rawStringPrefixes.contains(s) {
                    let q = b[j]
                    let triple = spec.tripleQuotes && j + 2 < n && b[j + 1] == q && b[j + 2] == q
                    let (end, _) = scanString(b, from: j, quote: q, triple: triple, raw: true)
                    out.append(ByteToken(i, end, .string)); i = end; lastSignificant = q; continue
                }
            }

            // 数字
            if isDigit(c) || (c == 0x2E && i + 1 < n && isDigit(b[i + 1]) && !isIdent(lastSignificant)) {
                var j = i + 1
                if c == 0x30, j < n, (b[j] | 0x20) == 0x78 || (b[j] | 0x20) == 0x62 || (b[j] | 0x20) == 0x6F { // 0x 0b 0o
                    j += 1
                    while j < n, isIdent(b[j]) { j += 1 }
                } else {
                    while j < n, isDigit(b[j]) || b[j] == 0x5F || b[j] == 0x2E || (b[j] | 0x20) == 0x65 || ((b[j] | 0x20) == 0x65) { j += 1 }
                    // 后缀 f, L, u, n
                    while j < n, isIdent(b[j]) { j += 1 }
                }
                out.append(ByteToken(i, j, .number)); i = j; lastSignificant = 0x30; continue
            }

            // 变量 $x
            if let vp = spec.variablePrefix, c == vp, i + 1 < n, (isIdentStart(b[i + 1]) || b[i + 1] == 0x7B || isDigit(b[i + 1])) {
                var j = i + 1
                if b[j] == 0x7B { while j < n, b[j] != 0x7D { j += 1 }; j = min(j + 1, n) }
                else { while j < n, isIdent(b[j]) { j += 1 } }
                out.append(ByteToken(i, j, .variable)); i = j; lastSignificant = 0x61; continue
            }

            // 标注 @x
            if let ap = spec.attributePrefix, c == ap, i + 1 < n, isIdentStart(b[i + 1]) {
                var j = i + 1; while j < n, isIdent(b[j]) || b[j] == 0x2E { j += 1 }
                out.append(ByteToken(i, j, .attribute)); i = j; lastSignificant = 0x61; continue
            }

            // 标识符 / 关键字
            if isIdentStart(c) {
                var j = i + 1; while j < n, isIdent(b[j]) { j += 1 }
                let word = String(decoding: b[i..<j], as: UTF8.self)
                let key = spec.caseInsensitive ? word.lowercased() : word
                let kind: TokenKind?
                if spec.keywords.contains(key) { kind = .keyword }
                else if spec.types.contains(key) { kind = .type }
                else if spec.constants.contains(key) { kind = .constant }
                else if spec.builtins.contains(key) { kind = .function }
                else {
                    // 前瞻：函数调用 / 类型启发式
                    var k = j; while k < n, b[k] == 0x20 { k += 1 }
                    if spec.functionCallHeuristic, k < n, b[k] == 0x28 { kind = .function }
                    else if spec.capitalizedTypeHeuristic, c >= 0x41, c <= 0x5A, j - i > 1, b[i + 1] >= 0x61, b[i + 1] <= 0x7A { kind = .type }
                    else if spec.capitalizedTypeHeuristic, isAllCapsConstant(b, i, j) { kind = .constant }
                    else { kind = nil }
                }
                if let kind { out.append(ByteToken(i, j, kind)) }
                i = j; lastSignificant = 0x61; continue
            }

            // 正则字面量（JS/TS 简化：/ 前面是运算符或行首）
            if spec.regexLiterals, c == 0x2F, i + 1 < n, b[i + 1] != 0x2F, b[i + 1] != 0x2A,
               lastSignificant == 0 || "=(,:[!&|?{};+-*%<>~".utf8.contains(lastSignificant) {
                var j = i + 1; var inClass = false; var ok = false
                while j < n, b[j] != 0x0A {
                    if b[j] == 0x5C { j += 2; continue }
                    if b[j] == 0x5B { inClass = true } else if b[j] == 0x5D { inClass = false }
                    else if b[j] == 0x2F, !inClass { ok = true; j += 1; break }
                    j += 1
                }
                if ok {
                    while j < n, isIdent(b[j]) { j += 1 } // flags
                    out.append(ByteToken(i, j, .regexp)); i = j; lastSignificant = 0x2F; continue
                }
            }

            // 运算符 / 标点
            if isOperator(c) {
                var j = i + 1; while j < n, isOperator(b[j]), j - i < 3 { j += 1 }
                out.append(ByteToken(i, j, .operator)); lastSignificant = c; i = j; continue
            }
            if isPunct(c) { out.append(ByteToken(i, i + 1, .punctuation)); lastSignificant = c; i += 1; continue }

            i += 1
        }
        return out
    }

    // MARK: helpers

    @inline(__always) private func isOperator(_ c: UInt8) -> Bool {
        switch c { case 0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x3D, 0x3C, 0x3E, 0x21, 0x26, 0x7C, 0x5E, 0x7E, 0x3F, 0x3A: true; default: false }
    }
    @inline(__always) private func isPunct(_ c: UInt8) -> Bool {
        switch c { case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x2C, 0x3B, 0x2E: true; default: false }
    }
    private func isAllCapsConstant(_ b: [UInt8], _ s: Int, _ e: Int) -> Bool {
        guard e - s >= 2 else { return false }
        var hasLetter = false
        for k in s..<e {
            let c = b[k]
            if c >= 0x41 && c <= 0x5A { hasLetter = true; continue }
            if c == 0x5F || (c >= 0x30 && c <= 0x39) { continue }
            return false
        }
        return hasLetter
    }

    /// 扫描字符串，返回结束偏移与转义序列位置
    private func scanString(_ b: [UInt8], from start: Int, quote: UInt8, triple: Bool, raw: Bool = false) -> (Int, [(Int, Int)]) {
        let n = b.count
        var escapes: [(Int, Int)] = []
        var j = start + (triple ? 3 : 1)
        while j < n {
            let c = b[j]
            if !raw, c == 0x5C, j + 1 < n {
                // \n \t \" \\ \u{…} \x..
                var e = j + 2
                if b[j + 1] == 0x75 || b[j + 1] == 0x78 { // \u \x
                    if e < n, b[e] == 0x7B { while e < n, b[e] != 0x7D { e += 1 }; e = min(e + 1, n) }
                    else { var k = 0; while e < n, k < 4, isHex(b[e]) { e += 1; k += 1 } }
                }
                escapes.append((j, e)); j = e; continue
            }
            if triple {
                if c == quote, j + 2 < n, b[j + 1] == quote, b[j + 2] == quote { return (j + 3, escapes) }
            } else {
                if c == quote { return (j + 1, escapes) }
                if c == 0x0A, quote != 0x60 { return (j, escapes) } // 单行字符串未闭合：到行尾
            }
            j += 1
        }
        return (n, escapes)
    }
    @inline(__always) private func isHex(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
}
