import AppKit
import QuireCore

/// 渲染层自定义属性 key。写在段落首字符（或整段）上，供布局片段绘制与交互读取。
public enum QuireAttribute {
    /// 块类型标记，值为 `BlockRole`
    public static let blockRole = NSAttributedString.Key("quire.blockRole")
    /// 引用嵌套深度（Int，≥1）
    public static let quoteDepth = NSAttributedString.Key("quire.quoteDepth")
    /// 代码块语言（String，可空）
    public static let codeLanguage = NSAttributedString.Key("quire.codeLanguage")
    /// 标题级别（Int 1…6）
    public static let headingLevel = NSAttributedString.Key("quire.headingLevel")
    /// 行内代码 run（Bool）：背景由 BlockLayoutFragment 自绘（垂直居中的圆角框），不用 .backgroundColor
    public static let inlineCode = NSAttributedString.Key("quire.inlineCode")
}

/// 段落在文档中的角色（决定自定义绘制）
public enum BlockRole: Int, Sendable {
    case body = 0
    case heading
    case codeBlock
    case blockQuote
    case thematicBreak
    case frontMatter
    case htmlBlock
    case image
    case table
    case mermaid
    case listItem
    case math
    /// 混合模式里处于源码态的块（每个源码行一段）：画成一整块浅底，不带复制按钮与行号
    case source
}

/// 代码块内换行使用 U+2028（行分隔符），使整个代码块保持为一个段落 → 一个布局片段 → 一块背景。
/// 复制时由 `ReaderTextView` 换回 "\n"。
public let codeLineSeparator: Character = "\u{2028}"
