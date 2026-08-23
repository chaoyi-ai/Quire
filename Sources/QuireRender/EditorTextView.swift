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
    /// 词性高亮模式；切换时清掉旧色、重新着色可见区
    /// 著作归属：区间 → 底色（已排序）；`showsAuthorship` 关时不画但照常记录
    public var authorshipSpans: [(range: NSRange, color: NSColor)] = [] { didSet { if showsAuthorship { applyAuthorshipColors() } } }
    public var showsAuthorship = false { didSet { guard showsAuthorship != oldValue else { return }; showsAuthorship ? applyAuthorshipColors() : clearAuthorshipColors() } }
    /// 字符级编辑（含撤销 / 重做 / 程序插入；setSource 整体替换除外）：editedRange 是新内容范围，delta 是长度变化，isPaste 表示来自粘贴
    public var onCharactersEdited: ((_ editedRange: NSRange, _ delta: Int, _ isPaste: Bool) -> Void)?
    var isPasting = false
    var authorshipRepaintWork: DispatchWorkItem?

    public var posMode: POSMode = .off {
        didSet {
            guard posMode != oldValue else { return }
            posGeneration += 1
            clearPOSColors()
            schedulePOSRecolor(delay: 0)
        }
    }
    var posGeneration = 0
    var posWork: DispatchWorkItem?
    /// 文风检查（nil = 关闭）
    public var styleChecker: StyleChecker? {
        didSet {
            styleCheckGeneration += 1
            if styleChecker == nil { clearAllStyleMarks() } else { scheduleStyleCheck(delay: 0) }
        }
    }
    var styleCheckGeneration = 0
    var styleCheckWork: DispatchWorkItem?

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
    /// `[[` 补全候选提供者：输入前缀 → 文件名（不带扩展名）列表；nil = 不补全
    public var wikiLinkCompletions: ((String) -> [String])?
    private var completingWikiLink = false

    // MARK: - [[wikilink]] 补全（用 NSTextView 原生补全弹窗）

    /// 光标前最近的未闭合 `[[` 到光标的范围（不跨行）
    private func wikiLinkPrefixRange() -> NSRange? {
        guard let ns = textStorage?.string as NSString? else { return nil }
        let sel = selectedRange()
        guard sel.length == 0 else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
        guard let open = before.range(of: "[[", options: .backwards) else { return nil }
        let partial = before[open.upperBound...]
        if partial.contains("]]") || partial.contains("|") { return nil }
        let start = lineStart + (String(before[..<open.upperBound]) as NSString).length
        return NSRange(location: start, length: sel.location - start)
    }

    public override var rangeForUserCompletion: NSRange {
        wikiLinkPrefixRange() ?? super.rangeForUserCompletion
    }

    public override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard let r = wikiLinkPrefixRange(), r == charRange, let provider = wikiLinkCompletions, let ns = textStorage?.string as NSString? else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        index.pointee = 0
        let list = provider(ns.substring(with: r))
        return list.isEmpty ? nil : list
    }

    public override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        // wikilink：按 Return / Tab 选定后补上 `]]`（点到别处 / 其他方式结束只收起，不补）
        if completingWikiLink, flag, movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue {
            super.insertCompletion(word + "]]", forPartialWordRange: charRange, movement: movement, isFinal: true)
            completingWikiLink = false
            return
        }
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag { completingWikiLink = false }
    }

    /// 打字时：在 `[[` 之后自动弹补全
    private func maybeTriggerWikiLinkCompletion() {
        guard let provider = wikiLinkCompletions, let r = wikiLinkPrefixRange(), let ns = textStorage?.string as NSString? else { completingWikiLink = false; return }
        // 没候选（文档未保存 / 索引还在扫 / 没匹配）时系统不会弹面板、也不会回调 insertCompletion：标志不能置上，否则以后永远不再触发
        guard !provider(ns.substring(with: r)).isEmpty else { completingWikiLink = false; return }
        completingWikiLink = true
        complete(nil)
    }
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
        // 文件拖放（图片 / Markdown 链接）：显式登记 fileURL，别指望纯文本视图的默认类型里有它
        registerForDraggedTypes(Array(Set(registeredDraggedTypes + [.fileURL])))
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
        startProgressiveLayout()   // 字体 / 行距变了，高度要重排
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
        startProgressiveLayout()
    }

    /// 与阅读视图同一套：≤ 200 KB 的文档在空闲时排完全文，滚动条不跳（见 ProgressiveLayout）
    private lazy var progressiveLayout = ProgressiveLayout(textView: self)
    public var progressiveLayoutMaxLength = 200_000
    public var isFullyLaidOut: Bool { progressiveLayout.isComplete }
    public func revalidateProgressiveLayout() { progressiveLayout.revalidate() }
    private func startProgressiveLayout(delay: TimeInterval = 0.3) {
        guard let ts = textStorage, ts.length > 0, ts.length <= progressiveLayoutMaxLength else { progressiveLayout.cancel(); return }
        progressiveLayout.start(delay: delay)
    }

    public var source: String { textStorage?.string ?? "" }

    // MARK: - 高亮

    /// 每行行首的围栏 / front matter 状态（与 lineStarts 对齐）
    private struct LineState: Equatable { var fenceChar: UInt8 = 0; var fenceLen: UInt16 = 0; var inFrontMatter = false }
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

    /// 用一行内容推进围栏 / front matter 状态。判定原语来自 MarkdownLexer（fence / onlyFence / indent）与 FrontMatter（isOpener / isCloser），
    /// 这里只剩"驱动"逻辑——以前这里自己写了一套，和词法器在制表符缩进 / `----` 上早就不一致
    private static func advance(_ st: inout LineState, line: UnsafeBufferPointer<unichar>, lineIndex: Int) {
        let n = line.count
        let indent = MarkdownLexer.indent(line, 0, n)
        if lineIndex == 0, FrontMatter.isOpener(line) { st.inFrontMatter = true; return }
        if st.inFrontMatter {
            if FrontMatter.isCloser(line) || lineIndex > FrontMatter.maxLines { st.inFrontMatter = false }
            return
        }
        guard indent < 4, let (ch, len) = MarkdownLexer.fence(line, indent, n) else { return }
        if st.fenceChar != 0 {
            // 闭合行：同字符、不短于开栏、其后只有空白
            guard ch == st.fenceChar, len >= Int(st.fenceLen), MarkdownLexer.onlyFence(line, indent, n) else { return }
            st.fenceChar = 0; st.fenceLen = 0
        } else {
            st.fenceChar = ch; st.fenceLen = UInt16(min(len, Int(UInt16.max)))
        }
    }

    private func rehighlightAll() {
        guard let ts = textStorage, ts.length > 0 else { return }
        highlight(range: NSRange(location: 0, length: ts.length), state: .initial)
        // 全量高亮会重置所有属性：词性色 / 文风标记 / 归属底色都要重新铺
        if showsAuthorship { applyAuthorshipColors() }
        schedulePOSRecolor(delay: 0)
        scheduleStyleCheck(delay: 0)
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
            let oldStates = lineStates
            rebuildLineStarts()
            onCharactersEdited?(editedRange, delta, isPasting)
            let ns = storage.string as NSString
            var para = ns.paragraphRange(for: editedRange)
            // 这段编辑是否改变了其后所有行的围栏 / front matter 状态（加了或删了 ``` / ---）：
            // 比较"编辑段之后那一行"的行首状态，新旧不同就重新高亮到文末（只看新文本里有没有 ``` 会漏掉删除围栏的情况）
            let afterIdx = lineNumber(at: min(para.location + para.length, ns.length)) - 1
            let oldIdx = afterIdx - (lineStates.count - oldStates.count)
            let stateChanged = afterIdx < lineStates.count && (oldIdx < 0 || oldIdx >= oldStates.count || oldStates[oldIdx] != lineStates[afterIdx])
            if stateChanged || ns.substring(with: para).hasPrefix("---") {
                para = NSRange(location: para.location, length: ns.length - para.location)
            }
            let st = fenceState(before: para.location)
            highlight(range: para, state: st)
            if showsAuthorship { applyAuthorshipColors(in: para) }
        }
    }

    public override func didChangeText() {
        super.didChangeText()
        onTextChange?()
        updateFormatToolbar()
        // 文本变了：还在后台跑的词性 / 文风任务算的是旧文本，结果作废
        posGeneration += 1; styleCheckGeneration += 1
        schedulePOSRecolor()
        scheduleStyleCheck()
        if wikiLinkPrefixRange() == nil { completingWikiLink = false }
        if !completingWikiLink { maybeTriggerWikiLinkCompletion() }
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
        if !stillSelecting { updateFormatToolbar() } else { formatToolbar?.isHidden = true }
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
        isPasting = true
        defer { isPasting = false }
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
        guard let documentURL else {
            // 文档还没存盘，图片没处放：说清楚，而不是只响一声
            let a = NSAlert(); a.messageText = RL("先存储文档再粘贴图片"); a.informativeText = RL("粘贴的图片会存到文档旁边的 assets 文件夹里，所以文档需要先有位置。"); a.runModal()
            return false
        }
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
        insertText(text, replacementRange: r)   // insertText 自己会走 shouldChangeText / didChangeText，不要再包一层（否则钩子跑两遍）
        // 光标放到 [] 里，方便直接写 alt
        setSelectedRange(NSRange(location: r.location + 2, length: 0))
        return true
    }

    /// ⇧⌘V：只粘纯文本
    public override func pasteAsPlainText(_ sender: Any?) {
        isPasting = true
        defer { isPasting = false }
        guard let s = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
        insertText(s, replacementRange: selectedRange())
    }

    /// 浏览器 / Word 复制出来的 HTML 才转；纯文本编辑器有时也塞 HTML 包一层 <pre>，那种不转
    static func looksLikeRichHTML(_ html: String) -> Bool {
        html.range(of: "<(p|h[1-6]|ul|ol|table|strong|em|a|img|blockquote|li|b|i)(\\s|>|/)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    public override func resignFirstResponder() -> Bool {
        formatToolbar?.isHidden = true
        return super.resignFirstResponder()
    }

    public override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }

    private var lastLaidOutWidth: CGFloat = 0
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContentInset()
        updateTypewriterInset()
        // 宽度变了（窗格展开 / 窗口拉伸）：换行位置全变，排好的高度作废，空闲时重排（拖拽中连续触发，start 会取消上一轮）
        if abs(newSize.width - lastLaidOutWidth) > 1 {
            lastLaidOutWidth = newSize.width
            if (textStorage?.length ?? 0) > 0 { startProgressiveLayout(delay: 0.5) }
        }
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
    public var isScrolledToTop: Bool {
        guard let sv = enclosingScrollView else { return false }
        return sv.contentView.bounds.minY + sv.contentInsets.top <= 1
    }
    /// 已经滚不动了（以 NSClipView 自己的夹紧规则为准，别自己算 frame / inset）
    public var isScrolledToBottom: Bool {
        guard let sv = enclosingScrollView else { return false }
        let clip = sv.contentView
        let maxOrigin = clip.constrainBoundsRect(NSRect(origin: CGPoint(x: clip.bounds.minX, y: 1e9), size: clip.bounds.size)).origin
        return clip.bounds.minY >= maxOrigin.y - 1
    }
    public func scrollToBottom() {
        guard let sv = enclosingScrollView else { return }
        let clip = sv.contentView
        let target = clip.constrainBoundsRect(NSRect(origin: CGPoint(x: clip.bounds.minX, y: 1e9), size: clip.bounds.size)).origin
        clip.setBoundsOrigin(target); sv.reflectScrolledClipView(clip)
    }

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
            isPasting = true; insertText(text, replacementRange: NSRange(location: idx, length: 0)); isPasting = false   // 拖进来的算"粘贴"
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
                insertText("", replacementRange: del)
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
        guard let blockRange, let live = textStorage?.string as NSString? else { return false }   // 格式化后 ns 已是旧快照，下面一律用 live
        let block = live.substring(with: blockRange)
        var lines = block.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var li = lineIndex
        var ranges = TableFormatter.cellRanges(lines[li])
        if cellIdx >= ranges.count {
            // 下一行；没有就新增一行
            if li + 1 < lines.count { li += 1 } else {
                let newRow = "|" + String(repeating: "   |", count: max(1, ranges.count))
                let insertAt = blockRange.location + blockRange.length
                let text = (insertAt == 0 || live.character(at: insertAt - 1) == 0x0A ? "" : "\n") + newRow + "\n"
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
        // 只改每行行首那几个字符（不是整段替换）：撤销是一组，归属记录只落在真正改动的字符上
        var lineStarts: [Int] = []
        var loc = lines.location
        while loc < lines.location + lines.length {
            lineStarts.append(loc)
            let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
            loc = lr.location + lr.length
            if lr.length == 0 { break }
        }
        var edits: [(NSRange, String)] = []
        for start in lineStarts {
            if delta > 0 { edits.append((NSRange(location: start, length: 0), "  ")); continue }
            let c0 = start < ns.length ? ns.character(at: start) : 0
            let c1 = start + 1 < ns.length ? ns.character(at: start + 1) : 0
            if c0 == 0x20, c1 == 0x20 { edits.append((NSRange(location: start, length: 2), "")) }
            else if c0 == 0x20 || c0 == 0x09 { edits.append((NSRange(location: start, length: 1), "")) }
        }
        guard !edits.isEmpty else { return }   // 没什么可去掉的：不动文档、不标脏
        undoManager?.beginUndoGrouping()
        var shift = 0
        for (r, text) in edits.sorted(by: { $0.0.location > $1.0.location }).reversed() {
            insertText(text, replacementRange: NSRange(location: r.location + shift, length: r.length))
            shift += (text as NSString).length - r.length
        }
        undoManager?.endUndoGrouping()
        setSelectedRange(NSRange(location: lines.location, length: lines.length + shift))
    }

    /// 用标记包裹选区（⌘B → **、⌘I → *、⌘K → [text](url)）
    public func wrapSelection(prefix: String, suffix: String, placeholder: String = RL("文本")) {
        let sel = selectedRange()
        // 有选区：只插入前后标记，选中的文字原样保留（归属不变）；没选区：插入占位文字
        undoManager?.beginUndoGrouping()
        let textLen: Int
        if sel.length > 0 {
            insertText(suffix, replacementRange: NSRange(location: sel.location + sel.length, length: 0))
            insertText(prefix, replacementRange: NSRange(location: sel.location, length: 0))
            textLen = sel.length
        } else {
            insertText(prefix + placeholder + suffix, replacementRange: sel)
            textLen = (placeholder as NSString).length
        }
        undoManager?.endUndoGrouping()
        setSelectedRange(NSRange(location: sel.location + prefix.utf16.count, length: textLen))
    }

    @objc public func toggleBold(_ sender: Any?) { wrapSelection(prefix: "**", suffix: "**") }
    @objc public func toggleItalic(_ sender: Any?) { wrapSelection(prefix: "*", suffix: "*") }
    @objc public func insertLink(_ sender: Any?) {
        let sel = selectedRange()
        let textLen = sel.length > 0 ? sel.length : (RL("链接文字") as NSString).length
        wrapSelection(prefix: "[", suffix: "](url)", placeholder: RL("链接文字"))
        setSelectedRange(NSRange(location: sel.location + textLen + 3, length: 3))
    }
    @objc public func toggleInlineCode(_ sender: Any?) { wrapSelection(prefix: "`", suffix: "`", placeholder: "code") }
    @objc public func toggleStrikethrough(_ sender: Any?) { wrapSelection(prefix: "~~", suffix: "~~") }
    @objc public func setHeading1(_ sender: Any?) { setHeadingLevel(1) }
    @objc public func setHeading2(_ sender: Any?) { setHeadingLevel(2) }
    @objc public func setHeading3(_ sender: Any?) { setHeadingLevel(3) }
    @objc public func toggleQuote(_ sender: Any?) { toggleLinePrefix("> ", pattern: "^(\\s*)>\\s?") }
    @objc public func toggleBulletList(_ sender: Any?) { toggleLinePrefix("- ", pattern: "^(\\s*)[-*+]\\s+") }

    /// 选区所在各行：设为 n 级标题（已是该级 → 去掉标记）
    public func setHeadingLevel(_ n: Int) {
        let prefix = String(repeating: "#", count: n) + " "
        editLinePrefixes { line in
            let existing = line.range(of: "^#{1,6}\\s+", options: .regularExpression).map { NSRange($0, in: line) } ?? NSRange(location: 0, length: 0)
            return (existing, line.hasPrefix(prefix) ? "" : prefix)
        }
    }

    /// 选区所在各行加 / 去行首标记（引用、列表）
    private func toggleLinePrefix(_ prefix: String, pattern: String) {
        guard let ns = textStorage?.string as NSString? else { return }
        let lines = ns.lineRange(for: selectedRange())
        var src: [String] = []
        ns.substring(with: lines).enumerateLines { line, _ in src.append(line) }
        let allHave = !src.isEmpty && src.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil }
        editLinePrefixes { line in
            if allHave {
                // 去掉标记，保留前导缩进（pattern 的第 1 组）
                guard let m = line.range(of: pattern, options: .regularExpression) else { return nil }
                let matched = String(line[m])
                let indent = matched.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
                return (NSRange(location: 0, length: (matched as NSString).length), indent)
            }
            return (NSRange(location: 0, length: 0), prefix)
        }
    }

    /// 对选区覆盖的每一行，只替换行首一小段（`edit` 返回行内要替换的范围与新文本；nil = 这行不动）。
    /// 不整段替换：撤销是一组、归属只落在真正改动的字符、光标 / 选区按位移修正
    private func editLinePrefixes(_ edit: (String) -> (NSRange, String)?) {
        guard let ns = textStorage?.string as NSString? else { return }
        let sel = selectedRange()
        let lines = ns.lineRange(for: sel)
        var edits: [(NSRange, String)] = []
        var loc = lines.location
        while loc < lines.location + lines.length {
            let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
            let line = ns.substring(with: lr).trimmingCharacters(in: .newlines)
            if let (r, text) = edit(line), !(r.length == 0 && text.isEmpty) { edits.append((NSRange(location: lr.location + r.location, length: r.length), text)) }
            loc = lr.location + lr.length
            if lr.length == 0 { break }
        }
        guard !edits.isEmpty else { return }
        undoManager?.beginUndoGrouping()
        var shift = 0
        for (r, text) in edits {   // 已按位置升序
            insertText(text, replacementRange: NSRange(location: r.location + shift, length: r.length))
            shift += (text as NSString).length - r.length
        }
        undoManager?.endUndoGrouping()
        let newLen = max(0, lines.length + shift - (ns.substring(with: lines).hasSuffix("\n") ? 1 : 0))
        setSelectedRange(NSRange(location: lines.location, length: newLen))
    }

    /// 选区第一行在本视图坐标里的矩形（浮动工具条定位用）
    public func firstLineRect(for range: NSRange) -> NSRect? {
        guard let tlm = textLayoutManager, let cs = textContentStorage,
              let loc = cs.location(cs.documentRange.location, offsetBy: range.location) else { return nil }
        var frag: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: loc, options: [.ensuresLayout]) { f in frag = f; return false }
        guard let frag else { return nil }
        let rel = range.location - cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location)
        var r = frag.layoutFragmentFrame
        for line in frag.textLineFragments where rel >= line.characterRange.location && rel <= line.characterRange.location + line.characterRange.length {
            r = CGRect(x: frag.layoutFragmentFrame.minX + line.typographicBounds.minX, y: frag.layoutFragmentFrame.minY + line.typographicBounds.minY, width: line.typographicBounds.width, height: line.typographicBounds.height)
            break
        }
        return r.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
    }

    // MARK: - 浮动格式工具条
    private var formatToolbar: FormatToolbar?
    /// 开关（设置）；挂到滚动视图上
    public var showsFormatToolbar = true { didSet { if !showsFormatToolbar { formatToolbar?.isHidden = true } else { updateFormatToolbar() } } }
    public func updateFormatToolbar() {
        guard showsFormatToolbar, let sv = enclosingScrollView else { formatToolbar?.isHidden = true; return }
        if formatToolbar == nil {
            let t = FormatToolbar(editor: self)
            sv.addSubview(t, positioned: .above, relativeTo: nil)
            formatToolbar = t
        }
        formatToolbar?.update()
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard selectedRange().length > 0 else { return menu }
        menu.insertItem(.separator(), at: 0)
        let items: [(String, Selector)] = [(RL("列表"), #selector(toggleBulletList(_:))), (RL("引用"), #selector(toggleQuote(_:))), ("H3", #selector(setHeading3(_:))), ("H2", #selector(setHeading2(_:))), ("H1", #selector(setHeading1(_:))),
                                           (RL("链接"), #selector(insertLink(_:))), (RL("行内代码"), #selector(toggleInlineCode(_:))), (RL("删除线"), #selector(toggleStrikethrough(_:))), (RL("斜体"), #selector(toggleItalic(_:))), (RL("粗体"), #selector(toggleBold(_:)))]
        for (title, sel) in items { let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.target = self; menu.insertItem(it, at: 0) }
        return menu
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
