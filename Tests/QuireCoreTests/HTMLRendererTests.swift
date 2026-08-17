import XCTest
@testable import QuireCore

final class HTMLRendererTests: XCTestCase {
    func testRendersAllBlockKinds() throws {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-dark")!
        let src = try String(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "small", withExtension: "md", subdirectory: "Fixtures")), encoding: .utf8)
        let doc = MarkdownParser().parse(src)
        var opts = HTMLRenderer.Options(); opts.title = "T <x>"
        let html = HTMLRenderer(theme: theme, options: opts).render(doc)
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<title>T &lt;x&gt;</title>"))
        XCTAssertTrue(html.contains("background:#0d1117"))              // 主题色内联
        XCTAssertTrue(html.contains("<h1 id=\"quire-示例文档\">"))
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked>"))
        XCTAssertTrue(html.contains("<span class=\"tok-keyword\">import</span>"))
        XCTAssertTrue(html.contains("<pre class=\"mermaid\">graph TD"))
        XCTAssertTrue(html.contains("mermaid.esm.min.mjs"))
        XCTAssertTrue(html.contains("<th style=\"text-align:center\">"))
        XCTAssertTrue(html.contains("<figure><img src=\"https://example.com/a.png\""))
        XCTAssertTrue(html.contains("<del>删除线</del>"))
        XCTAssertTrue(html.contains("<a href=\"https://github.com/chaoyi-ai/Quire\">"))
        XCTAssertFalse(html.contains("<script src"))  // 除 mermaid 外无外链脚本
    }

    func testEscaping() {
        let theme = ThemeStore.loadBuiltIn().theme(id: "github-light")!
        let html = HTMLRenderer(theme: theme).render(MarkdownParser().parse("a < b & `x > y`\n"))
        XCTAssertTrue(html.contains("a &lt; b &amp; <code>x &gt; y</code>"))
    }
}
