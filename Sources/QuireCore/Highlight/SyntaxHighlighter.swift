import Foundation

/// 高亮 token：`range` 为 **UTF-16 偏移**（直接对应 NSRange），便于渲染层零转换使用。
public struct Token: Hashable, Sendable {
    public var range: Range<Int>
    public var kind: TokenKind
    public init(range: Range<Int>, kind: TokenKind) { self.range = range; self.kind = kind }
}

/// 词法器：输入 UTF-8 字节，输出 **字节偏移** token。只覆盖需要着色的区间；未覆盖处视为 plain。
public protocol Lexer: Sendable {
    func tokenize(_ bytes: [UInt8]) -> [ByteToken]
}

public struct ByteToken: Hashable, Sendable {
    public var start: Int, end: Int
    public var kind: TokenKind
    public init(_ start: Int, _ end: Int, _ kind: TokenKind) { self.start = start; self.end = end; self.kind = kind }
}

/// 高亮入口：语言名 → 词法器 → UTF-16 token。无状态，可并发调用。
public struct SyntaxHighlighter: Sendable {
    public var registry: LanguageRegistry
    public init(registry: LanguageRegistry = .standard) { self.registry = registry }

    /// 是否支持该语言（nil / 未知语言返回 false，渲染层可跳过高亮）
    public func supports(_ language: String?) -> Bool {
        guard let language else { return false }
        return registry.lexer(for: language) != nil
    }

    public func highlight(_ code: String, language: String?) -> [Token] {
        guard let language, let lexer = registry.lexer(for: language) else { return [] }
        let bytes = Array(code.utf8)
        let byteTokens = lexer.tokenize(bytes)
        if byteTokens.isEmpty { return [] }

        // ASCII 快速路径：字节偏移 == UTF-16 偏移
        if !bytes.contains(where: { $0 >= 0x80 }) {
            return byteTokens.map { Token(range: $0.start..<$0.end, kind: $0.kind) }
        }
        // 非 ASCII：建 UTF-8 → UTF-16 偏移表
        var map = [Int](repeating: 0, count: bytes.count + 1)
        var u16 = 0
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            let len: Int = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
            let units = len == 4 ? 2 : 1
            for k in 0..<len where i + k < bytes.count { map[i + k] = u16 }
            u16 += units
            i += len
        }
        map[bytes.count] = u16
        return byteTokens.map { Token(range: map[$0.start]..<map[min($0.end, bytes.count)], kind: $0.kind) }
    }
}

/// 语言注册表：名称/别名 → 词法器。
public struct LanguageRegistry: Sendable {
    private var lexers: [String: any Lexer] = [:]
    private var aliases: [String: String] = [:]

    public init() {}

    public mutating func register(_ lexer: any Lexer, name: String, aliases: [String] = []) {
        lexers[name] = lexer
        for a in aliases { self.aliases[a] = name }
    }

    public func canonicalName(_ language: String) -> String? {
        let key = language.lowercased().trimmingCharacters(in: .whitespaces)
        // ```swift title="x" 之类：取第一个词
        let first = key.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == ":" }).first.map(String.init) ?? key
        if lexers[first] != nil { return first }
        return aliases[first]
    }

    public func lexer(for language: String) -> (any Lexer)? {
        canonicalName(language).flatMap { lexers[$0] }
    }

    public var languageNames: [String] { lexers.keys.sorted() }

    /// 内置全部语言
    public static let standard: LanguageRegistry = {
        var r = LanguageRegistry()
        for spec in LanguageSpec.all {
            r.register(GenericLexer(spec: spec), name: spec.name, aliases: spec.aliases)
        }
        r.register(JSONLexer(), name: "json", aliases: ["jsonc", "json5"])
        r.register(MarkupLexer(), name: "html", aliases: ["xml", "svg", "xhtml", "vue", "jsx-markup", "plist"])
        r.register(CSSLexer(), name: "css", aliases: ["scss", "less"])
        r.register(YAMLLexer(), name: "yaml", aliases: ["yml"])
        r.register(TOMLLexer(), name: "toml", aliases: ["ini", "cfg", "conf"])
        r.register(MarkdownCodeLexer(), name: "markdown", aliases: ["md", "mdx"])
        r.register(DiffLexer(), name: "diff", aliases: ["patch"])
        r.register(PlainLexer(), name: "plain", aliases: ["text", "txt", "plaintext", "none"])
        return r
    }()
}

/// 不着色。
public struct PlainLexer: Lexer {
    public init() {}
    public func tokenize(_ bytes: [UInt8]) -> [ByteToken] { [] }
}
