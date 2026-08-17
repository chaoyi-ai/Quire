import Foundation

/// 与 AppKit 无关的颜色（sRGB，0…1）。`#RGB` / `#RRGGBB` / `#RRGGBBAA`。
public struct ThemeColor: Hashable, Sendable, Codable, CustomStringConvertible {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public init?(hex: String) {
        var s = Substring(hex)
        guard s.first == "#" else { return nil }
        s = s.dropFirst()
        func byte(_ sub: Substring) -> Double? { UInt8(sub, radix: 16).map { Double($0) / 255 } }
        switch s.count {
        case 3, 4:
            let chars = Array(s)
            func dup(_ c: Character) -> Double? { UInt8(String([c, c]), radix: 16).map { Double($0) / 255 } }
            guard let r = dup(chars[0]), let g = dup(chars[1]), let b = dup(chars[2]) else { return nil }
            let a = chars.count == 4 ? dup(chars[3]) : 1
            guard let a else { return nil }
            self.init(red: r, green: g, blue: b, alpha: a)
        case 6, 8:
            let i0 = s.startIndex
            func seg(_ n: Int) -> Substring { s[s.index(i0, offsetBy: n)..<s.index(i0, offsetBy: n + 2)] }
            guard let r = byte(seg(0)), let g = byte(seg(2)), let b = byte(seg(4)) else { return nil }
            let a = s.count == 8 ? byte(seg(6)) : 1
            guard let a else { return nil }
            self.init(red: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }

    public var hexString: String {
        func h(_ v: Double) -> String { String(format: "%02x", Int((v * 255).rounded())) }
        return alpha >= 1 ? "#\(h(red))\(h(green))\(h(blue))" : "#\(h(red))\(h(green))\(h(blue))\(h(alpha))"
    }
    public var description: String { hexString }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = ThemeColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "非法颜色 \(s)（需要 #RGB / #RRGGBB / #RRGGBBAA）"))
        }
        self = c
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(hexString)
    }

    public static let clear = ThemeColor(red: 0, green: 0, blue: 0, alpha: 0)
    public func withAlpha(_ a: Double) -> ThemeColor { var c = self; c.alpha = a; return c }
}

public enum Appearance: String, Codable, Sendable, Hashable { case light, dark }

/// 代码高亮 token 类型；与 THEMES.md `colors.syntax` 键一一对应。
public enum TokenKind: String, Codable, Sendable, CaseIterable, Hashable {
    case keyword, string, comment, number, type, function, variable, constant, `operator`,
         punctuation, attribute, tag, meta, regexp, escape, invalid
    case plain // 不着色
}

extension TokenKind: CodingKeyRepresentable {}

// MARK: - Theme（已解析、字段齐全）

public struct Theme: Hashable, Sendable, Codable, Identifiable {
    public struct Colors: Hashable, Sendable, Codable {
        public struct BlockQuote: Hashable, Sendable, Codable {
            public var foreground: ThemeColor, border: ThemeColor, background: ThemeColor
        }
        public struct Code: Hashable, Sendable, Codable {
            public var background: ThemeColor, foreground: ThemeColor
            public var inlineBackground: ThemeColor, inlineForeground: ThemeColor
            public var border: ThemeColor, lineNumber: ThemeColor
        }
        public struct Table: Hashable, Sendable, Codable {
            public var headerBackground: ThemeColor, stripe: ThemeColor, border: ThemeColor, hover: ThemeColor
        }
        public struct Editor: Hashable, Sendable, Codable {
            public var currentLine: ThemeColor, gutter: ThemeColor, markdownMarker: ThemeColor
            public var markdownHeading: ThemeColor, markdownLink: ThemeColor, markdownCode: ThemeColor
        }
        public var background: ThemeColor, foreground: ThemeColor, muted: ThemeColor, accent: ThemeColor
        public var heading: ThemeColor, border: ThemeColor, selection: ThemeColor
        public var blockquote: BlockQuote
        public var code: Code
        public var table: Table
        public var syntax: [TokenKind: ThemeColor]
        public var editor: Editor

        public func syntaxColor(_ kind: TokenKind) -> ThemeColor { syntax[kind] ?? code.foreground }
    }

    public struct Typography: Hashable, Sendable, Codable {
        public enum Weight: String, Codable, Sendable, Hashable { case regular, medium, semibold, bold, heavy }
        public var bodyFont: [String], codeFont: [String]
        public var baseSize: Double, lineHeight: Double, paragraphSpacing: Double
        public var headingScale: [Double], headingWeight: Weight, headingSpacingBefore: Double
        public var codeSize: Double
    }

    public struct Layout: Hashable, Sendable, Codable {
        public var maxContentWidth: Double, horizontalPadding: Double, verticalPadding: Double
        public var codeBlockRadius: Double, codeBlockPadding: Double, blockquoteBarWidth: Double
        public var tableCellPadding: [Double]
    }

    public struct Mermaid: Hashable, Sendable, Codable {
        public var theme: String
    }

    public var id: String
    public var name: String
    public var appearance: Appearance
    public var author: String?
    public var colors: Colors
    public var typography: Typography
    public var layout: Layout
    public var mermaid: Mermaid
    /// 来源：内置 / 用户文件路径
    public var sourcePath: String?
    /// 若由 `extends` 派生，记录父主题 id（用于禁止多层继承）
    public var extendsID: String?

    public var isDark: Bool { appearance == .dark }
}
