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
}
