import XCTest
@testable import QuireCore

final class RelativePathTests: XCTestCase {
    func testPlain() {
        XCTAssertEqual(RelativePath.relative(URL(fileURLWithPath: "/a/b/c/d.md"), to: URL(fileURLWithPath: "/a/b")), "c/d.md")
        XCTAssertEqual(RelativePath.relative(URL(fileURLWithPath: "/a/b/c/d.md"), to: URL(fileURLWithPath: "/a/b/")), "c/d.md")
    }

    func testSymlinkedRoot() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quire-rel-\(getpid())")
        let real = base.appendingPathComponent("real"), link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = real.appendingPathComponent("sub/x.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        // 根用链接路径、文件用真实路径（FileManager 枚举常见情形）
        XCTAssertEqual(RelativePath.relative(file, to: link), "sub/x.md")
        // 反过来也行
        XCTAssertEqual(RelativePath.relative(link.appendingPathComponent("sub/x.md"), to: real), "sub/x.md")
    }

    func testOutsideFallsBackToName() {
        XCTAssertEqual(RelativePath.relative(URL(fileURLWithPath: "/x/y.md"), to: URL(fileURLWithPath: "/a/b")), "y.md")
    }
}
