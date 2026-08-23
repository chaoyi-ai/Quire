@testable import QuireCore
import XCTest

/// 测的是 QuireCore.VersionCompare 本尊（UpdateChecker 直接调它）
final class VersionCompareTests: XCTestCase {
    func isNewer(_ a: String, than b: String) -> Bool { VersionCompare.isNewer(a, than: b) }

    func testCompare() {
        XCTAssertTrue(isNewer("0.4.1", than: "0.4.0"))
        XCTAssertTrue(isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(isNewer("0.4.0", than: "0.4.0"))
        XCTAssertFalse(isNewer("0.3.9", than: "0.4"))
        XCTAssertTrue(isNewer("0.10.0", than: "0.9.0"), "按数字不按字符串")
    }
}
