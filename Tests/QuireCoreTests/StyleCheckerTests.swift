import XCTest
@testable import QuireCore

final class StyleCheckerTests: XCTestCase {
    func testEnglishWholeWordAndCategories() {
        let c = StyleChecker()
        let text = "Basically we can combine together our plans at the end of the day. Reallyism is not really a word."
        let m = c.matches(in: text)
        let phrases = m.map { $0.phrase.lowercased() }
        XCTAssertTrue(phrases.contains("basically")); XCTAssertTrue(phrases.contains("combine together")); XCTAssertTrue(phrases.contains("at the end of the day"))
        XCTAssertTrue(phrases.contains("really")); XCTAssertFalse(phrases.contains("reallyism"), "整词匹配")
        XCTAssertEqual(m.first { $0.phrase.lowercased() == "combine together" }?.category, .redundancy)
    }
    func testChineseAndNoCrossLanguageFalsePositives() {
        let c = StyleChecker()
        let m = c.matches(in: "众所周知，我们基本上完成了进行研究的工作，免费赠送给大家。")
        let phrases = m.map(\.phrase)
        XCTAssertTrue(phrases.contains("众所周知")); XCTAssertTrue(phrases.contains("基本上")); XCTAssertTrue(phrases.contains("进行研究")); XCTAssertTrue(phrases.contains("免费赠送"))
        // 英文段落不会被中文词表命中，反之亦然（"a lot" 不会在中文段落里找）
        XCTAssertFalse(c.matches(in: "This is a lot of text.").isEmpty)
        XCTAssertTrue(c.matches(in: "这里有 a lot 英文").map(\.phrase).allSatisfy { $0 != "a lot" })
    }
    func testUserRulesAndExceptions() {
        let c = StyleChecker.load(userRules: "# 我的规则\n老铁\n/reg(exp?|ular expression)/\n-as a matter of fact\n")
        let m = c.matches(in: "老铁，as a matter of fact this regexp works.")
        let phrases = m.map { $0.phrase.lowercased() }
        XCTAssertTrue(phrases.contains("老铁") || m.contains { $0.category == .custom })
        XCTAssertFalse(phrases.contains("as a matter of fact"), "例外生效")
        XCTAssertTrue(phrases.contains("regexp"))
    }
    func testOverlapsResolvedLongestFirst() {
        let c = StyleChecker()
        let m = c.matches(in: "We will combine together here.")
        XCTAssertEqual(m.filter { $0.range.location == 8 }.count, 1)
    }
}
