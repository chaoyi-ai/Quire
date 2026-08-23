import XCTest
@testable import QuireCore

final class FuzzyMatcherTests: XCTestCase {
    func testSubsequenceAndMiss() {
        XCTAssertNotNil(FuzzyMatcher.match(query: "rdm", candidate: "docs/README.md"))
        XCTAssertNil(FuzzyMatcher.match(query: "xyz", candidate: "docs/README.md"))
        XCTAssertEqual(FuzzyMatcher.match(query: "", candidate: "a")?.score, 0)
    }
    func testRankingPrefersFilenameAndBoundaries() {
        let cands = ["notes/2024/design-notes.md", "docs/DESIGN.md", "src/designer/old.md", "design.md"]
        let r = FuzzyMatcher.rank(query: "design", candidates: cands).map(\.0)
        XCTAssertEqual(r.first, "design.md")
        XCTAssertEqual(r[1], "docs/DESIGN.md", "文件名开头整词命中优先于路径中段")
        XCTAssertTrue(r.contains("notes/2024/design-notes.md"))
    }
    func testCJK() {
        let cands = ["会议记录/2024-01.md", "周报.md", "会议/纪要.md"]
        let r = FuzzyMatcher.rank(query: "会议纪", candidates: cands).map(\.0)
        XCTAssertEqual(r.first, "会议/纪要.md")
        XCTAssertFalse(r.contains("周报.md"))
    }
    func testPositionsForHighlight() {
        let m = FuzzyMatcher.match(query: "rm", candidate: "README.md")!
        XCTAssertEqual(m.positions, [0, 7], "DP 选边界上的 m（.md）而不是 README 中间的 M")
    }
}
