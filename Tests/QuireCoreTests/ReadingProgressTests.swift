import XCTest
@testable import QuireCore

/// M8 #88：章节划分、章节内统计、阅读速度校准
final class ReadingProgressTests: XCTestCase {
    let src = "前言一段。\n\n# 第一章\n\n一二三四五六七八九十。\n\n## 1.1 小节\n\n甲乙丙丁。\n\n# 第二章\n\nhello world foo bar\n"

    func testChapterRanges() {
        let doc = MarkdownParser().parse(src)
        // 块：0 前言, 1 H1, 2 段, 3 H2, 4 段, 5 H1, 6 段
        XCTAssertEqual(doc.blocks.count, 7)
        let pre = ReadingProgress.chapter(containing: 0, in: doc)!
        XCTAssertEqual(pre.title, ""); XCTAssertEqual(pre.startBlock, 0); XCTAssertEqual(pre.endBlock, 1)
        let c1 = ReadingProgress.chapter(containing: 2, in: doc)!
        XCTAssertEqual(c1.title, "第一章"); XCTAssertEqual(c1.startBlock, 1); XCTAssertEqual(c1.endBlock, 5, "到下一个同级 H1 为止，含子小节")
        let s11 = ReadingProgress.chapter(containing: 4, in: doc)!
        XCTAssertEqual(s11.title, "1.1 小节"); XCTAssertEqual(s11.endBlock, 5, "小节到下一个级别 ≤ 2 的标题为止")
        let c2 = ReadingProgress.chapter(containing: 6, in: doc)!
        XCTAssertEqual(c2.title, "第二章"); XCTAssertEqual(c2.endBlock, 7)
        XCTAssertNil(ReadingProgress.chapter(containing: 7, in: doc))
    }

    func testStatsOfBlocks() {
        let doc = MarkdownParser().parse(src)
        let starts = ReadingProgress.lineStarts(of: src)
        let c1 = ReadingProgress.stats(ofBlocks: 1..<5, in: doc, source: src, lineStarts: starts)
        // 标题"第一章"3 字 + 正文 10 字 + 小节标题 "1.1 小节"(1.1 一个词 + 2 字) + 4 字
        XCTAssertEqual(c1.cjkCharacters, 3 + 10 + 2 + 4)
        let c2 = ReadingProgress.stats(ofBlocks: 6..<7, in: doc, source: src, lineStarts: starts)
        XCTAssertEqual(c2.words, 4); XCTAssertEqual(c2.cjkCharacters, 0)
        XCTAssertEqual(ReadingProgress.stats(ofBlocks: 3..<3, in: doc, source: src, lineStarts: starts), TextStats())
        // 全文 = 各块之和（行切分不重叠不遗漏）
        let all = ReadingProgress.stats(ofBlocks: 0..<7, in: doc, source: src, lineStarts: starts)
        XCTAssertEqual(all.words, TextStats.compute(src).words)
    }

    func testSpeedCalibration() {
        var s = ReadingSpeed()
        XCTAssertFalse(s.isCalibrated)
        XCTAssertFalse(s.record(nominalMinutes: 1, seconds: 1), "太快 = 翻找")
        XCTAssertFalse(s.record(nominalMinutes: 1, seconds: 600), "太久 = 离开")
        XCTAssertFalse(s.record(nominalMinutes: 0.001, seconds: 10), "几乎没读到字")
        XCTAssertEqual(s.samples, 0)
        // 标称 1 分钟的文字实际读了 30 秒 → 2×
        XCTAssertTrue(s.record(nominalMinutes: 1, seconds: 30))
        XCTAssertEqual(s.factor, 2, accuracy: 0.001)
        for _ in 0..<10 { s.record(nominalMinutes: 1, seconds: 60) }
        XCTAssertTrue(s.isCalibrated)
        XCTAssertLessThan(s.factor, 1.15, "持续按标称速度读，倍率收敛回 1")
        XCTAssertEqual(s.minutes(forNominal: 10), Int((10 / s.factor).rounded(.up)))
        XCTAssertEqual(s.minutes(forNominal: 0), 0)
        XCTAssertEqual(ReadingSpeed(factor: 4, samples: 9).minutes(forNominal: 0.1), 1, "至少 1 分钟")
    }
}
