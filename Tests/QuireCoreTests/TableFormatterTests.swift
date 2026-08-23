import XCTest
@testable import QuireCore

final class TableFormatterTests: XCTestCase {
    func testCellsAndDetection() {
        XCTAssertEqual(TableFormatter.cells("| a | b\\|c | d |"), ["a", "b\\|c", "d"])
        XCTAssertTrue(TableFormatter.isTableLine("a | b | c"))
        XCTAssertFalse(TableFormatter.isTableLine("just text"))
        XCTAssertTrue(TableFormatter.isSeparatorLine("|:--|--:|"))
        XCTAssertEqual(TableFormatter.separator(forHeader: "| a | b |"), "| --- | --- |")
    }
    func testFormatAligns() {
        let out = TableFormatter.format(["|指标|值|", "|:--|--:|", "| 解析 1 MB | 42 ms |", "|x|"])
        XCTAssertEqual(out, ["| 指标      |    值 |", "| :-------- | ----: |", "| 解析 1 MB | 42 ms |", "| x         |       |"])
    }
    func testTableBlock() {
        let lines = ["text", "| a | b |", "|--|--|", "| 1 | 2 |", "", "after"]
        XCTAssertEqual(TableFormatter.tableBlock(lines: lines, containing: 2), 1...3)
        XCTAssertNil(TableFormatter.tableBlock(lines: lines, containing: 0))
    }
    func testCellRanges() {
        let r = TableFormatter.cellRanges("| a | bb |")
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(("| a | bb |" as NSString).substring(with: r[1]).trimmingCharacters(in: .whitespaces), "bb")
    }
}
