import Foundation

/// 编辑器排版参数（iA Writer 式：字体 / 字号 / 行距 / 行宽）。字体与字号为 nil / 0 时跟随主题。
public struct EditorTypography: Equatable, Sendable {
    public var fontFamily: String? = nil
    public var fontSize: CGFloat = 0
    public var lineHeight: CGFloat = 1.35
    /// 行宽（字符数，按 "0" 的宽度算）；0 = 不限制
    public var columnChars: Int = 0
    public init() {}
    public init(fontFamily: String?, fontSize: CGFloat, lineHeight: CGFloat, columnChars: Int) {
        self.fontFamily = fontFamily; self.fontSize = fontSize; self.lineHeight = lineHeight; self.columnChars = columnChars
    }
}
