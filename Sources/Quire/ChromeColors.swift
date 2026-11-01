import AppKit

/// 窗口铬的颜色算式（DESIGN.md §8.1）：一切铬色从主题背景推导。
/// 铬（工具栏行、侧栏、标签条）= 主题背景「抬高一级」；正文 = 主题背景。比例最初按 macOS 26 系统标签栏的覆盖层校准（0.9.1），
/// 现在没有系统件了，但这个量级看起来正好：分得清、不抢眼
@MainActor
enum ChromeColors {
    /// 实测（macOS 26.6，2×）：标签栏在浅色底上叠 9.5% 黑、深色底上叠 8% 白。直接按 sRGB 分量线性合成
    /// （NSColor.blended 不是线性的，差 5/255 就看得出一道边）
    static let liftLight: CGFloat = 0.095, liftDark: CGFloat = 0.08
    static func elevated(_ bg: NSColor) -> NSColor {
        let c = bg.usingColorSpace(.sRGB) ?? bg
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        let (l, target): (CGFloat, CGFloat) = lum < 0.5 ? (liftDark, 1) : (liftLight, 0)
        func mix(_ v: CGFloat) -> CGFloat { v * (1 - l) + target * l }
        return NSColor(srgbRed: mix(c.redComponent), green: mix(c.greenComponent), blue: mix(c.blueComponent), alpha: 1)
    }

    /// 深色主题？（elevated() 用的同一个亮度判断）
    static func isDark(_ bg: NSColor) -> Bool {
        let c = bg.usingColorSpace(.sRGB) ?? bg
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }
    /// 铬上的"墨"：铬色朝白（深色主题）/ 黑（浅色主题）走 t——和系统控件在同一行里画选中、分隔线、文字的方式一样（叠白 / 叠黑）
    static func ink(_ bg: NSColor, _ t: CGFloat) -> NSColor { mix(elevated(bg), isDark(bg) ? .white : .black, t) }

    /// sRGB 分量线性混合：t = 0 → a，t = 1 → b
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
        func m(_ u: CGFloat, _ v: CGFloat) -> CGFloat { u * (1 - t) + v * t }
        return NSColor(srgbRed: m(x.redComponent, y.redComponent), green: m(x.greenComponent, y.greenComponent), blue: m(x.blueComponent, y.blueComponent), alpha: 1)
    }

    // MARK: 铬上的状态、线条与文字：见 ChromeStep

    /// WCAG 对比度
    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func lum(_ c: NSColor) -> CGFloat {
            let s = c.usingColorSpace(.sRGB) ?? c
            func ch(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(s.redComponent) + 0.7152 * ch(s.greenComponent) + 0.0722 * ch(s.blueComponent)
        }
        let (l1, l2) = (lum(a), lum(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

/// 铬上的墨阶（DESIGN.md §8.1）：都用 `ChromeColors.ink(背景, 档位)`——铬色朝白（深色主题）/ 黑（浅色）走一步。
/// 档位取 AppKit 在同一行里自己画的强度（macOS 27.0.1 解析 / 实测），所以自绘的标签和系统的分段控件、侧栏读起来是一家：
/// tertiarySystemFill 4.7%（分段控件选中段）、quaternarySystemFill 2.7%、systemFill 9.8%、labelColor 85%、工具栏图标 50%（深）/ 55%（浅）
enum ChromeStep {
    /// 选中底板：深色 = 分段控件选中段（4.7%）；浅色主题里 4.7% 只有 1.10:1，看不太出来，加到 7%（方向不变，比系统那段略深）
    static func selected(dark: Bool) -> CGFloat { dark ? 0.047 : 0.07 }
    /// 标签之间的分隔线：细线要多一点墨才看得见，所以深色主题比选中底板（4.7%）略强、浅色（7%）略弱；面积小，一眼看过去还是底板显眼
    static let separator: CGFloat = 0.065
    /// 悬停底（只给 + 这类按钮；标签悬停不加底）
    static let hoverFill: CGFloat = 0.027
    /// 按下
    static let pressedFill: CGFloat = 0.098
    /// 选中 / 唯一标签的标题
    static let primaryText: CGFloat = 0.85
    /// 悬停标签的标题（= 分段控件选中段图标的墨）
    static let hoverText: CGFloat = 0.72
    /// 其余标题：所有内置主题里对铬 ≥ 4.5:1
    static func secondaryText(dark: Bool) -> CGFloat { dark ? 0.60 : 0.58 }
    /// 图标（+ 等），与旁边的系统工具栏图标同墨
    static func glyph(dark: Bool) -> CGFloat { dark ? 0.50 : 0.55 }
}
