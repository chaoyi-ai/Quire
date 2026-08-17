import AppKit
import QuireCore

extension ThemeColor {
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// 主题 → 已解析的 AppKit 字体/颜色/段落样式。所有属性不可变，可跨线程共享。
/// 一次构造（< 1 ms），整份文档渲染期间复用；主题或缩放变化时重建。
public final class RenderStyle: @unchecked Sendable {
    public let theme: Theme
    /// 缩放倍率（⌘+/⌘-），作用于所有字号与间距
    public let scale: CGFloat

    // 字号
    public let baseSize: CGFloat
    public let codeSize: CGFloat
    public let lineHeight: CGFloat          // pt
    public let paragraphSpacing: CGFloat    // pt

    // 字体
    public let bodyFont: NSFont
    public let bodyBold: NSFont
    public let bodyItalic: NSFont
    public let bodyBoldItalic: NSFont
    public let codeFont: NSFont
    public let codeBold: NSFont
    public let inlineCodeFont: NSFont
    public let headingFonts: [NSFont]       // h1…h6

    // 颜色
    public let background: NSColor
    public let foreground: NSColor
    public let muted: NSColor
    public let accent: NSColor
    public let heading: NSColor
    public let border: NSColor
    public let selection: NSColor
    public let quoteForeground: NSColor, quoteBorder: NSColor, quoteBackground: NSColor
    public let codeBackground: NSColor, codeForeground: NSColor, inlineCodeBackground: NSColor, inlineCodeForeground: NSColor, codeBorder: NSColor, lineNumber: NSColor
    public let tableHeaderBackground: NSColor, tableStripe: NSColor, tableBorder: NSColor, tableHover: NSColor
    public let syntaxColors: [TokenKind: NSColor]

    // 版式
    public let maxContentWidth: CGFloat
    public let horizontalPadding: CGFloat
    public let verticalPadding: CGFloat
    public let codeBlockRadius: CGFloat
    public let codeBlockPadding: CGFloat
    public let blockquoteBarWidth: CGFloat
    public let tableCellPadding: (vertical: CGFloat, horizontal: CGFloat)

    public init(theme: Theme, scale: CGFloat = 1) {
        self.theme = theme
        self.scale = scale
        let t = theme.typography
        baseSize = CGFloat(t.baseSize) * scale
        codeSize = (CGFloat(t.baseSize) * CGFloat(t.codeSize) * scale).rounded()
        lineHeight = (baseSize * CGFloat(t.lineHeight)).rounded()
        paragraphSpacing = (baseSize * CGFloat(t.paragraphSpacing)).rounded()

        let body = Self.resolveFont(families: t.bodyFont, size: baseSize, mono: false)
        bodyFont = body
        bodyBold = Self.variant(body, traits: .boldFontMask)
        bodyItalic = Self.variant(body, traits: .italicFontMask)
        bodyBoldItalic = Self.variant(Self.variant(body, traits: .boldFontMask), traits: .italicFontMask)
        let code = Self.resolveFont(families: t.codeFont, size: codeSize, mono: true)
        codeFont = code
        codeBold = Self.variant(code, traits: .boldFontMask)
        inlineCodeFont = Self.resolveFont(families: t.codeFont, size: (baseSize * CGFloat(t.codeSize)).rounded(), mono: true)

        let weight: NSFont.Weight = switch t.headingWeight {
        case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold; case .heavy: .heavy
        }
        let base = baseSize
        var hf: [NSFont] = []
        for i in 0..<6 {
            let s = i < t.headingScale.count ? t.headingScale[i] : 1
            let size = (base * CGFloat(s)).rounded()
            let f = Self.resolveFont(families: t.bodyFont, size: size, mono: false)
            hf.append(Self.weighted(f, weight: weight, families: t.bodyFont))
        }
        headingFonts = hf

        let c = theme.colors
        background = c.background.nsColor; foreground = c.foreground.nsColor; muted = c.muted.nsColor
        accent = c.accent.nsColor; heading = c.heading.nsColor; border = c.border.nsColor; selection = c.selection.nsColor
        quoteForeground = c.blockquote.foreground.nsColor; quoteBorder = c.blockquote.border.nsColor; quoteBackground = c.blockquote.background.nsColor
        codeBackground = c.code.background.nsColor; codeForeground = c.code.foreground.nsColor
        inlineCodeBackground = c.code.inlineBackground.nsColor; inlineCodeForeground = c.code.inlineForeground.nsColor
        codeBorder = c.code.border.nsColor; lineNumber = c.code.lineNumber.nsColor
        tableHeaderBackground = c.table.headerBackground.nsColor; tableStripe = c.table.stripe.nsColor
        tableBorder = c.table.border.nsColor; tableHover = c.table.hover.nsColor
        var sc: [TokenKind: NSColor] = [:]
        for (k, v) in c.syntax { sc[k] = v.nsColor }
        syntaxColors = sc

        let l = theme.layout
        maxContentWidth = CGFloat(l.maxContentWidth) * scale
        horizontalPadding = CGFloat(l.horizontalPadding)
        verticalPadding = CGFloat(l.verticalPadding)
        codeBlockRadius = CGFloat(l.codeBlockRadius)
        codeBlockPadding = (CGFloat(l.codeBlockPadding) * scale).rounded()
        blockquoteBarWidth = CGFloat(l.blockquoteBarWidth)
        tableCellPadding = (CGFloat(l.tableCellPadding.first ?? 6) * scale, CGFloat(l.tableCellPadding.dropFirst().first ?? 12) * scale)
    }

    public func syntaxColor(_ kind: TokenKind) -> NSColor { syntaxColors[kind] ?? codeForeground }

    public func headingFont(level: Int) -> NSFont { headingFonts[max(0, min(5, level - 1))] }

    // MARK: - 字体解析

    /// 家族名列表取第一个可用；`system` / `system-serif` / `system-rounded` / `system-mono` 为系统字体关键字
    static func resolveFont(families: [String], size: CGFloat, mono: Bool) -> NSFont {
        for name in families {
            switch name.lowercased() {
            case "system", "-apple-system", "system-ui": return NSFont.systemFont(ofSize: size)
            case "system-serif": return NSFont.systemFont(ofSize: size).withDesign(.serif)
            case "system-rounded": return NSFont.systemFont(ofSize: size).withDesign(.rounded)
            case "system-mono", "monospace": return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            default:
                if let f = NSFont(name: name, size: size) { return f }
                // 家族名（如 "SF Mono" 而非 PostScript 名）
                if NSFontManager.shared.availableFontFamilies.contains(name),
                   let f = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) { return f }
            }
        }
        return mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
    }

    static func variant(_ font: NSFont, traits: NSFontTraitMask) -> NSFont {
        let fm = NSFontManager.shared
        let converted = fm.convert(font, toHaveTrait: traits)
        // 转换失败会原样返回；系统字体的斜体需要走 descriptor
        if converted == font, traits.contains(.italicFontMask) {
            let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            return NSFont(descriptor: d, size: font.pointSize) ?? font
        }
        return converted
    }

    static func weighted(_ font: NSFont, weight: NSFont.Weight, families: [String]) -> NSFont {
        let first = families.first?.lowercased() ?? "system"
        switch first {
        case "system", "-apple-system", "system-ui": return NSFont.systemFont(ofSize: font.pointSize, weight: weight)
        case "system-serif": return NSFont.systemFont(ofSize: font.pointSize, weight: weight).withDesign(.serif)
        case "system-rounded": return NSFont.systemFont(ofSize: font.pointSize, weight: weight).withDesign(.rounded)
        default:
            let w: Int = switch weight {
            case .regular: 5; case .medium: 6; case .semibold: 8; case .bold: 9; case .heavy: 11; default: 5
            }
            return NSFontManager.shared.font(withFamily: font.familyName ?? "", traits: w >= 9 ? .boldFontMask : [], weight: w, size: font.pointSize) ?? font
        }
    }
}

extension NSFont {
    func withDesign(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
        guard let d = fontDescriptor.withDesign(design) else { return self }
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}
