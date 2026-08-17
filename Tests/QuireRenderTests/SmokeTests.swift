import XCTest
@testable import QuireRender
final class RenderSmokeTests: XCTestCase { func testVersion() { XCTAssertFalse(QuireRender.version.isEmpty) } }
