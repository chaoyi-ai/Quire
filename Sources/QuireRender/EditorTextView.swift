import AppKit
import QuireCore
import CQuireAttr

/// Markdown 源码编辑器（TextKit 2）：增量高亮、行号、当前行高亮、软换行、输入辅助。
@MainActor
public final class EditorTextView: NSTextView, NSTextStorageDelegate {
    public private(set) var style: RenderStyle
    private let lexer = MarkdownLexer()
    private var attrsCache: [MarkdownLexer.Kind: AnyObject] = [:]
    private var baseAttrs: AnyObject!
    private var boldFont: NSFont!, italicFont: NSFont!, boldItalicFont: NSFont!, editorFont: NSFont!
    private var lineStarts: [Int] = [0]     // 每行起始 UTF-16 偏移
    private var isHighlighting = false
    /// 文本变化回调（编辑器 → 文档）
    public var onTextChange: (() -> Void)?
    /// 是否显示行号
    public var showsLineNumbers = true { didSet { enclosingScrollView?.rulersVisible = showsLineNumbers } }

    public init(style: RenderStyle) {
        self.style = style
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        layoutManager.textContainer = container
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        commonInit()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func commonInit() {
        isEditable = true
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        // 代码创建的 NSTextView 默认 maxSize == 初始 frame，会把高度卡死在首屏；必须放开
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        usesFontPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        textContainerInset = CGSize(width: 12, height: 16)
        textStorage?.delegate = self
        applyStyle(style)
    }

    // MARK: - 样式

    public func applyStyle(_ style: RenderStyle) {
        self.style = style
        let size = (style.baseSize * 0.9).rounded()
        editorFont = NSFont(descriptor: style.codeFont.fontDescriptor, size: size) ?? style.codeFont
        boldFont = RenderStyle.variant(editorFont, traits: .boldFontMask)
        italicFont = RenderStyle.variant(editorFont, traits: .italicFontMask)
        boldItalicFont = RenderStyle.variant(boldFont, traits: .italicFontMask)
        backgroundColor = style.background
        insertionPointColor = style.foreground
        selectedTextAttributes = [.backgroundColor: style.selection]
        font = editorFont
        textColor = style.foreground
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.35
        ps.lineBreakMode = .byWordWrapping
        defaultParagraphStyle = ps
        typingAttributes = [.font: editorFont!, .foregroundColor: style.foreground, .paragraphStyle: ps]
        baseAttrs = QAUniqueAttributes(typingAttributes as NSDictionary) as AnyObject
        attrsCache = [:]
        let e = style.theme.colors.editor
        func mk(_ color: NSColor, font: NSFont? = nil, extra: [NSAttributedString.Key: Any] = [:]) -> AnyObject {
            var d = typingAttributes
            d[.foregroundColor] = color
            if let font { d[.font] = font }
            for (k, v) in extra { d[k] = v }
            return QAUniqueAttributes(d as NSDictionary) as AnyObject
        }
        attrsCache[.marker] = mk(e.markdownMarker.nsColor)
        attrsCache[.heading] = mk(e.markdownHeading.nsColor, font: boldFont)
        attrsCache[.codeSpan] = mk(e.markdownCode.nsColor)
        attrsCache[.codeBlock] = mk(e.markdownCode.nsColor)
        attrsCache[.fenceInfo] = mk(style.syntaxColor(.type))
        attrsCache[.emphasis] = mk(style.foreground, font: italicFont)
        attrsCache[.strong] = mk(style.foreground, font: boldFont)
        attrsCache[.strike] = mk(style.muted, extra: [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        attrsCache[.linkText] = mk(e.markdownLink.nsColor)
        attrsCache[.linkURL] = mk(style.muted, extra: [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: style.muted.withAlphaComponent(0.4)])
        attrsCache[.image] = mk(e.markdownLink.nsColor)
        attrsCache[.html] = mk(style.syntaxColor(.comment))
        attrsCache[.quote] = mk(style.quoteForeground)
        attrsCache[.frontMatter] = mk(style.muted)
        attrsCache[.escape] = mk(style.syntaxColor(.escape))
        attrsCache[.footnote] = mk(style.accent)
        attrsCache[.tableDelim] = mk(e.markdownMarker.nsColor)
        rehighlightAll()
        (enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.style = style
        needsDisplay = true
    }

    // MARK: - 内容

    /// 设置全文（不产生 undo）
    public func setSource(_ text: String) {
        guard let ts = textStorage else { return }
        undoManager?.removeAllActions()
        isHighlighting = true
        ts.beginEditing()
        ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: text)
        ts.endEditing()
        isHighlighting = false
        rebuildLineStarts()
        rehighlightAll()
    }

    public var source: String { textStorage?.string ?? "" }

    // MARK: - 高亮

    private func rebuildLineStarts() {
        let s = textStorage?.string ?? ""
        var starts = [0]
        starts.reserveCapacity(s.utf16.count / 40)
        var i = 0
        for u in s.utf16 { i += 1; if u == 0x0A { starts.append(i) } }
        lineStarts = starts
    }

    private func rehighlightAll() {
        guard let ts = textStorage, ts.length > 0 else { return }
        highlight(range: NSRange(location: 0, length: ts.length), state: .initial)
    }

    /// 计算 `location` 所在行开头的围栏 / front matter 状态：只看每行开头几个字符（O(行数)，1 MB ≈ 25k 行 < 1 ms）
    private func fenceState(before location: Int) -> MarkdownLexer.State {
        guard let ns = textStorage?.string as NSString?, location > 0 else { return .initial }
        var st = MarkdownLexer.State()
        let n = ns.length
        for (idx, start) in lineStarts.enumerated() {
            if start >= location { break }
            st.lineNumber = idx + 1
            // 读取行首至多 8 个字符
            var i = start
            var spaces = 0
            while i < n, spaces < 3, ns.character(at: i) == 0x20 { i += 1; spaces += 1 }
            guard i < n else { continue }
            let c = ns.character(at: i)
            if idx == 0, c == 0x2D, isDashRule(ns, i, n) { st.inFrontMatter = true; continue }
            if st.inFrontMatter {
                if (c == 0x2D && isDashRule(ns, i, n)) || (c == 0x2E && ns.character(at: min(i + 1, n - 1)) == 0x2E) { st.inFrontMatter = false }
                continue
            }
            guard c == 0x60 || c == 0x7E else { continue }
            var k = i; while k < n, ns.character(at: k) == c { k += 1 }
            let len = k - i
            guard len >= 3 else { continue }
            if st.inFence {
                if UInt8(c) == st.fenceChar, len >= st.fenceLen {
                    // 闭合行只能有空白
                    var m = k; var only = true
                    while m < n { let x = ns.character(at: m); if x == 0x0A { break }; if x != 0x20, x != 0x09 { only = false; break }; m += 1 }
                    if only { st.fenceChar = 0; st.fenceLen = 0 }
                }
            } else {
                // 反引号围栏 info 中不能含反引号
                var ok = true
                if c == 0x60 { var m = k; while m < n { let x = ns.character(at: m); if x == 0x0A { break }; if x == 0x60 { ok = false; break }; m += 1 } }
                if ok { st.fenceChar = UInt8(c); st.fenceLen = len }
            }
        }
        return st
    }
    private func isDashRule(_ ns: NSString, _ i: Int, _ n: Int) -> Bool {
        var k = i; var dashes = 0
        while k < n { let x = ns.character(at: k); if x == 0x0A { break }; if x == 0x2D { dashes += 1 } else if x != 0x20 { return false }; k += 1 }
        return dashes >= 3
    }

    private func highlight(range: NSRange, state: MarkdownLexer.State) {
        guard let ts = textStorage else { return }
        let ns = ts.string as NSString
        let text = ns.substring(with: range)
        var st = state
        let tokens = lexer.tokenize(text, base: range.location, state: &st)
        isHighlighting = true
        ts.beginEditing()
        QASetRunAttributes(ts, baseAttrs, UInt(range.location), UInt(range.length))
        for t in tokens {
            guard let a = attrsCache[t.kind] else { continue }
            let lo = max(range.location, t.range.lowerBound), hi = min(range.location + range.length, t.range.upperBound)
            guard hi > lo else { continue }
            // 强调 + 加粗叠加：嵌套时后者覆盖前者，若已是粗则用粗斜
            if t.kind == .emphasis, let f = ts.attribute(.font, at: lo, effectiveRange: nil) as? NSFont, f == boldFont {
                ts.addAttribute(.font, value: boldItalicFont!, range: NSRange(location: lo, length: hi - lo))
            } else {
                QASetRunAttributes(ts, a, UInt(lo), UInt(hi - lo))
            }
        }
        ts.endEditing()
        isHighlighting = false
    }

    public nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated {
            guard !isHighlighting, editedMask.contains(.editedCharacters) else { return }
            rebuildLineStarts()
            let ns = storage.string as NSString
            var para = ns.paragraphRange(for: editedRange)
            // 若编辑涉及围栏标记，重新高亮到文末（围栏状态会向下传播）
            let edited = ns.substring(with: para)
            if edited.contains("```") || edited.contains("~~~") || edited.hasPrefix("---") {
                para = NSRange(location: para.location, length: ns.length - para.location)
            }
            let st = fenceState(before: para.location)
            highlight(range: para, state: st)
        }
    }

    public override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }

    // MARK: - 当前行高亮

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard window?.firstResponder === self, let tlm = textLayoutManager, let cs = textContentStorage else { return }
        let sel = selectedRange()
        guard let loc = cs.location(cs.documentRange.location, offsetBy: sel.location), let frag = tlm.textLayoutFragment(for: loc) else { return }
        var f = frag.layoutFragmentFrame
        f.origin.y += textContainerInset.height
        f.origin.x = 0; f.size.width = bounds.width
        style.theme.colors.editor.currentLine.nsColor.setFill()
        f.intersection(rect).fill()
    }

    public override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    // MARK: - 行号

    /// 字符偏移 → 行号（1-based）
    public func lineNumber(at location: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }
    /// 行号（1-based）→ 行首偏移
    public func location(ofLine line: Int) -> Int {
        let i = max(0, min(lineStarts.count - 1, line - 1))
        return lineStarts[i]
    }
    public var lineCount: Int { lineStarts.count }

    /// 视口顶部所在行（1-based）
    public func topVisibleLine() -> Int {
        guard let tlm = textLayoutManager, let cs = textContentStorage, let sv = enclosingScrollView else { return 1 }
        let y = max(0, sv.contentView.bounds.minY - textContainerInset.height)
        guard let frag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return 1 }
        return lineNumber(at: cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location))
    }

    /// 滚动使某行到视口顶部
    public func scroll(toLine line: Int) {
        guard let tlm = textLayoutManager, let cs = textContentStorage, let sv = enclosingScrollView else { return }
        let loc = location(ofLine: line)
        guard let l = cs.location(cs.documentRange.location, offsetBy: loc) else { return }
        tlm.ensureLayout(for: NSTextRange(location: l))
        guard let frag = tlm.textLayoutFragment(for: l) else { return }
        let y = max(0, frag.layoutFragmentFrame.minY + textContainerInset.height - 8)
        sv.contentView.setBoundsOrigin(CGPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    // MARK: - 输入辅助

    public override func insertNewline(_ sender: Any?) {
        guard let ns = textStorage?.string as NSString? else { return super.insertNewline(sender) }
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: NSRange(location: lineRange.location, length: max(0, sel.location - lineRange.location)))
        // 列表续行：- / * / + / 1. / - [ ]
        if let m = line.range(of: "^(\\s*)([-*+]|\\d+[.)])\\s+(\\[[ xX]\\]\\s+)?", options: .regularExpression) {
            let prefix = String(line[m])
            let content = line[m.upperBound...]
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // 空项目回车：结束列表（删掉标记）
                let del = NSRange(location: lineRange.location, length: sel.location - lineRange.location)
                if shouldChangeText(in: del, replacementString: "") { insertText("", replacementRange: del); didChangeText() }
                super.insertNewline(sender)
                return
            }
            var next = prefix
            // 有序编号递增
            if let numRange = prefix.range(of: "\\d+", options: .regularExpression), let n = Int(prefix[numRange]) {
                next.replaceSubrange(numRange, with: String(n + 1))
            }
            next = next.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
            super.insertNewline(sender)
            insertText(next, replacementRange: selectedRange())
            return
        }
        // 引用续行
        if let m = line.range(of: "^(\\s*>\\s?)+", options: .regularExpression), !line[m.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
            super.insertNewline(sender)
            insertText(String(line[m]), replacementRange: selectedRange())
            return
        }
        // 围栏自动闭合：输入 ``` 回车 → 补 ```
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```"), !fenceState(before: lineRange.location).inFence, ns.length == lineRange.location + lineRange.length || !nextNonEmptyLineIsFence(ns, from: lineRange) {
            super.insertNewline(sender)
            let pos = selectedRange().location
            insertText("\n```", replacementRange: NSRange(location: pos, length: 0))
            setSelectedRange(NSRange(location: pos, length: 0))
            return
        }
        super.insertNewline(sender)
    }

    private func nextNonEmptyLineIsFence(_ ns: NSString, from lineRange: NSRange) -> Bool {
        var loc = lineRange.location + lineRange.length
        while loc < ns.length {
            let r = ns.lineRange(for: NSRange(location: loc, length: 0))
            let t = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t.hasPrefix("```") }
            loc = r.location + r.length
        }
        return false
    }

    public override func insertTab(_ sender: Any?) {
        // 选区多行：整体缩进；否则插入两个空格
        let sel = selectedRange()
        if sel.length > 0, let ns = textStorage?.string as NSString?, ns.substring(with: sel).contains("\n") {
            indentLines(in: sel, by: 1); return
        }
        insertText("  ", replacementRange: sel)
    }
    public override func insertBacktab(_ sender: Any?) {
        indentLines(in: selectedRange(), by: -1)
    }

    private func indentLines(in range: NSRange, by delta: Int) {
        guard let ns = textStorage?.string as NSString? else { return }
        let lines = ns.lineRange(for: range)
        var out = ""
        var removed = 0
        ns.substring(with: lines).enumerateLines { line, _ in
            if delta > 0 { out += "  " + line + "\n" }
            else {
                var l = line
                if l.hasPrefix("  ") { l.removeFirst(2); removed += 2 } else if l.hasPrefix(" ") || l.hasPrefix("\t") { l.removeFirst(); removed += 1 }
                out += l + "\n"
            }
        }
        if !ns.substring(with: lines).hasSuffix("\n") { out.removeLast() }
        if shouldChangeText(in: lines, replacementString: out) {
            insertText(out, replacementRange: lines)
            didChangeText()
            setSelectedRange(NSRange(location: lines.location, length: out.utf16.count))
        }
    }

    /// 用标记包裹选区（⌘B → **、⌘I → *、⌘K → [text](url)）
    public func wrapSelection(prefix: String, suffix: String, placeholder: String = "文本") {
        guard let ns = textStorage?.string as NSString? else { return }
        let sel = selectedRange()
        let text = sel.length > 0 ? ns.substring(with: sel) : placeholder
        let replacement = prefix + text + suffix
        guard shouldChangeText(in: sel, replacementString: replacement) else { return }
        insertText(replacement, replacementRange: sel)
        didChangeText()
        setSelectedRange(NSRange(location: sel.location + prefix.utf16.count, length: text.utf16.count))
    }

    @objc public func toggleBold(_ sender: Any?) { wrapSelection(prefix: "**", suffix: "**") }
    @objc public func toggleItalic(_ sender: Any?) { wrapSelection(prefix: "*", suffix: "*") }
    @objc public func insertLink(_ sender: Any?) {
        guard let ns = textStorage?.string as NSString? else { return }
        let sel = selectedRange()
        let text = sel.length > 0 ? ns.substring(with: sel) : "链接文字"
        let replacement = "[\(text)](url)"
        guard shouldChangeText(in: sel, replacementString: replacement) else { return }
        insertText(replacement, replacementRange: sel)
        didChangeText()
        setSelectedRange(NSRange(location: sel.location + text.utf16.count + 3, length: 3))
    }
    @objc public func toggleInlineCode(_ sender: Any?) { wrapSelection(prefix: "`", suffix: "`", placeholder: "code") }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let ch = event.charactersIgnoringModifiers {
            switch ch {
            case "b": toggleBold(nil); return true
            case "i": toggleItalic(nil); return true
            case "k": insertLink(nil); return true
            case "e": toggleInlineCode(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - 行号栏

@MainActor
public final class LineNumberRulerView: NSRulerView {
    weak var editor: EditorTextView?
    public var style: RenderStyle? { didSet { needsDisplay = true } }

    public init(editor: EditorTextView, scrollView: NSScrollView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 44
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let tlm = editor.textLayoutManager, let cs = editor.textContentStorage, let sv = scrollView else { return }
        let bg = style?.background ?? .textBackgroundColor
        bg.setFill(); bounds.fill()
        let gutterColor = style?.theme.colors.editor.gutter.nsColor ?? .tertiaryLabelColor
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (editor.font?.pointSize ?? 12) * 0.85), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: gutterColor]
        let curAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style?.foreground ?? .labelColor]
        let visible = sv.contentView.bounds
        let inset = editor.textContainerInset
        let currentLine = editor.lineNumber(at: editor.selectedRange().location)
        // 每段一个行号（软换行不计）
        let topY = max(0, visible.minY - inset.height)
        guard let startFrag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: topY)) else { return }
        var maxLine = 1
        tlm.enumerateTextLayoutFragments(from: startFrag.rangeInElement.location, options: [.ensuresLayout]) { frag in
            let f = frag.layoutFragmentFrame
            let y = f.minY + inset.height - visible.minY
            if y > bounds.height { return false }
            let offset = cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location)
            let line = editor.lineNumber(at: offset)
            maxLine = line
            let s = NSAttributedString(string: "\(line)", attributes: line == currentLine ? curAttrs : attrs)
            let sz = s.size()
            // 与首行基线对齐：用第一行片段高度
            let firstLineH = frag.textLineFragments.first?.typographicBounds.height ?? sz.height
            s.draw(at: CGPoint(x: ruleThickness - sz.width - 8, y: y + (firstLineH - sz.height) / 2))
            return true
        }
        // 宽度自适应
        let needed = ("\(max(editor.lineCount, maxLine))" as NSString).size(withAttributes: attrs).width + 20
        if abs(needed - ruleThickness) > 4 { ruleThickness = max(36, needed.rounded(.up)) }
    }
}
