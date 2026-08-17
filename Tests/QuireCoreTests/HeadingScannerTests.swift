import XCTest
@testable import QuireCore

final class HeadingScannerTests: XCTestCase {
    func scan(_ s: String) -> [(Int, String, Int)] { HeadingScanner.scan(Data(s.utf8)).map { ($0.level, $0.title, $0.line) } }

    func testATXAndSetext() {
        let r = scan("---\ntitle: x\n---\n# 一\n\n文字\n\n## 二 ##\n\nSetext 一\n=====\n\nSetext 二\n---\n\n```\n# 不是标题\n```\n\n    # 缩进代码也不是\n\n###### 六\n####### 七个不是\n")
        XCTAssertEqual(r.map { $0.1 }, ["一", "二", "Setext 一", "Setext 二", "六"])
        XCTAssertEqual(r.map { $0.0 }, [1, 2, 1, 2, 6])
        XCTAssertEqual(r[0].2, 4)
        XCTAssertEqual(r[2].2, 10)
    }

    func testListItemNotSetext() {
        // "- item" 后接 "---" 是分割线不是 setext
        XCTAssertTrue(scan("- item\n---\n").isEmpty)
        // 表格分隔行也不是
        XCTAssertTrue(scan("| a |\n---\n").isEmpty)
    }

    func testMatchesFullParserOnFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "small", withExtension: "md", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let fast = HeadingScanner.scan(data).map { "\($0.level):\($0.title)" }
        let full = MarkdownParser().parse(String(decoding: data, as: UTF8.self)).outline.entries.map { "\($0.level):\($0.title)" }
        XCTAssertEqual(fast, full)
    }

    func testThroughput() {
        let unit = "# 标题\n\n段落 **粗** *斜* `code` [l](u) 文字文字。\n\n- 项目一\n- 项目二\n\n```swift\n# not\n```\n\n"
        let data = Data(String(repeating: unit, count: 10000).utf8) // ~1.2 MB
        let t0 = Date()
        let r = HeadingScanner.scan(data, maxHeadings: 100_000)
        let dt = Date().timeIntervalSince(t0)
        XCTAssertEqual(r.count, 10000)
        XCTAssertLessThan(dt, 0.5, "1.2 MB 标题扫描耗时 \(dt)s")
    }
}
