import XCTest
@testable import QuireRender
@testable import QuireCore

final class RenderSmokeTests: XCTestCase {
    func testVersion() { XCTAssertFalse(QuireRenderInfo.version.isEmpty) }
}
