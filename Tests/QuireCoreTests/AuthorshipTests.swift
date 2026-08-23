import XCTest
@testable import QuireCore

final class AuthorshipTests: XCTestCase {
    func testTypingInsertsAndShifts() {
        var a = Authorship()
        a.apply(replacing: 0, length: 0, withLength: 5, author: "me")            // "hello"
        a.apply(replacing: 5, length: 0, withLength: 6, author: "me")            // "hello world" 合并
        XCTAssertEqual(a.spans, [.init(author: "me", start: 0, length: 11)])
        a.apply(replacing: 0, length: 0, withLength: 3, author: "ai")            // 前面插入
        XCTAssertEqual(a.spans, [.init(author: "ai", start: 0, length: 3), .init(author: "me", start: 3, length: 11)])
        a.apply(replacing: 4, length: 2, withLength: 0, author: nil)             // 删掉 me 中间两字
        XCTAssertEqual(a.spans, [.init(author: "ai", start: 0, length: 3), .init(author: "me", start: 3, length: 9)])
    }

    func testReplaceSplitsSpans() {
        var a = Authorship(spans: [.init(author: "me", start: 0, length: 10)])
        a.apply(replacing: 3, length: 4, withLength: 2, author: "paste")
        XCTAssertEqual(a.spans, [.init(author: "me", start: 0, length: 3), .init(author: "paste", start: 3, length: 2), .init(author: "me", start: 5, length: 3)])
        // 无归属替换：中间留空
        a.apply(replacing: 3, length: 2, withLength: 1, author: nil)
        XCTAssertEqual(a.spans, [.init(author: "me", start: 0, length: 3), .init(author: "me", start: 4, length: 3)])
    }

    func testAssign() {
        var a = Authorship(spans: [.init(author: "me", start: 0, length: 10)])
        a.assign(start: 2, length: 5, author: "quote")
        XCTAssertEqual(a.spans.map(\.author), ["me", "quote", "me"])
        a.assign(start: 0, length: 10, author: nil)
        XCTAssertTrue(a.spans.isEmpty)
    }

    func testNormalizeClipsAndMerges() {
        var a = Authorship(spans: [.init(author: "me", start: 5, length: 5), .init(author: "me", start: 0, length: 5), .init(author: "ai", start: 8, length: 10), .init(author: "x", start: 30, length: 2)])
        a.normalize(textLength: 15)
        XCTAssertEqual(a.spans, [.init(author: "me", start: 0, length: 10), .init(author: "ai", start: 10, length: 5)])
    }

    func testRoundTripAndHash() {
        var a = Authorship()
        a.apply(replacing: 0, length: 0, withLength: 6, author: "me")
        a.addAuthor(named: "Editor")
        let body = "# 标题\n\n正文。\n"
        let file = a.embed(into: body)
        XCTAssertTrue(file.hasPrefix(body + "\n<!-- quire-authorship v1 hash="))
        XCTAssertTrue(file.hasSuffix("-->\n"))
        let (b, parsed, mismatch) = Authorship.split(file)
        XCTAssertEqual(b, body); XCTAssertFalse(mismatch)
        XCTAssertEqual(parsed?.spans, a.spans)
        XCTAssertEqual(parsed?.authors.last?.name, "Editor")
        XCTAssertEqual(parsed?.authors.last?.color, Authorship.palette[0])
        // 正文被外部改了：哈希对不上 → 区间丢弃，作者表保留
        let tampered = file.replacingOccurrences(of: "正文。", with: "正文！")
        let (b2, p2, m2) = Authorship.split(tampered)
        XCTAssertEqual(b2, "# 标题\n\n正文！\n"); XCTAssertTrue(m2)
        XCTAssertEqual(p2?.spans.count, 0); XCTAssertEqual(p2?.authors.count, 5)
    }

    func testBodyWithoutTrailingNewlineRoundTrips() {
        let a = Authorship(spans: [.init(author: "me", start: 0, length: 2)])
        let file = a.embed(into: "ab")
        let (b, p, m) = Authorship.split(file)
        XCTAssertEqual(b, "ab\n"); XCTAssertFalse(m); XCTAssertEqual(p?.spans.count, 1)
        // 再 embed 一次得到同样的文件（稳定：key 排序）
        XCTAssertEqual(p!.embed(into: b), file)
    }

    func testCustomAuthorsPersistWithoutSpans_andTrailingWhitespaceTolerated() {
        var a = Authorship()
        a.addAuthor(named: "Editor")
        let file = a.embed(into: "x\n")
        XCTAssertTrue(file.contains(Authorship.marker), "加过作者就该存")
        let (b, p, m) = Authorship.split(file + "\n\n")
        XCTAssertEqual(b, "x\n"); XCTAssertFalse(m); XCTAssertEqual(p?.authors.last?.name, "Editor")
        // 块在但坏了：按对不上处理，不吞块也不保留坏数据
        let broken = "x\n\n<!-- quire-authorship v1 hash=abc\n{not json\n-->\n"
        let (b2, p2, m2) = Authorship.split(broken)
        XCTAssertEqual(b2, "x\n"); XCTAssertTrue(m2); XCTAssertEqual(p2?.spans.count, 0)
    }

    func testNoSpansNoTrailer_andPlainFilesUntouched() {
        XCTAssertEqual(Authorship().embed(into: "x\n"), "x\n")
        let (b, a, m) = Authorship.split("plain <!-- comment -->\n")
        XCTAssertEqual(b, "plain <!-- comment -->\n"); XCTAssertNil(a); XCTAssertFalse(m)
    }

    func testRealignByDiff() {
        var a = Authorship(spans: [.init(author: "me", start: 0, length: 5), .init(author: "ai", start: 6, length: 5)])   // "hello world"
        a.realign(from: "hello world", to: "hello big world", author: "me")          // 中间插入（索引 5 的空格本来就无归属）
        XCTAssertEqual(a.spans, [.init(author: "me", start: 0, length: 5), .init(author: "me", start: 6, length: 4), .init(author: "ai", start: 10, length: 5)])
        a.realign(from: "hello big world", to: "hello big worl", author: nil)        // 末尾删一个
        XCTAssertEqual(a.spans.last, .init(author: "ai", start: 10, length: 4))
        a.realign(from: "hello big worl", to: "hello big worl", author: nil)         // 没变
        XCTAssertEqual(a.spans.count, 3)
    }

    func testCounts() {
        let a = Authorship(spans: [.init(author: "me", start: 0, length: 4), .init(author: "ai", start: 4, length: 6), .init(author: "me", start: 20, length: 1)])
        XCTAssertEqual(a.characterCounts, ["me": 5, "ai": 6])
    }
}
