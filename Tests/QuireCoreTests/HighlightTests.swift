import XCTest
@testable import QuireCore

final class HighlightTests: XCTestCase {
    let hl = SyntaxHighlighter()

    /// 断言 `code` 里 `snippet` 的第一次出现被着色为 `kind`
    func assertKind(_ code: String, _ snippet: String, _ kind: TokenKind, language: String, file: StaticString = #filePath, line: UInt = #line) {
        let tokens = hl.highlight(code, language: language)
        let ns = code as NSString
        let r = ns.range(of: snippet)
        XCTAssertNotEqual(r.location, NSNotFound, "snippet 不在 code 中", file: file, line: line)
        let hit = tokens.first { $0.range.lowerBound <= r.location && $0.range.upperBound >= r.location + r.length && $0.kind == kind }
        XCTAssertNotNil(hit, "[\(language)] 「\(snippet)」应为 \(kind)，实际：\(tokens.filter { $0.range.overlaps(r.location..<(r.location + r.length)) }.map { "\($0.kind)@\($0.range)" })", file: file, line: line)
    }

    func testAliasesAndInfoStrings() {
        XCTAssertTrue(hl.supports("js"))
        XCTAssertTrue(hl.supports("Swift"))
        XCTAssertTrue(hl.supports("swift title=\"x\""))
        XCTAssertTrue(hl.supports("c++"))
        XCTAssertFalse(hl.supports(nil))
        XCTAssertFalse(hl.supports("brainfuck-not-supported"))
        XCTAssertEqual(hl.registry.canonicalName("YML"), "yaml")
    }

    func testSwift() {
        let code = """
        import Foundation
        /// doc
        @MainActor final class Foo: Bar { // trailing
            let x: Int = 0x1F; var s = "str \\(x) \\n"
            func run() async throws -> [String] { return try await fetch(42) }
        }
        /* block /* nested */ still comment */
        """
        assertKind(code, "import", .keyword, language: "swift")
        assertKind(code, "/// doc", .comment, language: "swift")
        assertKind(code, "@MainActor", .attribute, language: "swift")
        assertKind(code, "Foo", .type, language: "swift")
        assertKind(code, "Int", .type, language: "swift")
        assertKind(code, "0x1F", .number, language: "swift")
        assertKind(code, "\"str \\(x) \\n\"", .string, language: "swift")
        assertKind(code, "\\n", .escape, language: "swift")
        assertKind(code, "fetch", .function, language: "swift")
        assertKind(code, "// trailing", .comment, language: "swift")
        assertKind(code, "still comment */", .comment, language: "swift")
    }

    func testJavaScriptTypeScript() {
        let code = "const re = /ab+c/gi; let t = `x ${y}`; async function f(a) { return await go(a) ?? null } // c"
        assertKind(code, "const", .keyword, language: "js")
        assertKind(code, "/ab+c/gi", .regexp, language: "js")
        assertKind(code, "`x ${y}`", .string, language: "js")
        assertKind(code, "null", .constant, language: "js")
        assertKind(code, "go", .function, language: "js")
        assertKind("interface A { x: number }", "interface", .keyword, language: "ts")
        assertKind("interface A { x: number }", "number", .type, language: "ts")
        assertKind("a / b / c", "/", .operator, language: "js") // 除号不是正则
    }

    func testPython() {
        let code = "@dataclass\nclass P:\n    def f(self) -> None:\n        return f\"x{1}\" # c\n'''doc'''\nprint(True)"
        assertKind(code, "@dataclass", .attribute, language: "python")
        assertKind(code, "def", .keyword, language: "py")
        assertKind(code, "None", .constant, language: "python")
        assertKind(code, "f\"x{1}\"", .string, language: "python")
        assertKind(code, "# c", .comment, language: "python")
        assertKind(code, "'''doc'''", .string, language: "python")
        assertKind(code, "print", .function, language: "python")
    }

    func testBashCGoRust() {
        assertKind("#!/bin/bash\nfor f in $HOME/*.md; do echo \"$f\" ; done # x", "for", .keyword, language: "bash")
        assertKind("for f in $HOME/*.md; do echo \"$f\" ; done # x", "$HOME", .variable, language: "sh")
        assertKind("for f in $HOME/*.md; do echo \"$f\" ; done # x", "# x", .comment, language: "sh")
        assertKind("#include <stdio.h>\nint main(void) { return 0; }", "#include <stdio.h>", .meta, language: "c")
        assertKind("int main(void) { return 0; }", "int", .type, language: "c")
        assertKind("std::vector<int> v; auto p = nullptr;", "nullptr", .constant, language: "cpp")
        assertKind("func main() { fmt.Println(`raw`) }", "`raw`", .string, language: "go")
        assertKind("fn main<'a>(x: &'a str) -> Option<u32> { let s = r\"raw\"; }", "'a", .attribute, language: "rust")
        assertKind("fn main() -> Option<u32> {}", "Option", .type, language: "rust")
        assertKind("fn main() { let s = r\"raw\"; }", "r\"raw\"", .string, language: "rust")
    }

    func testSQL() {
        assertKind("SELECT count(*) FROM users WHERE id = 1 -- c", "SELECT", .keyword, language: "sql")
        assertKind("SELECT count(*) FROM users WHERE id = 1 -- c", "count", .function, language: "sql")
        assertKind("SELECT count(*) FROM users WHERE id = 1 -- c", "-- c", .comment, language: "sql")
    }

    func testJSON() {
        let code = "{\"key\": \"value\", \"n\": -1.5e3, \"b\": true, \"z\": null, \"bad\": nope}"
        assertKind(code, "\"key\"", .attribute, language: "json")
        assertKind(code, "\"value\"", .string, language: "json")
        assertKind(code, "-1.5e3", .number, language: "json")
        assertKind(code, "true", .constant, language: "json")
        assertKind(code, "nope", .invalid, language: "json")
    }

    func testHTML() {
        let code = "<!DOCTYPE html>\n<!-- c --><div class=\"a\" id='b' data-x>text</div><script>let x = 1;</script>"
        assertKind(code, "<!DOCTYPE html>", .meta, language: "html")
        assertKind(code, "<!-- c -->", .comment, language: "html")
        assertKind(code, "div", .tag, language: "html")
        assertKind(code, "class", .attribute, language: "html")
        assertKind(code, "\"a\"", .string, language: "html")
        assertKind(code, "let", .keyword, language: "html")
        assertKind("<a:b xmlns:a=\"u\"/>", "a:b", .tag, language: "xml")
    }

    func testCSS() {
        let code = ".card:hover > h1 { color: #fff; margin: 1.5rem 0 !important; --gap: 4px; width: calc(100% - 2px) } /* c */"
        assertKind(code, ".card", .type, language: "css")
        assertKind(code, ":hover", .attribute, language: "css")
        assertKind(code, "h1", .tag, language: "css")
        assertKind(code, "color", .attribute, language: "css")
        assertKind(code, "#fff", .number, language: "css")
        assertKind(code, "1.5rem", .number, language: "css")
        assertKind(code, "!important", .keyword, language: "css")
        assertKind(code, "--gap", .variable, language: "css")
        assertKind(code, "calc", .function, language: "css")
        assertKind(code, "/* c */", .comment, language: "css")
    }

    func testYAMLTOML() {
        let y = "# c\nname: Quire\nversion: 1.2\nlist:\n  - a\n  - \"b\" # t\nok: true\nanchor: &x 1\n---\n"
        assertKind(y, "# c", .comment, language: "yaml")
        assertKind(y, "name", .attribute, language: "yaml")
        assertKind(y, "Quire", .string, language: "yml")
        assertKind(y, "1.2", .number, language: "yaml")
        assertKind(y, "\"b\"", .string, language: "yaml")
        assertKind(y, "# t", .comment, language: "yaml")
        assertKind(y, "true", .constant, language: "yaml")
        assertKind(y, "&x", .meta, language: "yaml")
        let t = "[package]\nname = \"quire\" # c\nver = 1.0\nflag = true\nlist = [1, 2]"
        assertKind(t, "[package]", .tag, language: "toml")
        assertKind(t, "name", .attribute, language: "toml")
        assertKind(t, "\"quire\"", .string, language: "toml")
        assertKind(t, "# c", .comment, language: "toml")
        assertKind(t, "1.0", .number, language: "toml")
        assertKind(t, "true", .constant, language: "toml")
    }

    func testMarkdownAndDiff() {
        let md = "# Title\n- item **bold** `code` [l](u)\n```\nfence\n```\n"
        assertKind(md, "# Title", .tag, language: "md")
        assertKind(md, "`code`", .string, language: "markdown")
        assertKind(md, "[l]", .attribute, language: "markdown")
        assertKind(md, "fence", .string, language: "markdown")
        let d = "--- a\n+++ b\n@@ -1,2 +1,2 @@\n-old\n+new\n ctx"
        assertKind(d, "-old", .invalid, language: "diff")
        assertKind(d, "+new", .string, language: "diff")
        assertKind(d, "@@ -1,2 +1,2 @@", .number, language: "diff")
        assertKind(d, "+++ b", .meta, language: "patch")
    }

    func testNonASCIIOffsetsAreUTF16() {
        let code = "let 名字 = \"你好\" // 注释"
        let tokens = hl.highlight(code, language: "swift")
        let ns = code as NSString
        let str = tokens.first { $0.kind == .string }!
        XCTAssertEqual(ns.substring(with: NSRange(location: str.range.lowerBound, length: str.range.count)), "\"你好\"")
        let cmt = tokens.first { $0.kind == .comment }!
        XCTAssertEqual(ns.substring(with: NSRange(location: cmt.range.lowerBound, length: cmt.range.count)), "// 注释")
        // emoji（UTF-16 代理对）
        let e = "let s = \"😀\"; let n = 1"
        let t2 = hl.highlight(e, language: "swift")
        let num = t2.first { $0.kind == .number }!
        XCTAssertEqual((e as NSString).substring(with: NSRange(location: num.range.lowerBound, length: num.range.count)), "1")
    }

    func testAllLanguagesTokenizeWithoutCrash() {
        let sample = "func main() { let x = \"s\" + 'c' + `t` + 1.5e3; // c\n/* b */ # p\n@a $v <t a=\"1\"> {k: v} [1,2] -- x }"
        for name in hl.registry.languageNames {
            _ = hl.highlight(sample, language: name)
            _ = hl.highlight("", language: name)
            _ = hl.highlight("\"unterminated", language: name)
        }
    }

    func testThroughput() throws {
        // 粗略吞吐（Debug 构建下也应远高于 2 MB/s；Release 目标 > 20 MB/s）
        let unit = "func f(a: Int) -> String { return \"\\(a)\" } // comment\nlet x = [1, 2, 3].map { $0 * 2 }\n"
        let code = String(repeating: unit, count: 5000) // ~450 KB
        let t0 = Date()
        let tokens = hl.highlight(code, language: "swift")
        let dt = Date().timeIntervalSince(t0)
        XCTAssertGreaterThan(tokens.count, 10000)
        XCTAssertLessThan(dt, 2.0, "450KB swift 高亮耗时 \(dt)s")
    }
}
