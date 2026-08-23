import AppKit
import QuireCore

/// 混合实时预览（spike #85）：在 ReaderTextView 上，**光标所在的顶级块显示源码并可编辑，其余块保持渲染**。
///
/// 模型（Obsidian Live Preview 式）：
/// - 文档源码是唯一真相。激活块 i = 用该块 `sourceRange` 覆盖的原始行替换渲染串里 `ranges[i]` 那段，切到可编辑。
/// - 编辑只允许落在激活块的范围内（`shouldChangeText` 拦），范围长度随编辑增减（textStorage 代理）。
/// - 每次击键把新源码回写给宿主（`onSourceEdit`，宿主更新文档源码用于保存 / 撤销，但**不重渲染**）；
///   离开块（点击别处 / Esc / ⌘↩）时宿主重解析整篇、按 diff 重渲染——一个块可能被拆成多个，交给解析器。
/// - 块级附件（表格 / Mermaid / 图片 / 数学）激活后就是它们的 Markdown 源码：不用另做"渲染态表格编辑"。
public final class HybridTextView: ReaderTextView, NSTextStorageDelegate {
    /// 开关：关着就是普通阅读视图
    public var isHybridEnabled = false { didSet { if !isHybridEnabled { deactivate(commit: true) } } }
    /// 文档源码（与 rendered 同步更新；激活块时从这里取原始行）
    public var source: String = ""
    /// 激活块的源码被编辑：(块下标, 该块新的源码行文本含末尾换行, 原行范围)
    public var onSourceEdit: ((Int, String, ClosedRange<Int>) -> Void)?
    /// 离开激活块（需要宿主重解析 + 重渲染）
    public var onDeactivate: (() -> Void)?

    public private(set) var activeBlock: Int?
    /// 激活块源码在 textStorage 里的范围（随编辑更新）
    public private(set) var activeRange = NSRange(location: 0, length: 0)
    /// 退出编辑后、宿主重渲染到达前，textStorage 里仍是源码态的块（重渲染时要先换回上一版渲染串，范围才对得上）
    private var staleSourceForm: (block: Int, range: NSRange)?
    private var activeLines: ClosedRange<Int> = 1...1
    private var suppressDelegate = false

    // MARK: 激活 / 退出

    /// 把块 i 切成源码态。返回 false = 没有源码位置（如 front matter 之外的合成块）
    @discardableResult
    public func activate(block i: Int, caretAt offsetInSource: Int? = nil) -> Bool {
        guard isHybridEnabled, let rendered, i < rendered.blocks.count, let ts = textStorage,
              let lines = rendered.blocks[i].block.sourceRange?.lineRange else { return false }
        if activeBlock == i { return true }
        deactivate(commit: true)
        // 若上一块还没被宿主重渲染（异步），这里的渲染串已经不是 rendered 的样子：先把它换回去再激活新块
        if let stale = staleSourceForm, let prev = self.rendered { restoreSourceForm(previous: prev); _ = stale; staleSourceForm = nil; rangeShift = (Int.max, 0) }
        guard let src = Self.sourceText(lines: lines, of: source) else { return false }
        let range = rendered.ranges[i]
        let attr = NSMutableAttributedString(attributedString: sourceAttributedString(src))
        let sourceLen = attr.length
        // 块级元素（表格 / 图片 / Mermaid / 数学 / 代码）：源码下面保留渲染预览（Typora 的做法），随编辑实时更新
        let showsPreview = Self.wantsPreview(rendered.blocks[i].block.kind)
        if showsPreview { attr.append(rendered.blocks[i].attributed) }
        suppressDelegate = true
        ts.beginEditing()
        ts.replaceCharacters(in: range, with: attr)
        ts.endEditing()
        suppressDelegate = false
        // 后续块的范围整体平移（rendered 是不可变值，这里只维护本视图的偏移表）
        shiftRanges(after: i, by: attr.length - range.length)
        activeBlock = i
        activeRange = NSRange(location: range.location, length: sourceLen)
        previewLength = showsPreview ? attr.length - sourceLen : 0
        activeLines = lines
        ts.delegate = self
        isEditable = true
        let caret = min(activeRange.location + (offsetInSource ?? 0), activeRange.location + max(0, activeRange.length - 1))
        setSelectedRange(NSRange(location: caret, length: 0))
        window?.makeFirstResponder(self)
        return true
    }

    /// 激活块下方预览的长度（0 = 无预览）
    private var previewLength = 0
    private var previewWork: DispatchWorkItem?
    /// 源码态 + 预览 的整段范围
    private var activeSpan: NSRange { NSRange(location: activeRange.location, length: activeRange.length + previewLength) }

    static func wantsPreview(_ kind: BlockKind) -> Bool {
        switch kind {
        case .table, .image, .mermaid, .math, .codeBlock, .html: return true
        default: return false
        }
    }

    /// 宿主提供：把一段源码渲染成块（用于实时预览）
    public var renderPreview: ((String) -> NSAttributedString?)?

    /// 编辑后 150 ms 刷新预览
    private func schedulePreviewRefresh() {
        guard previewLength > 0 || (activeBlock.map { wantsPreviewNow($0) } ?? false) else { return }
        previewWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refreshPreview() }
        previewWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }
    private func wantsPreviewNow(_ i: Int) -> Bool { rendered.map { i < $0.blocks.count && Self.wantsPreview($0.blocks[i].block.kind) } ?? false }

    private func refreshPreview() {
        guard activeBlock != nil, let ts = textStorage, let src = activeSource, let render = renderPreview, let preview = render(src) else { return }
        let old = NSRange(location: activeRange.location + activeRange.length, length: previewLength)
        guard old.location + old.length <= ts.length else { return }
        let sel = selectedRange()
        suppressDelegate = true
        ts.beginEditing()
        ts.replaceCharacters(in: old, with: preview)
        ts.endEditing()
        suppressDelegate = false
        shiftRanges(after: activeBlock!, by: preview.length - previewLength)
        previewLength = preview.length
        setSelectedRange(sel)
    }

    /// 退出源码态。commit = 把当前源码回写并让宿主重渲染
    public func deactivate(commit: Bool) {
        guard let i = activeBlock else { return }
        activeBlock = nil
        staleSourceForm = (i, activeSpan)
        previewWork?.cancel()
        isEditable = false
        textStorage?.delegate = nil
        if commit { onDeactivate?() }
    }

    /// 把仍处于源码态的块换回 `previous` 的渲染串（增量替换前调用）
    private func restoreSourceForm(previous: RenderedDocument) {
        let form: (block: Int, range: NSRange)? = activeBlock.map { ($0, activeSpan) } ?? staleSourceForm
        guard let form, let ts = textStorage, form.block < previous.blocks.count, form.range.location + form.range.length <= ts.length else { return }
        suppressDelegate = true
        ts.beginEditing()
        ts.replaceCharacters(in: form.range, with: previous.blocks[form.block].attributed)
        ts.endEditing()
        suppressDelegate = false
    }

    /// 宿主回写后更新激活块的行范围（块内新增 / 删除了行）
    public func activeLinesDidChange(to lines: ClosedRange<Int>) { activeLines = lines }

    /// 当前激活块的源码（含末尾换行）
    public var activeSource: String? {
        guard activeBlock != nil, let ts = textStorage, activeRange.location + activeRange.length <= ts.length else { return nil }
        return (ts.string as NSString).substring(with: activeRange)
    }

    // MARK: 编辑约束

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard activeBlock != nil else { return false }
        // 只能改激活块内部；允许在末尾（换行之前）追加
        let end = activeRange.location + max(0, activeRange.length - 1)
        guard affectedCharRange.location >= activeRange.location, affectedCharRange.location + affectedCharRange.length <= end else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    public nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        MainActor.assumeIsolated {
            guard !suppressDelegate, activeBlock != nil, editedMask.contains(.editedCharacters) else { return }
            activeRange.length += delta
            shiftRanges(after: activeBlock!, by: delta)
            if let i = activeBlock, let src = activeSource { onSourceEdit?(i, src, activeLines) }
            rehighlightSource()
            schedulePreviewRefresh()
        }
    }

    public override func keyDown(with event: NSEvent) {
        if let i = activeBlock {
            // Esc / ⌘↩ 退出源码态
            if event.keyCode == 53 || (event.keyCode == 36 && event.modifierFlags.contains(.command)) { deactivate(commit: true); return }
            // ↑ 在块首行 / ↓ 在块末行：切到相邻块（无修饰键、无选区时）
            let sel = selectedRange()
            if sel.length == 0, event.modifierFlags.intersection([.shift, .command, .option]).isEmpty, let rendered, let ns = textStorage?.string as NSString? {
                let src = ns.substring(with: activeRange)
                let rel = sel.location - activeRange.location
                let firstLineEnd = (src as NSString).range(of: "\n").location
                let lastLineStart = (src.dropLast() as NSString).range(of: "\n", options: .backwards).location
                if event.keyCode == 126, firstLineEnd == NSNotFound || rel <= firstLineEnd, i > 0 {   // ↑
                    deactivate(commit: true); activate(block: i - 1)
                    if activeBlock == i - 1 { setSelectedRange(NSRange(location: activeRange.location + max(0, activeRange.length - 1), length: 0)) }
                    return
                }
                if event.keyCode == 125, (lastLineStart == NSNotFound || rel > lastLineStart), i + 1 < rendered.blocks.count {   // ↓
                    deactivate(commit: true); activate(block: i + 1)
                    return
                }
            }
        }
        super.keyDown(with: event)
    }

    /// 渲染态里点击位置之前的文本 → 源码里的偏移：用前文末尾几个字符在源码里倒查；找不到就按比例
    static func sourceOffset(forRenderedPrefix prefix: String, in source: String) -> Int {
        let ns = source as NSString
        let clean = prefix.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{2009}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n")
        if clean.isEmpty { return 0 }
        for n in stride(from: min(12, clean.count), through: 2, by: -1) {
            let tail = String(clean.suffix(n))
            let r = ns.range(of: tail)
            if r.location != NSNotFound { return r.location + r.length }
        }
        return min(ns.length - 1, Int(Double(ns.length) * Double(clean.count) / Double(max(1, clean.count + 8))))
    }

    public override func mouseDown(with event: NSEvent) {
        guard isHybridEnabled, let rendered, let ts = textStorage else { return super.mouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        let idx = min(characterIndexForInsertion(at: p), max(0, ts.length - 1))
        if let i = blockIndex(atCharacter: idx) {
            if i == activeBlock { return super.mouseDown(with: event) }   // 块内点击：正常移动光标 / 选择
            // 点到别的块：记下点击处在渲染文本里的前文，激活后把光标放到源码里对应的位置
            let renderedRange = rendered.ranges[i]
            let renderedPrefix = (ts.string as NSString).substring(with: NSRange(location: renderedRange.location, length: max(0, min(idx - renderedRange.location, renderedRange.length))))
            deactivate(commit: true)
            activate(block: i)
            if activeBlock == i, let src = activeSource {
                setSelectedRange(NSRange(location: activeRange.location + Self.sourceOffset(forRenderedPrefix: renderedPrefix, in: src), length: 0))
            }
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: 范围维护

    /// 本视图的块范围表（激活后与 rendered.ranges 偏离）
    private var rangeShift: (after: Int, delta: Int) = (Int.max, 0)

    private func shiftRanges(after i: Int, by delta: Int) {
        if rangeShift.after == i { rangeShift.delta += delta } else { rangeShift = (i, delta) }
    }

    /// 字符位置 → 块下标（考虑激活块造成的偏移）
    func blockIndex(atCharacter c: Int) -> Int? {
        guard let rendered else { return nil }
        var loc = c
        if rangeShift.after != Int.max, let a = activeBlock {
            let start = rendered.ranges[a].location
            if loc >= start {
                if loc < start + activeSpan.length { return a }
                loc -= rangeShift.delta
            }
        }
        return rendered.blockIndex(at: loc)
    }

    public override func setRendered(_ doc: RenderedDocument, style: RenderStyle) {
        activeBlock = nil; staleSourceForm = nil; rangeShift = (Int.max, 0); isEditable = false; textStorage?.delegate = nil
        super.setRendered(doc, style: style)
    }

    public override func replaceBlocks(with doc: RenderedDocument, diff: BlockDiff, previous: RenderedDocument) {
        // 增量替换按 previous.ranges 定位；若有块还处于源码态（编辑中或刚退出），先把它换回上一版的渲染串，范围才对得上（否则留下残片）
        restoreSourceForm(previous: previous)
        activeBlock = nil; staleSourceForm = nil; rangeShift = (Int.max, 0); isEditable = false; textStorage?.delegate = nil
        super.replaceBlocks(with: doc, diff: diff, previous: previous)
    }

    // MARK: 源码外观

    static func sourceText(lines: ClosedRange<Int>, of source: String) -> String? {
        let all = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.lowerBound >= 1, lines.upperBound <= all.count else { return nil }
        return all[(lines.lowerBound - 1)...(lines.upperBound - 1)].joined(separator: "\n") + "\n"
    }

    private let lexer = MarkdownLexer()

    private func sourceAttributedString(_ src: String) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacing = 0
        ps.lineHeightMultiple = 1.3
        ps.headIndent = 8; ps.firstLineHeadIndent = 8
        let attrs: [NSAttributedString.Key: Any] = [
            .font: style.codeFont,
            .foregroundColor: style.foreground,
            .paragraphStyle: ps,
            QuireAttribute.blockRole: BlockRole.source.rawValue,
        ]
        let m = NSMutableAttributedString(string: src, attributes: attrs)
        highlightSource(m, offset: 0)
        return m
    }

    /// 用 MarkdownLexer 给源码着色（与源码编辑器同一套规则 / 颜色）
    private func highlightSource(_ m: NSMutableAttributedString, offset: Int) {
        var st = MarkdownLexer.State()
        let e = style.theme.colors.editor
        for t in lexer.tokenize(m.string, base: 0, state: &st) {
            let r = NSRange(location: offset + t.range.lowerBound, length: t.range.count)
            guard r.location + r.length <= m.length else { continue }
            let color: NSColor? = switch t.kind {
            case .marker, .tableDelim: e.markdownMarker.nsColor
            case .heading: e.markdownHeading.nsColor
            case .codeSpan, .codeBlock, .fenceInfo: e.markdownCode.nsColor
            case .linkText, .linkURL, .image: e.markdownLink.nsColor
            case .html, .frontMatter, .quote: style.muted
            case .footnote, .escape: style.accent
            default: nil
            }
            if let color { m.addAttribute(.foregroundColor, value: color, range: r) }
            if t.kind == .strong { m.addAttribute(.font, value: RenderStyle.variant(style.codeFont, traits: .boldFontMask), range: r) }
            if t.kind == .emphasis { m.addAttribute(.font, value: RenderStyle.variant(style.codeFont, traits: .italicFontMask), range: r) }
        }
    }

    /// 编辑后重新着色激活块（只改属性，不替换字符——替换会让光标跳到块尾）
    private func rehighlightSource() {
        guard let ts = textStorage, activeRange.location + activeRange.length <= ts.length else { return }
        suppressDelegate = true
        ts.beginEditing()
        ts.addAttributes([.foregroundColor: style.foreground, .font: style.codeFont], range: activeRange)
        let text = (ts.string as NSString).substring(with: activeRange)
        let m = NSMutableAttributedString(string: text)
        highlightSource(m, offset: 0)
        m.enumerateAttributes(in: NSRange(location: 0, length: m.length), options: []) { attrs, r, _ in
            var a: [NSAttributedString.Key: Any] = [:]
            if let c = attrs[.foregroundColor] { a[.foregroundColor] = c }
            if let f = attrs[.font] { a[.font] = f }
            if !a.isEmpty { ts.addAttributes(a, range: NSRange(location: activeRange.location + r.location, length: r.length)) }
        }
        ts.endEditing()
        suppressDelegate = false
    }
}
