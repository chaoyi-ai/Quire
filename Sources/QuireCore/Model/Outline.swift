import Foundation

/// 大纲（目录）：标题的扁平序列 + 层级；UI 层按需构造树。
public struct Outline: Hashable, Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: String          // 标题 anchor id（GitHub 规则）
        public var level: Int
        public var title: String
        public var blockIndex: Int     // 在 Document.blocks 中的下标
        public var line: Int?          // 源码起始行
        public init(id: String, level: Int, title: String, blockIndex: Int, line: Int?) {
            self.id = id; self.level = level; self.title = title; self.blockIndex = blockIndex; self.line = line
        }
    }
    public var entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }
}

/// GitHub 风格 heading id：小写、去掉标点（保留字母/数字/空格/连字符/下划线，含 CJK）、空格→`-`；重复时追加 `-1`、`-2`…
public struct HeadingIDGenerator {
    private var seen: [String: Int] = [:]
    public init() {}

    public static func slug(_ title: String) -> String {
        var out = ""
        out.reserveCapacity(title.utf8.count)
        for scalar in title.lowercased().unicodeScalars {
            switch scalar {
            case " ": out.append("-")
            case "-", "_": out.append(Character(scalar))
            default:
                if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                    out.unicodeScalars.append(scalar)
                }
                // 其他标点丢弃
            }
        }
        return out
    }

    public mutating func next(for title: String) -> String {
        let base = Self.slug(title)
        let count = seen[base, default: 0]
        seen[base] = count + 1
        return count == 0 ? base : "\(base)-\(count)"
    }
}
