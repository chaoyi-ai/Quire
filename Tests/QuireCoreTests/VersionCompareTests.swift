import XCTest

/// UpdateChecker.isNewer 在 App 目标里（可执行目标不能被测试导入），这里镜像同一算法做回归
final class VersionCompareTests: XCTestCase {
    func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
    func testCompare() {
        XCTAssertTrue(isNewer("0.4.1", than: "0.4.0"))
        XCTAssertTrue(isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(isNewer("0.4.0", than: "0.4.0"))
        XCTAssertFalse(isNewer("0.3.9", than: "0.4"))
        XCTAssertTrue(isNewer("0.10.0", than: "0.9.0"), "按数字不按字符串")
    }
}
