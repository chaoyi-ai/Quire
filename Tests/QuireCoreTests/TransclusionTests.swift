import XCTest
@testable import QuireCore

final class TransclusionTests: XCTestCase {
    private func loader(_ files: [String: Transclusion.Content]) -> Transclusion.Loader {
        { target, _ in
            let t = target.hasSuffix(".md") || target.contains(".") ? target : target + ".md"
            guard let c = files[t] else { return nil }
            return ("/root/" + t, c)
        }
    }

    func testDirectiveDetection() {
        XCTAssertEqual(Transclusion.parse("![[a]]"), "a")
        XCTAssertEqual(Transclusion.parse("![[sub/a.md | 标题]]"), "sub/a.md")
        XCTAssertNil(Transclusion.parse("![[a]] tail"))
        XCTAssertNil(Transclusion.parse("![[]]"))
        XCTAssertNil(Transclusion.parse("![[a]] ![[b]]"))
        // 有 wikilinks 时段落是 `!` + link
        let doc = MarkdownParser().parse("![[chapter]]\n")
        guard case .paragraph(let inl) = doc.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(Transclusion.directive(in: inl), "chapter")
        XCTAssertNil(Transclusion.directive(in: [.text("hi "), .link(destination: "quire-wiki:x", title: nil, children: [])]))
    }

    func testMarkdownExpansionKeepsDirectiveRange() {
        let p = MarkdownParser()
        let doc = p.parse("# 书\n\n![[ch1]]\n\n尾声\n")
        let r = Transclusion.expand(doc, parser: p, fromPath: "/root/book.md", loader: loader(["ch1.md": .markdown("---\ntitle: x\n---\n## 第一章\n\n正文\n")]))
        XCTAssertEqual(r.includedPaths, ["/root/ch1.md"])
        XCTAssertEqual(r.document.blocks.count, 4)   // 书 / 第一章 / 正文 / 尾声（front matter 不显示）
        guard case .heading(2, _, _) = r.document.blocks[1].kind else { return XCTFail("\(r.document.blocks[1].kind)") }
        XCTAssertEqual(r.document.blocks[1].sourceRange?.start.line, 3)
        XCTAssertEqual(r.document.blocks[2].sourceRange?.start.line, 3)
        XCTAssertEqual(r.document.outline.entries.map(\.title), ["书", "第一章"])
        XCTAssertEqual(r.document.outline.entries[1].blockIndex, 1)
    }

    func testCycleAndDepthGuard() {
        let p = MarkdownParser()
        let files: [String: Transclusion.Content] = ["a.md": .markdown("A\n\n![[b]]\n"), "b.md": .markdown("B\n\n![[a]]\n")]
        let r = Transclusion.expand(p.parse("![[a]]\n"), parser: p, fromPath: "/root/main.md", loader: loader(files))
        let text = r.document.blocks.map { b -> String in if case .paragraph(let i) = b.kind { return i.plainText } else { return "" } }
        XCTAssertEqual(text[0], "A"); XCTAssertEqual(text[1], "B")
        XCTAssertTrue(text[2].contains("循环包含"), text[2])
        // 自包含
        let r2 = Transclusion.expand(p.parse("![[main]]\n"), parser: p, fromPath: "/root/main.md", loader: loader(["main.md": .markdown("x")]))
        if case .paragraph(let i) = r2.document.blocks[0].kind { XCTAssertTrue(i.plainText.contains("循环包含")) } else { XCTFail() }
        // 深度
        let deep: [String: Transclusion.Content] = Dictionary(uniqueKeysWithValues: (0..<10).map { ("d\($0).md", .markdown("![[d\($0 + 1)]]\n")) })
        let r3 = Transclusion.expand(p.parse("![[d0]]\n"), parser: p, fromPath: nil, loader: loader(deep))
        XCTAssertEqual(r3.document.blocks.count, 1)
        if case .paragraph(let i) = r3.document.blocks[0].kind { XCTAssertTrue(i.plainText.contains("嵌套太深")) } else { XCTFail() }
    }

    func testMissingAndUnavailable() {
        let p = MarkdownParser()
        let r = Transclusion.expand(p.parse("![[nope]]\n\n![[big]]\n"), parser: p, fromPath: nil, loader: loader(["big.md": .unavailable("太大")]))
        XCTAssertEqual(r.document.blocks.count, 2)
        if case .paragraph(let i) = r.document.blocks[0].kind { XCTAssertTrue(i.plainText.contains("找不到 nope")) } else { XCTFail() }
        if case .paragraph(let i) = r.document.blocks[1].kind { XCTAssertTrue(i.plainText.contains("太大")) } else { XCTFail() }
        XCTAssertTrue(r.includedPaths.contains("/root/big.md"))
    }

    func testNoDirectiveIsIdentity() {
        let p = MarkdownParser()
        let doc = p.parse("# a\n\nb ![[c]] d\n")
        let r = Transclusion.expand(doc, parser: p, fromPath: nil, loader: { _, _ in nil })
        XCTAssertEqual(r.document.blocks, doc.blocks)
        XCTAssertTrue(r.includedPaths.isEmpty)
    }

    func testCSVAndImage() {
        let p = MarkdownParser()
        let csv = "name,qty,note\n\"Smith, J\",3,\"say \"\"hi\"\"\"\nLee,12,\n"
        let r = Transclusion.expand(p.parse("![[data.csv]]\n\n![[pic.png]]\n"), parser: p, fromPath: nil,
                                    loader: loader(["data.csv": .csv(csv), "pic.png": .image(path: "/root/pic.png", alt: "pic")]))
        guard case .table(let t) = r.document.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(t.header.map(\.plainText), ["name", "qty", "note"])
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.rows[0].map(\.plainText), ["Smith, J", "3", "say \"hi\""])
        XCTAssertEqual(t.rows[1].map(\.plainText), ["Lee", "12", ""])
        XCTAssertEqual(t.alignments, [.none, .right, .none])
        guard case .image(let src, _, let alt) = r.document.blocks[1].kind else { return XCTFail() }
        XCTAssertEqual(src, "/root/pic.png"); XCTAssertEqual(alt, "pic")
    }

    func testIncludedImagesRebaseToTheirOwnDirectory() {
        let p = MarkdownParser()
        let r = Transclusion.expand(p.parse("![[sub/ch]]\n"), parser: p, fromPath: "/root/main.md",
                                    loader: { _, _ in ("/root/sub/ch.md", .markdown("![fig](img/a.png)\n\n看 ![b](../b.png) 与 ![c](https://x/c.png)\n")) })
        guard case .image(let s, _, _) = r.document.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(s, "/root/sub/img/a.png")
        guard case .paragraph(let i) = r.document.blocks[1].kind, case .image(let b, _, _) = i[1], case .image(let c, _, _) = i[3] else { return XCTFail("\(r.document.blocks[1].kind)") }
        XCTAssertEqual(b, "/root/b.png"); XCTAssertEqual(c, "https://x/c.png")
    }

    func testTSV() {
        let rows = CSV.rows("a\tb\n1\t2\r\n3\t4")
        XCTAssertEqual(rows, [["a", "b"], ["1", "2"], ["3", "4"]])
    }
}
