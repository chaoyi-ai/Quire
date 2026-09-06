import Foundation

/// 阅读进度（Kindle 的"本章剩余时间"，见 docs/research/kindle.md §3.5）：章节划分、章节内剩余字数、按读者实际速度校准。
/// 纯计算，App 层（ReadingTracker）负责采样时机与持久化。
public struct ChapterRange: Equatable, Sendable {
    public var title: String
    public var level: Int
    /// 章节起始块（标题块）；文档开头没有标题时为 0、title 为空
    public var startBlock: Int
    /// 结束块（不含）：下一个级别 ≤ 本章的标题块，或 blocks.count
    public var endBlock: Int
    public init(title: String, level: Int, startBlock: Int, endBlock: Int) {
        self.title = title; self.level = level; self.startBlock = startBlock; self.endBlock = endBlock
    }
}

public enum ReadingProgress {
    /// 包含某块的章节：最近一个在它之前（含）的标题；章节到下一个同级或更高级标题为止
    public static func chapter(containing block: Int, in doc: Document) -> ChapterRange? {
        guard !doc.blocks.isEmpty, block >= 0, block < doc.blocks.count else { return nil }
        let entries = doc.outline.entries
        guard let i = entries.lastIndex(where: { $0.blockIndex <= block }) else {
            // 第一个标题之前的部分
            return ChapterRange(title: "", level: 0, startBlock: 0, endBlock: entries.first?.blockIndex ?? doc.blocks.count)
        }
        let cur = entries[i]
        let end = entries[(i + 1)...].first { $0.level <= cur.level }?.blockIndex ?? doc.blocks.count
        return ChapterRange(title: cur.title, level: cur.level, startBlock: cur.blockIndex, endBlock: end)
    }

    /// 源码每行起点的 utf8 下标（1-based 行 n 的起点 = offsets[n-1]）；一次扫描，1 MB ≈ 1 ms。最后追加 utf8.count 作哨兵
    public static func lineStarts(of source: String) -> [String.Index] {
        var out: [String.Index] = [source.startIndex]
        let u = source.utf8
        var i = u.startIndex
        while i < u.endIndex {
            if u[i] == 0x0A { out.append(u.index(after: i)) }
            i = u.index(after: i)
        }
        out.append(source.endIndex)
        return out
    }

    /// 块区间 [from, to) 覆盖的源码文本统计（按块的 sourceRange 行号切源码）
    public static func stats(ofBlocks range: Range<Int>, in doc: Document, source: String, lineStarts: [String.Index]) -> TextStats {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= doc.blocks.count else { return TextStats() }
        guard let first = doc.blocks[range.lowerBound...].first(where: { $0.sourceRange != nil })?.sourceRange,
              let last = doc.blocks[range].last(where: { $0.sourceRange != nil })?.sourceRange else { return TextStats() }
        let startLine = max(1, first.start.line), endLine = max(startLine, last.end.line)
        guard startLine - 1 < lineStarts.count else { return TextStats() }
        let a = lineStarts[startLine - 1]
        let b = lineStarts[min(endLine, lineStarts.count - 1)]
        guard a <= b else { return TextStats() }
        return TextStats.compute(String(source[a..<b]))
    }
}

extension TextStats {
    /// 标称阅读时间（分钟，不取整）：中文 400 字 / 分，其他 200 词 / 分
    public var nominalMinutes: Double { Double(cjkCharacters) / 400 + Double(words - cjkCharacters) / 200 }
}

/// 读者实际速度相对标称速度的倍率（1 = 标称），滑动平均。样本 = "读过一段文字用了多久"
public struct ReadingSpeed: Codable, Equatable, Sendable {
    public var factor: Double = 1
    public var samples = 0
    public init() {}
    public init(factor: Double, samples: Int) { self.factor = factor; self.samples = samples }

    /// 一次采样至少要读这么久才算"在读"（太短是翻找），太长是离开了
    public static let minInterval: TimeInterval = 3, maxInterval: TimeInterval = 180
    /// 可信的速度倍率范围：快过 4× 是在翻页找东西，慢过 0.25× 是挂机
    public static let factorRange: ClosedRange<Double> = 0.25...4

    /// 记一次：读了标称 `nominalMinutes` 分钟的文字，实际用了 `seconds` 秒。不可信的样本丢掉，返回是否采纳
    @discardableResult
    public mutating func record(nominalMinutes: Double, seconds: TimeInterval) -> Bool {
        guard nominalMinutes > 0.02, seconds >= Self.minInterval, seconds <= Self.maxInterval else { return false }
        let k = nominalMinutes * 60 / seconds
        guard Self.factorRange.contains(k) else { return false }
        // 前几个样本学得快一点，之后稳下来
        let alpha = samples < 5 ? 0.4 : 0.15
        factor = samples == 0 ? k : factor + alpha * (k - factor)
        samples += 1
        return true
    }

    /// 校准后的阅读时间（分钟，向上取整，至少 1）
    public func minutes(forNominal m: Double) -> Int { m <= 0 ? 0 : max(1, Int((m / factor).rounded(.up))) }
    public var isCalibrated: Bool { samples >= 3 }
}
