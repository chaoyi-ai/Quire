import XCTest
import Foundation
@testable import QuireRender

/// 本地化完整性：代码里出现的每个 `L("…")` / `RL("…")` 键都在 zh-Hans 与 en 两套 .strings 里，且两套键集合相等。
final class LocalizationTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func stringsKeys(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(obj as? [String: String], "\(url.lastPathComponent) 不是 key=value 表")
    }

    private func codeKeys(in dir: URL, fn: String) throws -> Set<String> {
        let re = try NSRegularExpression(pattern: "\\b\(fn)\\(\"((?:[^\"\\\\]|\\\\.)*)\"\\)")
        var keys = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let s = try String(contentsOf: file, encoding: .utf8)
            for m in re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
                let raw = (s as NSString).substring(with: m.range(at: 1))
                keys.insert(raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return keys
    }

    private func check(module: String, fn: String, sources: String, resources: String) throws {
        let root = repoRoot
        let code = try codeKeys(in: root.appendingPathComponent(sources), fn: fn)
        XCTAssertFalse(code.isEmpty, "\(module) 没找到任何 \(fn)(\"…\") 键")
        let zh = try stringsKeys(root.appendingPathComponent("\(resources)/zh-Hans.lproj/Localizable.strings"))
        let en = try stringsKeys(root.appendingPathComponent("\(resources)/en.lproj/Localizable.strings"))
        XCTAssertEqual(Set(zh.keys), Set(en.keys), "\(module)：zh-Hans 与 en 键集合不一致")
        let missing = code.subtracting(zh.keys)
        XCTAssertTrue(missing.isEmpty, "\(module)：代码里有键不在 .strings：\(missing)")
        let unused = Set(zh.keys).subtracting(code)
        XCTAssertTrue(unused.isEmpty, "\(module)：.strings 里有键代码未用：\(unused)")
        for (k, v) in zh { XCTAssertEqual(k, v, "zh-Hans 应为恒等映射：\(k)") }
        for (k, v) in en {
            XCTAssertFalse(v.isEmpty, "en 译文为空：\(k)")
            // 格式占位符数量一致
            XCTAssertEqual(k.components(separatedBy: "%").count, v.components(separatedBy: "%").count, "占位符数量不一致：\(k)")
        }
    }

    func testAppStringsComplete() throws {
        try check(module: "Quire", fn: "L", sources: "Sources/Quire", resources: "Sources/Quire/Resources")
    }

    func testRenderStringsComplete() throws {
        try check(module: "QuireRender", fn: "RL", sources: "Sources/QuireRender", resources: "Sources/QuireRender/Resources/Localizable")
    }

    func testRenderBundleHasBothLocalizations() {
        let locs = Set(Bundle.module.localizations.map { $0.lowercased() })
        XCTAssertTrue(locs.contains("en") && locs.contains("zh-hans"), "\(locs)")
        XCTAssertFalse(RL("复制代码").isEmpty)
    }
}
