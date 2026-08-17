import XCTest
import AppKit
@testable import QuireRender
@testable import QuireCore

@MainActor
final class InlineCodeGeometryTests: XCTestCase {
    func testMeasuredBoxMatchesRunWidth() {
        let style = RenderStyle(theme: ThemeStore.loadBuiltIn().theme(id: "github-light")!)
        let reader = ReaderTextView(style: style)
        reader.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let doc = MarkdownParser().parse("这是一个 粗体、`行内代码` 和 链接 的段落。\n")
        reader.setRendered(DocumentRenderer(style: style).render(doc), style: style)
        let tlm = reader.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        var frag: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { f in frag = f; return false }
        let f = try! XCTUnwrap(frag)
        let para = (f.textElement as! NSTextParagraph).attributedString
        var runRange = NSRange()
        var found = false
        para.enumerateAttribute(QuireAttribute.inlineCode, in: NSRange(location: 0, length: para.length), options: []) { v, r, stop in
            if v as? Bool == true { runRange = r; found = true; stop.pointee = true }
        }
        XCTAssertTrue(found)
        let lf = f.textLineFragments[0]
        let x0 = lf.locationForCharacter(at: runRange.location).x
        let x1 = lf.locationForCharacter(at: runRange.location + runRange.length).x
        let runText = para.attributedSubstring(from: runRange)
        let expected = runText.size().width
        print("x0=\(x0) x1=\(x1) measured=\(x1 - x0) expectedRunWidth=\(expected) runText=\(runText.string.debugDescription)")
        // 左右各两个正文窄空格：框宽应≈run 宽度（回退字体不再撑宽尾部）
        XCTAssertEqual(x1 - x0, expected, accuracy: 2, "框宽与 run 宽不一致")
        // 左右留白对称：首个内容字符到 x0 的距离 == x1 到最后内容字符结束的距离
        let leftPad = lf.locationForCharacter(at: runRange.location + 3).x - x0
        let rightPad = x1 - lf.locationForCharacter(at: runRange.location + runRange.length - 3).x
        XCTAssertEqual(leftPad, rightPad, accuracy: 1.5, "左右留白不对称 left=\(leftPad) right=\(rightPad)")
        // 检查 run 的前后字符位置：前一个字符结束 == x0，后一个字符开始 == x1
        let before = lf.locationForCharacter(at: runRange.location - 1).x
        let after = lf.locationForCharacter(at: runRange.location + runRange.length + 1).x
        print("prevCharX=\(before) nextCharX=\(after)")
        for i in (runRange.location - 1)...(runRange.location + runRange.length + 1) {
            let ch = (para.string as NSString).substring(with: NSRange(location: i, length: 1))
            print("  idx \(i) \(ch.debugDescription) x=\(lf.locationForCharacter(at: i).x)")
        }
        let inner = para.attributedSubstring(from: NSRange(location: runRange.location + 1, length: runRange.length - 2))
        print("innerWidth=\(inner.size().width) thinSpaceWidth=\(para.attributedSubstring(from: NSRange(location: runRange.location, length: 1)).size().width)")
    }
}
