import XCTest
@testable import QuireCore

final class HTMLToMarkdownTests: XCTestCase {
    func testBasics() {
        let html = "<h1>Title</h1><p>Hello <strong>bold</strong> and <em>it</em> <code>x</code> <a href=\"https://a.b\">link</a>.</p>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), "# Title\n\nHello **bold** and *it* `x` [link](https://a.b).\n")
    }
    func testListsNested() {
        let html = "<ul><li>one</li><li>two<ul><li>deep</li></ul></li></ul><ol start=\"3\"><li>three</li><li>four</li></ol>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), "- one\n- two\n  - deep\n\n3. three\n4. four\n")
    }
    func testPreAndQuote() {
        let html = "<pre><code class=\"language-swift\">let a = 1\nprint(a)</code></pre><blockquote><p>quoted</p></blockquote>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), "```swift\nlet a = 1\nprint(a)\n```\n\n> quoted\n")
    }
    func testTableAndImage() {
        let html = "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>x|y</td></tr></tbody></table><p><img src=\"a.png\" alt=\"pic\"></p>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), "| A | B |\n| --- | --- |\n| 1 | x\\|y |\n\n![pic](a.png)\n")
    }
    func testMessyBrowserHTML() {
        let html = "<html><head><style>p{}</style><meta charset=\"utf-8\"></head><body><div class=\"x\"><span style=\"color:red\">Red</span>\n   text<br>next</div><script>alert(1)</script></body></html>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), "Red text  \nnext\n")
    }
    func testPlainTextPassthrough() {
        XCTAssertEqual(HTMLToMarkdown.convert("just text").trimmingCharacters(in: .newlines), "just text")
    }
}
