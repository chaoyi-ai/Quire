import Foundation

/// 阅读版式：与配色主题**正交**的一层（Kindle 的做法，见 docs/research/kindle.md §3.1）。
/// 每项的零值（0 / 空 / -1 / .theme）= 跟随主题；显式值覆盖主题的 typography / layout。只影响阅读视图，编辑器有自己的设置。
public struct ReadingLayout: Codable, Hashable, Sendable {
    public enum Weight: Int, Codable, Sendable, CaseIterable { case theme = 0, medium, semibold }
    public enum Alignment: Int, Codable, Sendable, CaseIterable { case theme = 0, leading, justified }

    public var bodyFontFamily = ""
    public var codeFontFamily = ""
    /// pt；0 = 主题
    public var fontSize = 0
    public var weight: Weight = .theme
    /// 行高倍率；0 = 主题
    public var lineHeight: Double = 0
    /// 段距（em）；0 = 主题
    public var paragraphSpacing: Double = 0
    /// 内容列宽（pt）；-1 = 主题，0 = 不限
    public var contentWidth = -1
    public var alignment: Alignment = .theme

    public init() {}
    public init(bodyFontFamily: String = "", codeFontFamily: String = "", fontSize: Int = 0, weight: Weight = .theme,
                lineHeight: Double = 0, paragraphSpacing: Double = 0, contentWidth: Int = -1, alignment: Alignment = .theme) {
        self.bodyFontFamily = bodyFontFamily; self.codeFontFamily = codeFontFamily; self.fontSize = fontSize; self.weight = weight
        self.lineHeight = lineHeight; self.paragraphSpacing = paragraphSpacing; self.contentWidth = contentWidth; self.alignment = alignment
    }

    public static let followTheme = ReadingLayout()
    public var isFollowingTheme: Bool { self == .followTheme }

    // 面板 / 设置里的取值
    public static let fontSizes = [13, 14, 15, 16, 17, 18, 19, 20, 22, 24]
    public static let lineHeightRange: ClosedRange<Double> = 1.3...2.0
    public static let paragraphSpacingRange: ClosedRange<Double> = 0.5...1.5
    /// 主题 / 窄 / 中 / 宽 / 不限
    public static let contentWidths = [-1, 620, 760, 920, 0]
}

/// 版式预设：只含版式、不含配色。内置四个 + 用户自存（名字由用户起）
public struct ReadingLayoutPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// 内置预设的 name 是本地化键（App 层用 L() 翻），用户预设是原文
    public var name: String
    public var layout: ReadingLayout
    public var isBuiltIn: Bool
    public init(id: String, name: String, layout: ReadingLayout, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.layout = layout; self.isBuiltIn = isBuiltIn
    }

    public static let builtIn: [ReadingLayoutPreset] = [
        // 紧凑：屏幕上多放内容——小字、紧行距、宽列
        ReadingLayoutPreset(id: "compact", name: "紧凑", layout: ReadingLayout(fontSize: 15, lineHeight: 1.45, paragraphSpacing: 0.75, contentWidth: 920), isBuiltIn: true),
        ReadingLayoutPreset(id: "standard", name: "标准", layout: .followTheme, isBuiltIn: true),
        // 舒适：书本式长文阅读
        ReadingLayoutPreset(id: "comfortable", name: "舒适", layout: ReadingLayout(fontSize: 17, lineHeight: 1.7, paragraphSpacing: 1.0, contentWidth: 760), isBuiltIn: true),
        // 大字：Kindle 的 Large / Low Vision 折中——大字号、更松、窄列、正文加重
        ReadingLayoutPreset(id: "large", name: "大字", layout: ReadingLayout(fontSize: 20, weight: .medium, lineHeight: 1.8, paragraphSpacing: 1.1, contentWidth: 620), isBuiltIn: true),
    ]

    /// 与当前版式完全一致的预设（先内置再用户）
    public static func matching(_ layout: ReadingLayout, user: [ReadingLayoutPreset]) -> ReadingLayoutPreset? {
        (builtIn + user).first { $0.layout == layout }
    }
}

extension RenderOptions {
    /// 把版式叠到渲染选项上（版式字段覆盖同名选项）
    public func applying(_ l: ReadingLayout) -> RenderOptions {
        var o = self
        o.bodyFontFamily = l.bodyFontFamily
        o.codeFontFamily = l.codeFontFamily
        o.baseFontSize = l.fontSize
        o.bodyWeight = l.weight.rawValue
        o.lineHeight = l.lineHeight
        o.paragraphSpacing = l.paragraphSpacing
        o.contentWidth = l.contentWidth
        o.alignment = l.alignment.rawValue
        return o
    }
}
