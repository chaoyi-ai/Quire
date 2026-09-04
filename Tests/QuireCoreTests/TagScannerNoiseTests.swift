import XCTest
@testable import QuireCore

/// 侧栏标签段的误报（技术文档里的 `#rgb` / `#anchor`）与嵌套标签
final class TagScannerNoiseTests: XCTestCase {
    private func scan(_ s: String) -> [String] { TagScanner.scan(s.data(using: .utf8)!) }

    func testInlineCodeAndURLsAreNotTags() {
        let doc = """
        颜色写成 `#rgb` 或 `#rrggbb`，锚点用 `#anchor`；``带 # 的 `双反引号`` 也跳过。
        链接 https://example.com/page#frag 和 ?x=1#top 不算。
        真正的标签：#设计 和 #todo。
        """
        XCTAssertEqual(scan(doc), ["设计", "todo"])
    }

    func testUnclosedBacktickDoesNotEatTheParagraph() {
        XCTAssertEqual(scan("一个 ` 孤零零的反引号 #still 算标签"), ["still"])
    }

    func testNestedTags() {
        XCTAssertEqual(scan("#设计/侧栏 与 #a/b/c，#a/ 末尾斜杠去掉，#/x 不算，#a//b 不算"), ["设计/侧栏", "a/b/c", "a"])
    }

    func testColorsStillExcludedButWordsKept() {
        XCTAssertEqual(scan("#fff #1a2b3c #cafe #beef #bad"), ["cafe", "beef", "bad"])
    }
}
