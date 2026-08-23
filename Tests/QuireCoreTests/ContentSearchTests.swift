import XCTest
@testable import QuireCore

final class ContentSearchTests: XCTestCase {
    func makeFiles(_ contents: [String]) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quire-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try contents.enumerated().map { (i, c) in
            let u = dir.appendingPathComponent("f\(i).md"); try c.write(to: u, atomically: true, encoding: .utf8); return u
        }
    }

    func testSubstringCaseInsensitiveAndCJK() throws {
        let files = try makeFiles(["# Title\n\nHello World\nhello again\n", "无关\n会议纪要：今天\n", "nothing"])
        var results: [ContentSearch.FileResult] = []
        ContentSearch().run(query: "hello", files: files) { results.append($0) }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].hits.map(\.line), [3, 4])
        XCTAssertEqual(results[0].hits[0].range, 0..<5)
        results = []
        ContentSearch().run(query: "纪要", files: files) { results.append($0) }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].hits[0].line, 2)
        XCTAssertEqual(results[0].hits[0].text, "会议纪要：今天")
        XCTAssertEqual(results[0].hits[0].range, 2..<4)
    }

    func testCaseSensitiveAndRegex() throws {
        let files = try makeFiles(["Foo foo FOO\nbar\n"])
        var opts = ContentSearch.Options(); opts.caseSensitive = true
        var results: [ContentSearch.FileResult] = []
        ContentSearch().run(query: "foo", files: files, options: opts) { results.append($0) }
        XCTAssertEqual(results[0].hits.count, 1)
        XCTAssertEqual(results[0].hits[0].column, 5)
        var ro = ContentSearch.Options(); ro.regex = true
        results = []
        ContentSearch().run(query: "fo+", files: files, options: ro) { results.append($0) }
        XCTAssertEqual(results[0].hits.count, 3)
    }

    func testCancel() throws {
        let files = try makeFiles(Array(repeating: "x match x\n", count: 50))
        let s = ContentSearch()
        var n = 0
        s.run(query: "match", files: files) { _ in n += 1; if n == 3 { s.cancel() } }
        XCTAssertEqual(n, 3)
    }

    func testThroughput50MB() throws {
        // 1000 个 50 KB 文件 ≈ 50 MB：预算 300 ms 出首批结果；这里整体扫完应 < 1.5 s（debug 构建）
        let body = String(repeating: "The quick brown fox jumps over the lazy dog. 解析永远在后台线程。\n", count: 700)
        let files = try makeFiles(Array(repeating: body, count: 1000))
        let t = Date()
        var first: TimeInterval?
        var count = 0
        ContentSearch().run(query: "needle-not-present", files: files) { _ in count += 1 }
        ContentSearch().run(query: "lazy dog", files: files) { _ in if first == nil { first = Date().timeIntervalSince(t) }; count += 1 }
        let total = Date().timeIntervalSince(t)
        XCTAssertEqual(count, 1000)
        XCTAssertLessThan(first ?? 99, 0.3)
        XCTAssertLessThan(total, 3.0)
        print("search 2×50MB total \(Int(total * 1000)) ms, first \(Int((first ?? 0) * 1000)) ms")
    }
}
