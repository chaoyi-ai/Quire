import XCTest
@testable import QuireCore

final class TextStatsTests: XCTestCase {
    func testMixedText() {
        let s = TextStats.compute("Hello, world! 这是中文。\nSecond line it's fine\n")
        XCTAssertEqual(s.words, 2 + 4 + 4)         // Hello world / 这是中文（4，。不算）/ Second line it's fine
        XCTAssertEqual(s.cjkCharacters, 4)
        XCTAssertEqual(s.lines, 2)
        XCTAssertEqual(s.characters, "Hello,world!这是中文。Secondlineit'sfine".count)
        XCTAssertEqual(s.readingMinutes, 1)
    }
    func testEmptyAndNoTrailingNewline() {
        XCTAssertEqual(TextStats.compute(""), TextStats())
        XCTAssertEqual(TextStats.compute("a").lines, 1)
        XCTAssertEqual(TextStats.compute("a\nb").lines, 2)
        XCTAssertEqual(TextStats.compute("").readingMinutes, 0)
    }
    func testReadingTime() {
        let zh = String(repeating: "字", count: 1200)
        XCTAssertEqual(TextStats.compute(zh).readingMinutes, 3)
        let en = Array(repeating: "word", count: 450).joined(separator: " ")
        XCTAssertEqual(TextStats.compute(en).readingMinutes, 3)
    }
    func testPerformance1MB() {
        let s = String(repeating: "这是一个性能测试段落，包含 English words and 数字 12345。\n", count: 20000)
        XCTAssertGreaterThan(s.utf8.count, 1_000_000)
        let t = Date()
        _ = TextStats.compute(s)
        XCTAssertLessThan(Date().timeIntervalSince(t), 0.2, "debug 构建也应远低于此；release 预算 5 ms")
    }
}
