import AppKit

/// 窗口铬的颜色算式（DESIGN.md §8.1）：一切铬色从主题背景推导。
/// 「抬高一级」的比例按系统标签栏的覆盖层校准：macOS 26 的标签栏在窗口底色上叠约 9% 的黑（浅色）/ 白（深色），
/// 没有 API 能改它——所以侧栏、工具栏行、字数胶囊都用同一比例，让它们和标签栏落在同一个色阶上，铬就是一整块
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

/// 工具栏那一行的底色：标题栏是透明的，透出来的是窗口底色（正文色）；这一块把它铺成铬色，和侧栏、标签栏连成一整块。
/// 放在 contentView 里、正文之上、工具栏之下；不接事件；只盖工具栏行（标签栏那行由系统自己叠色，正好落到同一色阶）
final class ChromeBandView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { true }
}
