import Foundation
import AppKit
import QuireCore
import QuireRender

// quire-bench：性能基准 CLI。输出 JSON 到 stdout，人类可读摘要到 stderr。
// 用法：quire-bench [all|parse|highlight|themes|render|full|theme|incremental|views|gen <dir>] [--iterations N]

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "all"
var iterations = 5
if let i = args.firstIndex(of: "--iterations"), i + 1 < args.count, let n = Int(args[i + 1]) { iterations = n }

struct Result: Encodable {
    var name: String
    var bytes: Int
    var medianMs: Double
    var minMs: Double
    var throughputMBps: Double
    var note: String?
}
var results: [Result] = []

@MainActor @discardableResult
func measure(_ name: String, bytes: Int, note: String? = nil, _ body: () -> Void) -> Result {
    var times: [Double] = []
    body() // 预热
    for _ in 0..<iterations {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        times.append(Double(t1 - t0) / 1_000_000)
    }
    times.sort()
    let median = times[times.count / 2]
    let r = Result(name: name, bytes: bytes, medianMs: median, minMs: times[0], throughputMBps: Double(bytes) / 1_048_576 / (median / 1000), note: note)
    results.append(r)
    FileHandle.standardError.write("\(name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(String(format: "%8.2f ms", median))  (min \(String(format: "%.2f", times[0])))  \(String(format: "%.1f MB/s", r.throughputMBps))\n".data(using: .utf8)!)
    return r
}

let large = FixtureGenerator.mixed(targetBytes: 1_048_576)
let medium = FixtureGenerator.mixed(targetBytes: 200 * 1024, seedOffset: 7)
let small = FixtureGenerator.mixed(targetBytes: 20 * 1024, seedOffset: 3)
let codeHeavy = FixtureGenerator.codeHeavy(targetBytes: 500 * 1024)
let tableHeavy = FixtureGenerator.tableHeavy(targetBytes: 200 * 1024)

let parser = MarkdownParser()
let highlighter = SyntaxHighlighter()

@MainActor func runParse() {
    measure("parse/large-1mb", bytes: large.utf8.count) { _ = parser.parse(large) }
    measure("parse/medium-200k", bytes: medium.utf8.count) { _ = parser.parse(medium) }
    measure("parse/small-20k", bytes: small.utf8.count) { _ = parser.parse(small) }
    measure("parse/table-heavy", bytes: tableHeavy.utf8.count) { _ = parser.parse(tableHeavy) }
}

@MainActor func runHighlight() {
    let sw = String(repeating: FixtureGenerator.codeSwift + "\n", count: 800)
    let js = String(repeating: FixtureGenerator.codeJS + "\n", count: 1200)
    let py = String(repeating: FixtureGenerator.codePy + "\n", count: 1200)
    let json = String(repeating: FixtureGenerator.codeJSON + "\n", count: 2000)
    measure("highlight/swift", bytes: sw.utf8.count) { _ = highlighter.highlight(sw, language: "swift") }
    measure("highlight/javascript", bytes: js.utf8.count) { _ = highlighter.highlight(js, language: "javascript") }
    measure("highlight/python", bytes: py.utf8.count) { _ = highlighter.highlight(py, language: "python") }
    measure("highlight/json", bytes: json.utf8.count) { _ = highlighter.highlight(json, language: "json") }
    // 整份 code-heavy 文档：解析 + 全部代码块高亮
    measure("highlight/code-heavy-doc", bytes: codeHeavy.utf8.count) {
        let doc = parser.parse(codeHeavy)
        for b in doc.blocks { if case .codeBlock(let l, let c) = b.kind { _ = highlighter.highlight(c, language: l) } }
    }
}

@MainActor func runThemes() {
    measure("themes/load-builtin", bytes: 0) { _ = ThemeStore.loadBuiltIn() }
}

@MainActor
func runRender() {
    let catalog = ThemeStore.loadBuiltIn()
    guard let light = catalog.theme(id: "github-light"), let dark = catalog.theme(id: "github-dark") else {
        FileHandle.standardError.write("主题缺失，跳过 render\n".data(using: .utf8)!); return
    }
    let doc = parser.parse(large)
    measure("stats/large-1mb", bytes: large.utf8.count) { _ = TextStats.compute(large) }
    let renderer = DocumentRenderer(theme: light)
    measure("render/large-1mb", bytes: large.utf8.count) { _ = renderer.render(doc) }
    // 数学：200 个公式（一半块级一半行内）的解析 + 渲染，SwiftMath 缓存每轮清不掉 → 用不同字号绕开缓存不现实，这里测的是缓存命中后的装配成本 + 首轮真实渲染
    let mathDoc = (0..<100).map { i in "段落 \(i) 行内 $x_{\(i)}^2 + \\frac{a}{b}$ 公式\n\n$$\n\\int_0^{\(i)} e^{-t}\\,dt = 1 - e^{-\(i)}\n$$\n" }.joined(separator: "\n")
    let mathParsed = parser.parse(mathDoc)
    // 冷渲染：每次用没见过的公式（带轮次编号），SwiftMath 缓存命不中，测的是真实的公式渲染成本
    var round = 0
    measure("render/math-200-cold", bytes: mathDoc.utf8.count) {
        round += 1
        let fresh = (0..<100).map { i in "段落 \(i) 行内 $y_{\(i)}^{\(round)} + \\frac{\(round)}{b}$ 公式\n\n$$\n\\int_0^{\(i)} e^{-\(round)t}\\,dt = 1 - e^{-\(i)}\n$$\n" }.joined(separator: "\n")
        _ = renderer.render(parser.parse(fresh))
    }
    measure("render/math-200", bytes: mathDoc.utf8.count) { _ = renderer.render(mathParsed) }
    measure("full/large-1mb (parse+render)", bytes: large.utf8.count) { _ = renderer.render(parser.parse(large)) }
    let docMedium = parser.parse(medium)
    measure("full/medium-200k", bytes: medium.utf8.count) { _ = renderer.render(parser.parse(medium)) }
    _ = docMedium
    // 主题切换：不重解析，重渲染
    let darkRenderer = DocumentRenderer(theme: dark)
    measure("theme/switch-large-1mb", bytes: large.utf8.count) { _ = darkRenderer.render(doc) }   // 主题切换 = 同一 Document 换 style 全量重建
    // 增量：改中间一段
    var lines = large.components(separatedBy: "\n")
    lines[lines.count / 2] += " 修改"
    let edited = lines.joined(separator: "\n")
    let editedDoc = parser.parse(edited)
    measure("incremental/edit-middle-1mb", bytes: large.utf8.count) {
        let diff = BlockDiff.compute(old: doc.blocks, new: editedDoc.blocks)
        _ = renderer.render(blocks: Array(editedDoc.blocks[diff.newChanged]))
    }
}

/// 视图层：ReaderTextView.setRendered（含附件扫描）、EditorTextView 单次按键路径（行索引重建 + 段落增量高亮）
@MainActor
func runViews() {
    let catalog = ThemeStore.loadBuiltIn()
    guard let light = catalog.theme(id: "github-light") else { return }
    let style = RenderStyle(theme: light)
    let doc = parser.parse(large)
    let rendered = DocumentRenderer(style: style).render(doc)
    // 与 app 一致：放在 NSScrollView 里（TextKit 2 只布局视口；不放滚动视图会全量布局）
    let reader = ReaderTextView(style: style)
    let readerScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    readerScroll.documentView = reader
    reader.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    measure("view/reader-setRendered-1mb", bytes: large.utf8.count) {
        reader.setRendered(rendered, style: style)
        reader.textLayoutManager?.textViewportLayoutController.layoutViewport()   // 首屏布局
    }
    let editor = EditorTextView(style: style)
    let editorScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    editorScroll.documentView = editor
    editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    editor.setSource(large)
    let mid = (large as NSString).length / 2
    let lineStart = (large as NSString).range(of: "\n", options: [], range: NSRange(location: mid, length: (large as NSString).length - mid)).location + 1
    var toggle = false
    measure("view/editor-keystroke-1mb", bytes: large.utf8.count) {
        // 交替插入/删除一个字符，保持文档不变
        if toggle { editor.insertText("", replacementRange: NSRange(location: lineStart, length: 1)) }
        else { editor.insertText("x", replacementRange: NSRange(location: lineStart, length: 0)) }
        toggle.toggle()
    }
    if toggle { editor.insertText("", replacementRange: NSRange(location: lineStart, length: 1)) }
    // 专注（句子淡化）开着时的击键：渲染属性整篇重设
    editor.setSelectedRange(NSRange(location: lineStart, length: 0))
    editor.focusMode = .sentence
    measure("view/editor-keystroke-focus-1mb", bytes: large.utf8.count) {
        if toggle { editor.insertText("", replacementRange: NSRange(location: lineStart, length: 1)) }
        else { editor.insertText("x", replacementRange: NSRange(location: lineStart, length: 0)) }
        toggle.toggle()
    }
    if toggle { editor.insertText("", replacementRange: NSRange(location: lineStart, length: 1)) }
    editor.focusMode = .off
}

func generate(to dir: String) throws {
    let base = URL(fileURLWithPath: dir)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try large.write(to: base.appendingPathComponent("large-1mb.md"), atomically: true, encoding: .utf8)
    try medium.write(to: base.appendingPathComponent("medium.md"), atomically: true, encoding: .utf8)
    try codeHeavy.write(to: base.appendingPathComponent("code-heavy.md"), atomically: true, encoding: .utf8)
    try tableHeavy.write(to: base.appendingPathComponent("table-heavy.md"), atomically: true, encoding: .utf8)
    try FixtureGenerator.mermaidDoc(count: 20).write(to: base.appendingPathComponent("mermaid.md"), atomically: true, encoding: .utf8)
    FileHandle.standardError.write("✓ 已生成到 \(dir)\n".data(using: .utf8)!)
}

switch command {
case "parse": runParse()
case "highlight": runHighlight()
case "themes": runThemes()
case "render", "full", "theme", "incremental": runRender()
case "views": runViews()
case "gen":
    let dir = args.count > 1 ? args[1] : "Tests/QuireCoreTests/Fixtures"
    try generate(to: dir)
    exit(0)
case "all":
    runParse(); runHighlight(); runThemes(); runRender(); runViews()
default:
    FileHandle.standardError.write("未知命令 \(command)\n".data(using: .utf8)!); exit(2)
}

let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
let out = try enc.encode(["iterations": AnyEncodable(iterations), "results": AnyEncodable(results)])
print(String(decoding: out, as: UTF8.self))

struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ v: any Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
