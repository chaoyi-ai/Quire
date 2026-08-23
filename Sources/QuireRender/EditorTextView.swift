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
    /// 专注模式；变化时重算淡化 / 留白
    public var focusMode: EditorFocusMode = .off {
        didSet {
            guard focusMode != oldValue else { return }
            updateTypewriterInset()
            applyFocusDim()
            if focusMode == .typewriter { centerCaretLine() }
            needsDisplay = true
        }
    }
    var focusDimActive = false
    var lastFocusRange: NSRange?
    var dimOverlay: FocusDimOverlay?
    /// 最近一次选区变化是否来自键盘（打字机模式只在这种情况下居中，避免点击时屏幕跳）
    private var selectionFromKeyboard = false
    /// 内容列最大宽度（0 = 不限制，贴左）：沉浸模式 / 行宽设置下居中成一列
    public var maxContentWidth: CGFloat = 0 { didSet { if maxContentWidth != oldValue { updateContentInset(); needsLayout = true } } }
    /// 排版参数（字体 / 字号 / 行距 / 行宽），覆盖主题的代码字体；变化时重设样式
    public var typography = EditorTypography() {
        didSet { if typography != oldValue { applyStyle(style); maxContentWidth = typography.columnChars > 0 ? CGFloat(typography.columnChars) * charWidth : immersiveWidth } }
    }
    /// 沉浸模式要求的列宽（0 = 无）；与行宽设置取其一
    public var immersiveWidth: CGFloat = 0 {
        didSet { maxContentWidth = typography.columnChars > 0 ? CGFloat(typography.columnChars) * charWidth : immersiveWidth }
    }
    /// Esc（沉浸模式退出用）
    public var onEscape: (() -> Void)?
    /// 粘贴时若剪贴板有 HTML（来自浏览器 / 富文本 App）自动转成 Markdown
    public var convertsHTMLOnPaste = true

    /// 标记出挑（iA Writer 式）：`#` / `-` / `1.` / `>` 出挑到左边距，正文左缘对齐。关掉则普通左对齐。
    public var hangingMarkers = true { didSet { if hangingMarkers != oldValue { applyStyle(style) } } }
    /// 出挑列宽（字符数）：最多容纳 `### ` / `10. ` / `> > `；更长的标记（h4–h6）只能部分出挑
    static let hangingColumnChars: CGFloat = 4
    private var charWidth: CGFloat = 8
    private var hangingStyles: [Int: NSParagraphStyle] = [:]   // key = spaces << 8 | markerLen
    private var boldFont: NSFont!, italicFont: NSFont!, boldItalicFont: NSFont!, editorFont: NSFont!
    private var lineStarts: [Int] = [0]     // 每行起始 UTF-16 偏移
    private var isHighlighting = false
    /// 文本变化回调（编辑器 → 文档）
    public var onTextChange: (() -> Void)?
    /// 拖入 Markdown 文件（打开）
    public var onDropFiles: (([URL]) -> Void)?
    /// 当前文档 URL（用于生成拖入图片/文件的相对路径）
    public var documentURL: URL?

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
        let size = typography.fontSize > 0 ? typography.fontSize : (style.baseSize * 0.9).rounded()
        if let family = typography.fontFamily, !family.isEmpty, let f = NSFont(name: family, size: size) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            editorFont = f
        } else {
            editorFont = NSFont(descriptor: style.codeFont.fontDescriptor, size: size) ?? style.codeFont
        }
        boldFont = RenderStyle.variant(editorFont, traits: .boldFontMask)
        italicFont = RenderStyle.variant(editorFont, traits: .italicFontMask)
        boldItalicFont = RenderStyle.variant(boldFont, traits: .italicFontMask)
        backgroundColor = style.background
        insertionPointColor = style.foreground
        selectedTextAttributes = [.backgroundColor: style.selection]
        font = editorFont
        textColor = style.foreground
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = typography.lineHeight
        ps.lineBreakMode = .byWordWrapping
        charWidth = ("0" as NSString).size(withAttributes: [.font: editorFont!]).width
        if typography.columnChars > 0 { maxContentWidth = CGFloat(typography.columnChars) * charWidth }
        hangingStyles = [:]
        if hangingMarkers {
            let col = (Self.hangingColumnChars * charWidth).rounded()
            ps.firstLineHeadIndent = col; ps.headIndent = col
        }
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

    /// 每行行首的围栏 / front matter 状态（与 lineStarts 对齐）
    private struct LineState { var fenceChar: UInt8 = 0; var fenceLen: UInt16 = 0; var inFrontMatter = false }
    private var lineStates: [LineState] = [LineState()]

    /// 一趟重建行索引 + 每行行首状态。分块 getCharacters（不用 String.utf16 逐字遍历：1 MB 桥接串 ~9 ms → <1 ms）。
    private func rebuildLineStarts() {
        guard let ns = textStorage?.string as NSString?, ns.length > 0 else { lineStarts = [0]; lineStates = [LineState()]; return }
        let n = ns.length
        var starts: [Int] = [0]; starts.reserveCapacity(n / 40 + 1)
        var states: [LineState] = [LineState()]; states.reserveCapacity(n / 40 + 1)
        var st = LineState()          // 正在扫描的这一行行首的状态 → 处理完成为下一行行首状态
        var lineIdx = 0
        var carry: [unichar] = []     // 跨块的未完成行
        let chunk = 1 << 16
        var buf = [unichar](repeating: 0, count: chunk)
        var loc = 0
        while loc < n {
            let len = min(chunk, n - loc)
            ns.getCharacters(&buf, range: NSRange(location: loc, length: len))
            buf.withUnsafeBufferPointer { p in
                var lineBegin = 0
                for k in 0..<len where p[k] == 0x0A {
                    if carry.isEmpty {
                        Self.advance(&st, line: UnsafeBufferPointer(rebasing: p[lineBegin..<k]), lineIndex: lineIdx)
                    } else {
                        carry.append(contentsOf: p[lineBegin..<k])
                        carry.withUnsafeBufferPointer { Self.advance(&st, line: $0, lineIndex: lineIdx) }
                        carry.removeAll(keepingCapacity: true)
                    }
                    lineIdx += 1
                    starts.append(loc + k + 1)
                    states.append(st)
                    lineBegin = k + 1
                }
                if lineBegin < len { carry.append(contentsOf: p[lineBegin..<len]) }
            }
            loc += len
        }
        lineStarts = starts
        lineStates = states
    }

    /// 用一行内容推进围栏 / front matter 状态（只看行首几个字符 + 必要时整行）
    private static func advance(_ st: inout LineState, line: UnsafeBufferPointer<unichar>, lineIndex: Int) {
        let n = line.count
        var i = 0, spaces = 0
        while i < n, spaces < 3, line[i] == 0x20 { i += 1; spaces += 1 }
        guard i < n else { return }
        let c = line[i]
        func isDashRule() -> Bool {
            var dashes = 0
            for k in i..<n { let x = line[k]; if x == 0x2D { dashes += 1 } else if x != 0x20, x != 0x0D { return false } }
            return dashes >= 3
        }
        if lineIndex == 0, c == 0x2D, isDashRule() { st.inFrontMatter = true; return }
        if st.inFrontMatter {
            if (c == 0x2D && isDashRule()) || (c == 0x2E && i + 2 < n && line[i + 1] == 0x2E && line[i + 2] == 0x2E) { st.inFrontMatter = false }
            return
        }
        guard c == 0x60 || c == 0x7E else { return }
        var k = i; while k < n, line[k] == c { k += 1 }
        let len = k - i
        guard len >= 3 else { return }
        if st.fenceChar != 0 {
            // 闭合行：同字符、不短于开栏、其后只有空白
            guard UInt8(c) == st.fenceChar, len >= Int(st.fenceLen) else { return }
            for m in k..<n where line[m] != 0x20 && line[m] != 0x09 && line[m] != 0x0D { return }
            st.fenceChar = 0; st.fenceLen = 0
        } else {
            // 反引号围栏 info 中不能含反引号
            if c == 0x60 { for m in k..<n where line[m] == 0x60 { return } }
            st.fenceChar = UInt8(c); st.fenceLen = UInt16(min(len, Int(UInt16.max)))
        }
    }

    private func rehighlightAll() {
        guard let ts = textStorage, ts.length > 0 else { return }
        highlight(range: NSRange(location: 0, length: ts.length), state: .initial)
    }

    /// `location` 所在行行首的围栏 / front matter 状态（查表，O(log 行数)）
    private func fenceState(before location: Int) -> MarkdownLexer.State {
        guard location > 0 else { return .initial }
        let line = lineNumber(at: location)          // 1-based
        let ls = lineStates[min(line - 1, lineStates.count - 1)]
        var st = MarkdownLexer.State()
        st.fenceChar = ls.fenceChar; st.fenceLen = Int(ls.fenceLen); st.inFrontMatter = ls.inFrontMatter
        st.lineNumber = line - 1     // lexer 语义：该行之前的行数（0-based 行号）
        return st
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
        // 段落样式最后设：token 的属性字典整体覆盖，会把段落样式打回默认
        if hangingMarkers { applyHangingIndents(ns, in: range) }
        ts.endEditing()
        isHighlighting = false
    }

    /// 标记出挑：按行首前缀（≤3 空格 + `#{1,6} ` / `[-*+] ` / `\d{1,9}[.)] ` / `(> )+`）设段落样式：
    /// headIndent = 列宽 + 缩进空格宽，firstLineHeadIndent = headIndent − 标记宽（≥ 0）
    private func applyHangingIndents(_ ns: NSString, in range: NSRange) {
        guard let ts = textStorage else { return }
        let col = (Self.hangingColumnChars * charWidth).rounded()
        var loc = range.location
        let end = range.location + range.length
        while loc < end {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            defer { loc = para.location + max(1, para.length) }
            let (spaces, marker) = Self.markerPrefix(ns, para)
            guard marker > 0 else { continue }
            let key = spaces << 8 | marker
            let ps: NSParagraphStyle
            if let cached = hangingStyles[key] { ps = cached } else {
                let m = (defaultParagraphStyle ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
                let head = col + CGFloat(spaces) * charWidth
                m.headIndent = head
                m.firstLineHeadIndent = max(0, head - CGFloat(marker) * charWidth)
                hangingStyles[key] = m; ps = m
            }
            ts.addAttribute(.paragraphStyle, value: ps, range: para)
        }
    }

    /// 返回 (前导空格数, 标记字符数含其后空格)；无标记返回 (0, 0)
    static func markerPrefix(_ ns: NSString, _ para: NSRange) -> (Int, Int) {
        let n = para.length
        @inline(__always) func c(_ k: Int) -> unichar { k < n ? ns.character(at: para.location + k) : 0 }
        var i = 0
        while i < 3, c(i) == 0x20 { i += 1 }
        let spaces = i
        let ch = c(i)
        if ch == 0x23 {   // #
            var k = i; while k - i < 6, c(k) == 0x23 { k += 1 }
            return c(k) == 0x20 ? (spaces, k - i + 1) : (0, 0)
        }
        if ch == 0x2D || ch == 0x2A || ch == 0x2B { return c(i + 1) == 0x20 ? (spaces, 2) : (0, 0) }   // - * +
        if ch == 0x3E {   // > (> )+
            var k = i; var len = 0
            while c(k) == 0x3E { k += 1; len += 1; if c(k) == 0x20 { k += 1; len += 1 } }
            return (spaces, len)
        }
        if ch >= 0x30 && ch <= 0x39 {   // 1. / 1)
            var k = i; while k - i < 9, c(k) >= 0x30, c(k) <= 0x39 { k += 1 }
            if (c(k) == 0x2E || c(k) == 0x29), c(k + 1) == 0x20 { return (spaces, k - i + 2) }
        }
        return (0, 0)
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
        if focusMode != .off {
            applyFocusDim()
            if focusMode == .typewriter { centerCaretLine() }
        }
    }

    public override func keyDown(with event: NSEvent) {
        selectionFromKeyboard = true
        super.keyDown(with: event)
        selectionFromKeyboard = false
    }

    public override func mouseDown(with event: NSEvent) {
        selectionFromKeyboard = false
        super.mouseDown(with: event)
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard focusMode != .off, !stillSelecting else { return }
        applyFocusDim()
        if focusMode == .typewriter, selectionFromKeyboard { centerCaretLine() }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if focusDimActive { dimOverlay?.setNeedsDisplay(dirtyRect) }
    }

    /// 粘贴剪贴板图片时存到哪（相对文档目录）；nil = 文档未保存，回退为提示
    public var pastedImagesDirectoryName = "assets"

    public override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // 剪贴板是图片（截图 / 从浏览器复制图片）且没有文本：存成文件、插入 ![](相对路径)
        if pb.string(forType: .string) == nil, pb.string(forType: .html) == nil, pb.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue]) {
            if pasteImageFromPasteboard(pb) { return }
        }
        // 有文件 / 图片等非文本内容时走默认；纯文本来源（代码编辑器）也走默认
        if convertsHTMLOnPaste, let html = pb.string(forType: .html), !html.isEmpty, Self.looksLikeRichHTML(html) {
            let md = HTMLToMarkdown.convert(html)
            if !md.isEmpty { insertText(md, replacementRange: selectedRange()); return }
        }
        pasteAsPlainText(sender)
    }

    /// 剪贴板图片 → `<文档目录>/assets/<文档名>/粘贴-时间戳.png`，插入 `![](相对路径)`。文档未保存时无处可放：返回 false 走默认
    func pasteImageFromPasteboard(_ pb: NSPasteboard) -> Bool {
        guard let documentURL else { NSSound.beep(); return false }
        guard let data = pb.data(forType: .png) ?? (pb.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else { return false }
        let docDir = documentURL.deletingLastPathComponent()
        let folder = docDir.appendingPathComponent(pastedImagesDirectoryName).appendingPathComponent(documentURL.deletingPathExtension().lastPathComponent)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        var url = folder.appendingPathComponent("pasted-\(f.string(from: Date())).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("pasted-\(f.string(from: Date()))-\(n).png"); n += 1 }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { NSSound.beep(); return false }
        let rel = DropSupport.relativePath(of: url, to: documentURL)
        let text = "![](\(rel))"
        let r = selectedRange()
        guard shouldChangeText(in: r, replacementString: text) else { return false }
        insertText(text, replacementRange: r)
        // 光标放到 [] 里，方便直接写 alt
        setSelectedRange(NSRange(location: r.location + 2, length: 0))
        didChangeText()
        return true
    }

    /// ⇧⌘V：只粘纯文本
    public override func pasteAsPlainText(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
        insertText(s, replacementRange: selectedRange())
    }

    /// 浏览器 / Word 复制出来的 HTML 才转；纯文本编辑器有时也塞 HTML 包一层 <pre>，那种不转
    static func looksLikeRichHTML(_ html: String) -> Bool {
        html.range(of: "<(p|h[1-6]|ul|ol|table|strong|em|a|img|blockquote|li|b|i)(\\s|>|/)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    public override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContentInset()
        updateTypewriterInset()
    }

    /// 沉浸 / 行宽限制：把超出 maxContentWidth 的宽度分到左右 inset
    func updateContentInset() {
        let w = bounds.width
        var inset: CGFloat = 12
        if maxContentWidth > 0, w - 24 > maxContentWidth { inset = ((w - maxContentWidth) / 2).rounded(.down) }
        if abs(textContainerInset.width - inset) > 0.5 { textContainerInset = CGSize(width: inset, height: textContainerInset.height) }
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
        // 可见区顶部 = bounds.minY + 被工具栏盖住的 contentInsets.top
        let y = max(0, sv.contentView.bounds.minY + sv.contentInsets.top - textContainerInset.height)
        guard let frag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return 1 }
        return lineNumber(at: cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location))
    }

    /// 滚动使某行到视口顶部
    public func scroll(toLine line: Int) {
        guard let tlm = textLayoutManager, let cs = textContentStorage, let sv = enclosingScrollView else { return }
        let loc = location(ofLine: line)
        guard let l = cs.location(cs.documentRange.location, offsetBy: loc) else { return }
        // 估算布局：设视口 → 布局视口 → 重算，直到稳定（最多 3 轮）
        for _ in 0..<3 {
            var frag: NSTextLayoutFragment?
            tlm.enumerateTextLayoutFragments(from: l, options: [.ensuresLayout]) { f in frag = f; return false }
            guard let frag else { return }
            let y = max(-sv.contentInsets.top, frag.layoutFragmentFrame.minY + textContainerInset.height - 8 - sv.contentInsets.top)
            if abs(y - sv.contentView.bounds.minY) <= 0.5 { break }
            sv.contentView.setBoundsOrigin(CGPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
            tlm.textViewportLayoutController.layoutViewport()
        }
    }

    // MARK: - 拖放：.md 打开；图片插入 ![]()；其他文件插入 []()

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !DropSupport.fileURLs(from: sender).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !DropSupport.fileURLs(from: sender).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DropSupport.fileURLs(from: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        let mds = urls.filter(DropSupport.isMarkdown)
        let others = urls.filter { !DropSupport.isMarkdown($0) }
        if !mds.isEmpty { onDropFiles?(mds) }
        if !others.isEmpty {
            let point = convert(sender.draggingLocation, from: nil)
            let idx = characterIndexForInsertion(at: point)
            let text = others.map { u -> String in
                let rel = DropSupport.relativePath(of: u, to: documentURL)
                let name = u.deletingPathExtension().lastPathComponent
                return DropSupport.isImage(u) ? "![\(name)](\(rel))" : "[\(u.lastPathComponent)](\(rel))"
            }.joined(separator: "\n")
            let r = NSRange(location: idx, length: 0)
            if shouldChangeText(in: r, replacementString: text) {
                insertText(text, replacementRange: r)
                didChangeText()
            }
        }
        return true
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
        // 表格：表头行回车 → 补分隔行 + 空行；表格内回车 → 新行模板
        if TableFormatter.isTableLine(line), !TableFormatter.isSeparatorLine(line), sel.location == lineRange.location + lineRange.length - (ns.substring(with: lineRange).hasSuffix("\n") ? 1 : 0) {
            let nextLineStart = lineRange.location + lineRange.length
            let nextLine: String = nextLineStart < ns.length ? ns.substring(with: ns.lineRange(for: NSRange(location: nextLineStart, length: 0))).trimmingCharacters(in: .newlines) : ""
            let prevLine: String = lineRange.location > 0 ? ns.substring(with: ns.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))).trimmingCharacters(in: .newlines) : ""
            let n = max(1, TableFormatter.cells(line).count)
            let emptyRow = "|" + String(repeating: "   |", count: n)
            if !TableFormatter.isSeparatorLine(nextLine), !TableFormatter.isTableLine(prevLine) {
                // 这是表头
                super.insertNewline(sender)
                let pos = selectedRange().location
                insertText(TableFormatter.separator(forHeader: line) + "\n" + emptyRow, replacementRange: NSRange(location: pos, length: 0))
                _ = formatTableBlock(containing: pos)
                _ = moveTableCell(by: 0)
                return
            }
            super.insertNewline(sender)
            let pos = selectedRange().location
            insertText(emptyRow, replacementRange: NSRange(location: pos, length: 0))
            _ = formatTableBlock(containing: pos)
            _ = moveTableCell(by: 0)
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
        if moveTableCell(by: 1) { return }
        // 选区多行：整体缩进；否则插入两个空格
        let sel = selectedRange()
        if sel.length > 0, let ns = textStorage?.string as NSString?, ns.substring(with: sel).contains("\n") {
            indentLines(in: sel, by: 1); return
        }
        insertText("  ", replacementRange: sel)
    }
    public override func insertBacktab(_ sender: Any?) {
        if moveTableCell(by: -1) { return }
        indentLines(in: selectedRange(), by: -1)
    }

    // MARK: - 表格源码辅助（#57）

    /// 光标所在行是表格行时：Tab / ⇧Tab 在单元格间移动（先把整张表格式化对齐），末格 Tab 追加一行
    private func moveTableCell(by delta: Int) -> Bool {
        guard let ns = textStorage?.string as NSString? else { return false }
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard TableFormatter.isTableLine(line) else { return false }
        // 当前格
        let col = sel.location - lineRange.location
        var cellIdx = TableFormatter.cellRanges(line).firstIndex { col >= $0.location && col <= $0.location + $0.length } ?? 0
        cellIdx += delta
        // 先格式化整张表（光标按单元格重新定位）
        let (blockRange, lineIndex) = formatTableBlock(containing: sel.location)
        guard let blockRange else { return false }
        let block = ns.substring(with: NSRange(location: blockRange.location, length: 0)).isEmpty ? (textStorage!.string as NSString).substring(with: blockRange) : ""
        var lines = block.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var li = lineIndex
        var ranges = TableFormatter.cellRanges(lines[li])
        if cellIdx >= ranges.count {
            // 下一行；没有就新增一行
            if li + 1 < lines.count { li += 1 } else {
                let newRow = "|" + String(repeating: "   |", count: max(1, ranges.count))
                let insertAt = blockRange.location + blockRange.length
                let text = (ns.character(at: max(0, insertAt - 1)) == 0x0A ? "" : "\n") + newRow + "\n"
                insertText(text, replacementRange: NSRange(location: insertAt, length: 0))
                _ = formatTableBlock(containing: insertAt)
                lines = tableLines(containing: insertAt); li = lines.count - 1
            }
            if TableFormatter.isSeparatorLine(lines[li]), li + 1 < lines.count { li += 1 }
            ranges = TableFormatter.cellRanges(lines[li]); cellIdx = 0
        } else if cellIdx < 0 {
            guard li > 0 else { return true }
            li -= 1
            if TableFormatter.isSeparatorLine(lines[li]), li > 0 { li -= 1 }
            ranges = TableFormatter.cellRanges(lines[li]); cellIdx = max(0, ranges.count - 1)
        }
        // 定位到该格内容（选中内容，便于直接覆盖）
        guard let blk = currentTableBlockRange(containing: selectedRange().location) else { return true }
        var offset = blk.location
        for k in 0..<li { offset += (lines[k] as NSString).length + 1 }
        guard cellIdx < ranges.count else { return true }
        let r = ranges[cellIdx]
        let cellText = (lines[li] as NSString).substring(with: r)
        let lead = cellText.prefix(while: { $0 == " " }).count
        let trail = cellText.reversed().prefix(while: { $0 == " " }).count
        let contentLen = max(0, r.length - lead - trail)
        setSelectedRange(NSRange(location: offset + r.location + lead, length: contentLen))
        scrollRangeToVisible(selectedRange())
        return true
    }

    private func tableLines(containing location: Int) -> [String] {
        guard let r = currentTableBlockRange(containing: location), let ns = textStorage?.string as NSString? else { return [] }
        var lines = ns.substring(with: r).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// 光标所在的连续表格行区间（字符范围，含末尾换行）
    private func currentTableBlockRange(containing location: Int) -> NSRange? {
        guard let ns = textStorage?.string as NSString? else { return nil }
        let lineNo = lineNumber(at: location) - 1
        var all: [String] = []
        // 只取附近 ±200 行，避免大文档整篇切分
        let lo = max(0, lineNo - 200), hi = min(lineCount - 1, lineNo + 200)
        for k in lo...hi { let r = ns.lineRange(for: NSRange(location: self.location(ofLine: k + 1), length: 0)); all.append(ns.substring(with: r).trimmingCharacters(in: .newlines)) }
        guard let block = TableFormatter.tableBlock(lines: all, containing: lineNo - lo) else { return nil }
        let start = self.location(ofLine: lo + block.lowerBound + 1)
        let endLine = ns.lineRange(for: NSRange(location: self.location(ofLine: lo + block.upperBound + 1), length: 0))
        return NSRange(location: start, length: endLine.location + endLine.length - start)
    }

    /// 格式化光标所在表格；返回格式化后的块范围与光标所在行在块内的下标
    @discardableResult
    public func formatTableBlock(containing location: Int) -> (NSRange?, Int) {
        guard let blk = currentTableBlockRange(containing: location), let ns = textStorage?.string as NSString? else { return (nil, 0) }
        let lineIndex = lineNumber(at: location) - lineNumber(at: blk.location)
        var lines = ns.substring(with: blk).components(separatedBy: "\n")
        let hadTrailingNewline = lines.last == ""
        if hadTrailingNewline { lines.removeLast() }
        let formatted = TableFormatter.format(lines).joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
        if formatted != ns.substring(with: blk) {
            let sel = selectedRange()
            insertText(formatted, replacementRange: blk)
            setSelectedRange(NSRange(location: min(sel.location, blk.location + (formatted as NSString).length), length: 0))
        }
        return (NSRange(location: blk.location, length: (formatted as NSString).length), lineIndex)
    }

    /// 菜单：格式化当前表格
    @objc public func formatTable(_ sender: Any?) { _ = formatTableBlock(containing: selectedRange().location) }

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
    public func wrapSelection(prefix: String, suffix: String, placeholder: String = RL("文本")) {
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
        let text = sel.length > 0 ? ns.substring(with: sel) : RL("链接文字")
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
