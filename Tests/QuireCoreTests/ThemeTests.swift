import XCTest
@testable import QuireCore

final class ThemeTests: XCTestCase {
    func testColorParsing() {
        XCTAssertEqual(ThemeColor(hex: "#fff"), ThemeColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(ThemeColor(hex: "#0969da")?.hexString, "#0969da")
        XCTAssertEqual(ThemeColor(hex: "#0969da33")?.alpha ?? 0, 0x33 / 255.0, accuracy: 0.001)
        XCTAssertNil(ThemeColor(hex: "0969da"))
        XCTAssertNil(ThemeColor(hex: "#zzz"))
        XCTAssertNil(ThemeColor(hex: "#12345"))
    }

    func testBuiltInThemesAllLoad() {
        let cat = ThemeStore.loadBuiltIn()
        XCTAssertTrue(cat.errors.isEmpty, "内置主题加载错误：\(cat.errors)")
        let ids = Set(cat.themes.map(\.id))
        XCTAssertEqual(ids, ["github-light", "github-dark", "paper", "solarized-light", "solarized-dark", "nord", "dracula", "one-dark", "gruvbox-light", "gruvbox-dark", "claude-light", "claude-dark"])
        // extends 生效：paper 继承 github-light 的 layout，但覆盖了 background 与字体
        let paper = cat.theme(id: "paper")!
        XCTAssertEqual(paper.layout.maxContentWidth, 760)
        XCTAssertEqual(paper.colors.background.hexString, "#f7f3e9")
        XCTAssertEqual(paper.typography.bodyFont.first, "Charter")
        XCTAssertEqual(paper.typography.codeFont.first, "SF Mono") // 未覆盖 → 继承
        XCTAssertEqual(paper.extendsID, "github-light")
        // 每个主题的 syntax 都齐全
        for t in cat.themes {
            for k in TokenKind.allCases where k != .plain {
                XCTAssertNotNil(t.colors.syntax[k], "\(t.id) 缺少 syntax.\(k.rawValue)")
            }
        }
        XCTAssertEqual(cat.themes(for: .dark).count, 7)
        XCTAssertEqual(cat.themes(for: .light).count, 5)
    }

    func testValidationErrors() throws {
        let cat = ThemeStore.loadBuiltIn()
        var loader = ThemeLoader(available: cat.byID)
        func load(_ json: String) throws -> Theme { try loader.load(data: Data(json.utf8)) }

        XCTAssertThrowsError(try load(#"{"schema": 2, "id": "x", "name": "X", "appearance": "light"}"#)) { e in
            guard case ThemeError.unsupportedSchema(2) = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try load(#"{"schema": 1, "id": "Bad ID", "name": "X", "appearance": "light"}"#)) { e in
            guard case ThemeError.invalidID = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try load(#"{"schema": 1, "id": "x", "name": "X", "appearance": "light", "extends": "nope"}"#)) { e in
            guard case ThemeError.unknownParent("nope") = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try load(#"{"schema": 1, "id": "x", "name": "X", "appearance": "light", "extends": "paper"}"#)) { e in
            guard case ThemeError.nestedExtends = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try load(#"{"schema": 1, "id": "x", "name": "X", "appearance": "light", "colors": {"accent": "red"}}"#)) { e in
            guard case ThemeError.decoding(let m) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(m.contains("colors.accent"), m)
        }
        // 最小合法主题：缺失字段回退默认
        let t = try load(##"{"schema": 1, "id": "mini", "name": "Mini", "appearance": "dark", "colors": {"accent": "#ff0000"}}"##)
        XCTAssertEqual(t.colors.accent.hexString, "#ff0000")
        XCTAssertEqual(t.colors.background, cat.theme(id: "github-dark")!.colors.background)
        loader.available["mini"] = t
        let child = try load(#"{"schema": 1, "id": "mini-child", "name": "C", "appearance": "dark", "extends": "mini"}"#)
        XCTAssertEqual(child.colors.accent.hexString, "#ff0000")
    }

    func testUserDirectoryOverridesBuiltIn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quire-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ##"{"schema": 1, "id": "nord", "name": "Nord (mine)", "appearance": "dark", "extends": "github-dark", "colors": {"accent": "#123456"}}"##
            .write(to: dir.appendingPathComponent("nord.json"), atomically: true, encoding: .utf8)
        try "not json".write(to: dir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        let cat = ThemeStore.loadAll(userDirectory: dir)
        XCTAssertEqual(cat.theme(id: "nord")?.name, "Nord (mine)")
        XCTAssertEqual(cat.theme(id: "nord")?.colors.accent.hexString, "#123456")
        XCTAssertEqual(cat.errors.count, 1)
        XCTAssertTrue(cat.errors[0].path.hasSuffix("broken.json"))
    }
}

/// 成对主题（跟随系统在一对之间切）
final class ThemePairTests: XCTestCase {
    func testCounterpartBothDirectionsAndNotInherited() {
        let cat = ThemeStore.loadBuiltIn()
        let light = cat.theme(id: "github-light")!, dark = cat.theme(id: "github-dark")!
        XCTAssertEqual(light.pair, "github-dark")
        XCTAssertNil(dark.pair, "只需单向声明")
        XCTAssertEqual(cat.counterpart(of: light)?.id, "github-dark")
        XCTAssertEqual(cat.counterpart(of: dark)?.id, "github-light", "反向也认")
        // paper extends github-light：不继承搭档关系
        let paper = cat.theme(id: "paper")!
        XCTAssertNil(paper.pair)
        XCTAssertNil(cat.counterpart(of: paper))
        // 没有搭档的
        XCTAssertNil(cat.counterpart(of: cat.theme(id: "nord")!))
        XCTAssertEqual(cat.counterpart(of: cat.theme(id: "claude-light")!)?.id, "claude-dark")
        XCTAssertEqual(cat.counterpart(of: cat.theme(id: "claude-dark")!)?.id, "claude-light")
    }

    func testPairMustBeOppositeAppearance() throws {
        var loader = ThemeLoader(available: Dictionary(uniqueKeysWithValues: ThemeStore.loadBuiltIn().themes.map { ($0.id, $0) }))
        loader.defaults = [.light: "github-light", .dark: "github-dark"]
        let t = try loader.load(data: Data(#"{"schema":1,"id":"x-light","name":"X","appearance":"light","pair":"paper"}"#.utf8))
        let cat = ThemeCatalog(themes: ThemeStore.loadBuiltIn().themes + [t], errors: [])
        XCTAssertNil(cat.counterpart(of: t), "同外观的 pair 无效")
    }
}
