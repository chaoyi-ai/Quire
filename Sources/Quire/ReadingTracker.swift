import Foundation
import QuireCore

/// 章节进度（给字数胶囊）：本章标题、剩余字数、按读者速度校准后的剩余分钟
struct ChapterProgress: Equatable {
    var title: String
    var remainingWords: Int
    var remainingMinutes: Int
    var totalMinutes: Int
}

/// 阅读进度跟踪：阅读视图顶部块每变一次记一次样本（读过多少标称分钟的文字、用了多久）→ 校准 `ReadingSpeed`；
/// 并算出当前章节的剩余量。倍率持久化在 `reader.speed`。
@MainActor
final class ReadingTracker {
    private static let key = "reader.speed"
    private(set) var speed: ReadingSpeed
    private var lineStarts: [String.Index] = []
    private var source = ""
    private var doc: Document = .empty
    private var lastBlock: Int?
    private var lastTime: Date?
    private var chapterCache: (range: ChapterRange, total: TextStats)?

    init() {
        speed = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ReadingSpeed.self, from: $0) } ?? ReadingSpeed()
    }

    /// 文档（重新）解析后：换源码与块表；不清速度，但清掉上一次的位置（块下标已经不可比）
    func documentChanged(_ doc: Document, source: String) {
        self.doc = doc
        if source != self.source { self.source = source; lineStarts = ReadingProgress.lineStarts(of: source) }
        chapterCache = nil
        lastBlock = nil; lastTime = nil
    }

    /// 阅读视图顶部块变了：采样 + 返回本章进度
    func topBlockChanged(_ block: Int, at now: Date = Date()) -> ChapterProgress? {
        defer { lastBlock = block; lastTime = now }
        if let lb = lastBlock, let lt = lastTime, block > lb {
            // 往下读了 lb..<block 这些块
            let read = ReadingProgress.stats(ofBlocks: lb..<block, in: doc, source: source, lineStarts: lineStarts)
            if speed.record(nominalMinutes: read.nominalMinutes, seconds: now.timeIntervalSince(lt)) { save() }
        }
        return progress(at: block)
    }

    func progress(at block: Int) -> ChapterProgress? {
        guard let ch = ReadingProgress.chapter(containing: block, in: doc) else { return nil }
        if chapterCache?.range != ch {
            chapterCache = (ch, ReadingProgress.stats(ofBlocks: ch.startBlock..<ch.endBlock, in: doc, source: source, lineStarts: lineStarts))
        }
        let remaining = ReadingProgress.stats(ofBlocks: block..<ch.endBlock, in: doc, source: source, lineStarts: lineStarts)
        return ChapterProgress(title: ch.title, remainingWords: remaining.words,
                               remainingMinutes: speed.minutes(forNominal: remaining.nominalMinutes),
                               totalMinutes: speed.minutes(forNominal: chapterCache!.total.nominalMinutes))
    }

    /// 全文按校准速度的阅读时间
    func minutes(for stats: TextStats) -> Int { speed.minutes(forNominal: stats.nominalMinutes) }

    func resetSpeed() { speed = ReadingSpeed(); save() }
    private func save() { if let d = try? JSONEncoder().encode(speed) { UserDefaults.standard.set(d, forKey: Self.key) } }
}
