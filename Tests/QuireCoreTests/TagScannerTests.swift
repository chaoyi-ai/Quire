import XCTest
@testable import QuireCore

final class TagScannerTests: XCTestCase {
    func testTags() {
        let md = "# 标题不是标签\n\n今天 #日记 和 #todo_2，还有 #1 #fff #日记（重复）。\n\n```\n#code 不算\n```\n\nURL: https://x.com/#frag 不算 email@a#b\n#Swift is #cool."
        XCTAssertEqual(TagScanner.scan(md.data(using: .utf8)!), ["日记", "todo_2", "Swift", "cool"])
        // 像十六进制的英文词是标签；真正的颜色值不是
        let hex = "#cafe #bad #beef #face #c0ffee #1a2b3c #fff #FFF #abc"
        XCTAssertEqual(TagScanner.scan(hex.data(using: .utf8)!), ["cafe", "bad", "beef", "face", "abc"])
    }
}
