import AppKit
import QuireCore

/// 只读 Markdown 阅读视图（TextKit 2）。
/// - 内容列居中并受 `maxContentWidth` 约束
/// - 自定义布局片段绘制代码块背景 / 引用条 / 分割线
/// - 复制时把代码块内 U+2028 换回换行
/// - 图片异步加载 + downsample
@MainActor
public class ReaderTextView: NSTextView, @preconcurrency NSTextLayoutManagerDelegate {   // 非 final：HybridTextView 继承
    public private(set) var style: RenderStyle
    /// 当前文档路径（相对图片解析）
    public var baseURL: URL?
    /// 已渲染文档（用于块范围查询）
    public private(set) var rendered: RenderedDocument?
    private lazy var overlays = CodeBlockOverlayController(textView: self)
    /// 是否显示代码块复制按钮
    public var showsCodeCopyButtons = true { didSet { if !showsCodeCopyButtons { overlays.removeAll() } else { overlays.setNeedsUpdate() } } }

    public init(style: RenderStyle) {
        self.style = style
        // TextKit 2 栈
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        layoutManager.delegate = self
        commonInit()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// 拖入 Markdown 文件（App 层决定打开方式）
    public var onDropFiles: (([URL]) -> Void)?

    private func commonInit() {
        registerForDraggedTypes([.fileURL])
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        allowsUndo = false
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
        displaysLinkToolTips = true
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        applyStyleChrome()
    }

    private func applyStyleChrome() {
        backgroundColor = style.background
        insertionPointColor = style.foreground
        selectedTextAttributes = [.backgroundColor: style.selection]
        linkTextAttributes = [.foregroundColor: style.accent, .cursor: NSCursor.pointingHand]
        textContainerInset = CGSize(width: style.horizontalPadding, height: style.verticalPadding)
        updateContentInsets()
    }

    // MARK: - 内容

    /// 装配已渲染文档（主线程，O(文档长度) 的一次 setAttributedString）
    public func setRendered(_ doc: RenderedDocument, style: RenderStyle) {
        self.style = style
        self.rendered = doc
        applyStyleChrome()
        guard let ts = textContentStorage?.textStorage else { return }
        // 先清空再整体设置：已有布局时直接 setAttributedString 会让 TextKit 2 逐段落对账旧元素
        //（1 MB 文档实测 4.3 s，主线程卡死）；清空后再设只需 ~10 ms（与首次设置一样）。
        if ts.length > 0 {
            ts.beginEditing(); ts.setAttributedString(NSAttributedString()); ts.endEditing()
        }
        ts.beginEditing()
        ts.setAttributedString(doc.attributed)
        ts.endEditing()
        // 渲染时按主题的最大列宽算的附件尺寸（独立公式 / 命中缓存的 Mermaid）要按真实列宽再收一次
        lastFittedWidth = contentWidth
        fitAttachmentsToWidth()
        if loadsAttachmentsAutomatically { loadImages() }
    }

    /// 打印 / 导出视图设为 false：不要在 setRendered 里异步起加载，而是 `loadAllAttachmentsForExport()` 等全部就绪
    public var loadsAttachmentsAutomatically = true

    /// 仅更新块表（内容未变，如 diff 为空）
    public func updateRendered(_ doc: RenderedDocument) { self.rendered = doc }

    /// 增量替换若干块（M3 编辑器路径）
    public func replaceBlocks(with doc: RenderedDocument, diff: BlockDiff, previous: RenderedDocument) {
        guard let ts = textContentStorage?.textStorage else { return setRendered(doc, style: style) }
        // 旧文档中被替换的字符范围
        let oldStart = diff.oldChanged.lowerBound < previous.ranges.count ? previous.ranges[diff.oldChanged.lowerBound].location : ts.length
        let oldEnd = diff.oldChanged.upperBound - 1 < previous.ranges.count && diff.oldChanged.upperBound > diff.oldChanged.lowerBound
            ? previous.ranges[diff.oldChanged.upperBound - 1].location + previous.ranges[diff.oldChanged.upperBound - 1].length : oldStart
        let replacement = NSMutableAttributedString()
        for i in diff.newChanged { replacement.append(doc.blocks[i].attributed) }
        ts.beginEditing()
        ts.replaceCharacters(in: NSRange(location: oldStart, length: oldEnd - oldStart), with: replacement)
        ts.endEditing()
        self.rendered = doc
        loadImages(blocks: diff.newChanged)
    }

    public override var isOpaque: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsCodeCopyButtons { overlays.setNeedsUpdate() }
    }

    // MARK: - 布局：内容列居中

    private var lastFittedWidth: CGFloat = 0
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContentInsets()
        // 宽度变化：把超宽的图片 / Mermaid 附件重新缩放到内容列宽
        if abs(contentWidth - lastFittedWidth) > 1 {
            lastFittedWidth = contentWidth
            fitAttachmentsToWidth()
        }
    }

    /// 块级图片的显示尺寸：作者指定宽度（HTML width / {width=…}）优先，再不超过内容列宽；`apply(image:)` 与 `fitAttachmentsToWidth` 共用这一个算法
    /// （以前两处各算一套：窗口一变宽，作者指定的宽度就被"恢复到自然尺寸"盖掉）
    nonisolated static func displaySize(natural: CGSize, requested: ImageAttachment.RequestedWidth?, maxWidth: CGFloat, inline: Bool, baseSize: CGFloat) -> CGSize {
        var size = natural
        if size.width <= 0 || size.height <= 0 { size = CGSize(width: 100, height: 100) }
        var w = size.width, h = size.height
        if inline {
            let inlineMaxH = baseSize * 1.5
            if h > inlineMaxH { w *= inlineMaxH / h; h = inlineMaxH }
        }
        if let req = requested {
            let target: CGFloat = switch req { case .points(let p): p; case .fraction(let f): maxWidth * f }
            if target > 0 { h *= target / w; w = target }
        }
        if w > maxWidth { h *= maxWidth / w; w = maxWidth }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// 让块级图片 / Mermaid / 独立公式附件的显示宽度不超过内容列宽（保持纵横比、尊重作者指定宽度）
    func fitAttachmentsToWidth() {
        guard let ts = textStorage, ts.length > 0 else { return }
        let maxW = max(100, contentWidth)
        var changes: [(NSTextAttachment, NSRange)] = []
        forEachLoadableAttachment(includeMath: true) { att, r in
            guard let img = att.image else { return }
            let natural = img.size
            guard natural.width > 0, natural.height > 0 else { return }
            var target: CGSize
            if let ia = att as? ImageAttachment {
                guard !ia.isInline, ia.isLoaded else { return }
                target = Self.displaySize(natural: natural, requested: ia.requestedWidth, maxWidth: maxW, inline: false, baseSize: style.baseSize)
            } else if let m = att as? MermaidAttachment {
                guard m.isRendered else { return }
                target = Self.displaySize(natural: natural, requested: nil, maxWidth: maxW, inline: false, baseSize: style.baseSize)
            } else if let math = att as? MathAttachment, math.isDisplay {
                target = Self.displaySize(natural: natural, requested: nil, maxWidth: maxW, inline: false, baseSize: style.baseSize)
            } else { return }
            if abs(att.bounds.width - target.width) > 0.5 {
                att.bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)
                changes.append((att, r))
            }
        }
        guard !changes.isEmpty else { return }
        ts.beginEditing()
        for (att, r) in changes { ts.addAttribute(.attachment, value: att, range: r) }
        ts.endEditing()
    }

    /// 只在标记了 hasLoadableAttachments 的块里枚举图片 / Mermaid 附件（避免全文属性枚举，1 MB 文档 ~100 ms/次）
    private func forEachLoadableAttachment(blocks blockRange: Range<Int>? = nil, includeMath: Bool = false, _ body: (NSTextAttachment, NSRange) -> Void) {
        guard let ts = textStorage, let rendered else { return }
        let indices = blockRange.map { $0.clamped(to: 0..<rendered.blocks.count) } ?? 0..<rendered.blocks.count
        for i in indices where rendered.blocks[i].hasLoadableAttachments || (includeMath && { if case .math = rendered.blocks[i].block.kind { true } else { false } }()) {
            let r = rendered.ranges[i]
            guard r.location + r.length <= ts.length else { continue }
            ts.enumerateAttribute(.attachment, in: r, options: [.longestEffectiveRangeNotRequired]) { value, range, _ in
                if let att = value as? NSTextAttachment { body(att, range) }
            }
        }
    }

    private func updateContentInsets() {
        if fixedPrintingWidth != nil { textContainerInset = .zero; return }
        let w = bounds.width
        let maxW = style.maxContentWidth
        var inset = style.horizontalPadding
        if maxW > 0, w - inset * 2 > maxW {
            inset = ((w - maxW) / 2).rounded(.down)
        }
        if textContainerInset.width != inset {
            textContainerInset = CGSize(width: inset, height: style.verticalPadding)
        }
        // 容器宽度显式跟随（widthTracksTextView 只在 frame 变化时更新，inset 变化时不会）
        let cw = max(50, w - inset * 2)
        if let c = textContainer, abs(c.size.width - cw) > 0.5 {
            c.size = CGSize(width: cw, height: .greatestFiniteMagnitude)
        }
    }

    /// 内容列宽度（pt）
    public var contentWidth: CGFloat { bounds.width - textContainerInset.width * 2 }

    /// NSTextView（TextKit 2）在某些布局时序下会用过期的容器宽度做水平居中，导致 origin 漂移；
    /// 内容列位置完全由 textContainerInset 决定，这里固定下来。
    public override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }

    private var fixedPrintingWidth: CGFloat?
    /// 打印 / PDF：固定容器宽度，忽略 maxContentWidth 居中逻辑
    public func setPrintingWidth(_ w: CGFloat) {
        fixedPrintingWidth = w
        textContainerInset = .zero
        textContainer?.size = CGSize(width: w, height: .greatestFiniteMagnitude)
        setFrameSize(NSSize(width: w, height: frame.height))
    }
    /// 强制全部布局并把 frame 高度撑到内容高度（打印分页需要）
    public func layoutAllForPrinting() {
        guard let tlm = textLayoutManager else { return }
        tlm.ensureLayout(for: tlm.documentRange)
        var maxY: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: nil, options: [.reverse, .ensuresLayout]) { frag in
            maxY = frag.layoutFragmentFrame.maxY; return false
        }
        setFrameSize(NSSize(width: frame.width, height: maxY.rounded(.up) + 1))
        pageRects = nil
    }

    // MARK: - 打印分页（TextKit 2 片段边界；NSTextView 自带的分页走 TextKit 1 路径，不可用）

    private var pageRects: [CGRect]?

    /// 打印：标题不孤行——标题落在页尾而正文被挤到下一页时，把标题一起带过去
    public var keepHeadingsWithNext = false
    /// 打印分页结果（页数给页眉 / 页脚用）
    public var printedPageCount: Int { pageRects?.count ?? 1 }
    /// 打印：页眉 / 页脚（页号从 1 起）；nil = 不画。走 AppKit 自带的 pageHeader / pageFooter 机制
    /// （NSPrintInfo 的 headerAndFooter = true 时 drawPageBorder 默认实现会画）——别自己重写 drawPageBorder 改 frame，
    /// NSTextView 的 frame 一动就触发 TextKit 重排，分页矩形随之失效（实测第 2 页起画错内容）
    public var printHeaderFooter: ((_ page: Int, _ pages: Int) -> (header: NSAttributedString?, footer: NSAttributedString?))?

    public override var pageHeader: NSAttributedString {
        guard let printHeaderFooter, let op = NSPrintOperation.current else { return NSAttributedString() }
        return printHeaderFooter(op.currentPage, printedPageCount).header ?? NSAttributedString()
    }
    public override var pageFooter: NSAttributedString {
        guard let printHeaderFooter, let op = NSPrintOperation.current else { return NSAttributedString() }
        return printHeaderFooter(op.currentPage, printedPageCount).footer ?? NSAttributedString()
    }

    private func computePageRects(pageHeight: CGFloat) -> [CGRect] {
        guard let tlm = textLayoutManager, pageHeight > 10 else { return [bounds] }
        var rects: [CGRect] = []
        var pageTop: CGFloat = 0
        var lastBottom: CGFloat = 0
        var lastTop: CGFloat = 0
        var lastWasHeading = false
        let width = bounds.width
        let keep = keepHeadingsWithNext
        tlm.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { frag in
            let f = frag.layoutFragmentFrame
            let top = f.minY + self.textContainerInset.height
            let bottom = f.maxY + self.textContainerInset.height
            if bottom - pageTop > pageHeight {
                // 当前片段放不下：在它之前分页（若它本身超过一页，硬切）；前一片是标题则连标题一起带到下一页
                let breakAt = (keep && lastWasHeading && lastTop > pageTop) ? lastTop : lastBottom
                if breakAt > pageTop { rects.append(CGRect(x: 0, y: pageTop, width: width, height: breakAt - pageTop)); pageTop = breakAt }
                while bottom - pageTop > pageHeight {
                    rects.append(CGRect(x: 0, y: pageTop, width: width, height: pageHeight)); pageTop += pageHeight
                }
            }
            lastBottom = bottom
            lastTop = top
            lastWasHeading = keep && (frag as? BlockLayoutFragment)?.isHeading == true
            return true
        }
        if lastBottom > pageTop { rects.append(CGRect(x: 0, y: pageTop, width: width, height: lastBottom - pageTop)) }
        return rects.isEmpty ? [bounds] : rects
    }

    /// 打印坐标系里的标题位置（块下标、级别、标题、y）；要先 layoutAllForPrinting
    public func headingPositions() -> [(index: Int, level: Int, title: String, y: CGFloat)] {
        guard let rendered else { return [] }
        var out: [(Int, Int, String, CGFloat)] = []
        for (i, b) in rendered.blocks.enumerated() {
            guard case .heading(let level, let inl, _) = b.block.kind, let frag = layoutFragment(atCharacter: rendered.ranges[i].location) else { continue }
            out.append((i, level, inl.plainText.trimmingCharacters(in: .whitespaces), frag.layoutFragmentFrame.minY + textContainerInset.height))
        }
        return out
    }

    /// y → (页号从 0 起, 页内距顶偏移)；按与打印相同的分页算
    public func pagePlacement(forY y: CGFloat, pageHeight: CGFloat) -> (page: Int, offset: CGFloat) {
        let rects = computePageRects(pageHeight: pageHeight)
        for (i, r) in rects.enumerated() where y < r.maxY { return (i, max(0, y - r.minY)) }
        return (max(0, rects.count - 1), 0)
    }

    public override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        guard fixedPrintingWidth != nil, let op = NSPrintOperation.current else { return super.knowsPageRange(range) }
        let info = op.printInfo
        let pageHeight = (info.paperSize.height - info.topMargin - info.bottomMargin).rounded(.down)
        if pageRects == nil { pageRects = computePageRects(pageHeight: pageHeight) }
        range.pointee = NSRange(location: 1, length: pageRects!.count)
        return true
    }

    public override func rectForPage(_ page: Int) -> NSRect {
        guard fixedPrintingWidth != nil, let rects = pageRects, page >= 1, page <= rects.count else { return super.rectForPage(page) }
        return rects[page - 1]
    }



    // MARK: - NSTextLayoutManagerDelegate

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let f = BlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
        f.style = style
        return f
    }

    // MARK: - 拖放：Markdown 文件 → 打开

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropSupport.fileURLs(from: sender).contains(where: DropSupport.isMarkdown) ? .copy : []
    }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DropSupport.fileURLs(from: sender).filter(DropSupport.isMarkdown)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    // MARK: - 点击图片

    /// 点击块级/行内图片：回调图片来源（App 层决定用系统打开还是自己看图）
    public var onImageClick: ((String) -> Void)?

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let ts = textStorage, onImageClick != nil {
            let p = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: p)
            if idx < ts.length, let att = ts.attribute(.attachment, at: idx, effectiveRange: nil) as? ImageAttachment, att.isLoaded, let src = att.source {
                // 确认点在附件的实际矩形内（characterIndexForInsertion 可能落在附件旁边）
                if let tlm = textLayoutManager, let cs = textContentStorage, let loc = cs.location(cs.documentRange.location, offsetBy: idx),
                   let frag = tlm.textLayoutFragment(for: loc) {
                    var r = frag.frameForTextAttachment(at: loc)
                    r.origin.x += frag.layoutFragmentFrame.minX + textContainerInset.width
                    r.origin.y += frag.layoutFragmentFrame.minY + textContainerInset.height
                    if r.contains(p) { onImageClick?(src); return }
                }
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: - 复制：U+2028 → \n

    public override func copy(_ sender: Any?) {
        guard let ts = textStorage, selectedRange().length > 0 else { return super.copy(sender) }
        let sub = ts.attributedSubstring(from: selectedRange())
        let plain = sub.string.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2009}", with: "")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(plain, forType: .string)
        // 同时提供 RTF（保留样式），但换行也修正
        let m = NSMutableAttributedString(attributedString: sub)
        m.mutableString.replaceOccurrences(of: "\u{2028}", with: "\n", range: NSRange(location: 0, length: m.length))
        if let rtf = try? m.data(from: NSRange(location: 0, length: m.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pb.setData(rtf, forType: .rtf)
        }
    }

    // MARK: - 图片

    /// 扫描附件，异步加载未加载的图片 / 渲染 Mermaid（可见区域优先）
    /// 触发图片 / Mermaid 异步加载。只枚举标记了 hasLoadableAttachments 的块（`blockRange` 可再限定块下标范围，
    /// 增量替换时只看被替换的块），不对整份文档做属性枚举。
    public func loadImages(blocks blockRange: Range<Int>? = nil) {
        guard let ts = textStorage, ts.length > 0, let rendered else { return }
        // 收集后按"离视口的距离"排序：Mermaid 渲染是串行的，先渲染看得见的
        var pending: [(NSTextAttachment, NSRange)] = []
        forEachLoadableAttachment(blocks: blockRange) { value, range in
            if let m = value as? MermaidAttachment, !m.isRendered, !m.failed { pending.append((m, range)) }
            else if let a = value as? ImageAttachment, !a.isLoaded, !a.loadFailed, a.source != nil { pending.append((a, range)) }
            else if let t = value as? TableAttachment, t.cellImageAttachments.contains(where: { !$0.isLoaded && !$0.loadFailed && $0.source != nil }) { pending.append((t, range)) }
        }
        guard !pending.isEmpty else { return }
        let visibleTop = topVisibleBlockIndex().flatMap { rendered.ranges[$0].location } ?? 0
        pending.sort { abs($0.1.location - visibleTop) < abs($1.1.location - visibleTop) }
        load(pending)
    }

    /// 表格单元格里的图片：逐个加载，每张到了就让表格重排
    private func loadTableCellImages(_ table: TableAttachment, at range: NSRange) {
        let scale = window?.backingScaleFactor ?? 2
        let maxW = style.baseSize * 12
        for att in table.cellImageAttachments where !att.isLoaded && !att.loadFailed {
            guard let src = att.source, let url = ImageLoader.resolve(src, relativeTo: baseURL) else { att.loadFailed = true; continue }
            ImageLoader.shared.load(url, maxPixelWidth: maxW * scale) { [weak self, weak table] image in
                guard let self, let table else { return }
                if let image {
                    att.isLoaded = true
                    image.accessibilityDescription = att.altText.isEmpty ? RL("图片") : att.altText
                    let size = Self.displaySize(natural: image.size, requested: att.requestedWidth, maxWidth: maxW, inline: true, baseSize: self.style.baseSize)
                    att.image = image
                    att.bounds = CGRect(x: 0, y: -(size.height * 0.25), width: size.width, height: size.height)
                } else { att.loadFailed = true }
                table.invalidateLayout()
                self.relayoutAttachment(table, hint: range)
            }
        }
    }

    /// 加载任意字符范围里的附件（混合模式的实时预览：预览串是临时拼进 textStorage 的，不在 rendered 的块表里）
    public func loadAttachments(in range: NSRange) {
        guard let ts = textStorage, range.location + range.length <= ts.length, range.length > 0 else { return }
        var pending: [(NSTextAttachment, NSRange)] = []
        ts.enumerateAttribute(.attachment, in: range, options: [.longestEffectiveRangeNotRequired]) { value, r, _ in
            if let m = value as? MermaidAttachment, !m.isRendered, !m.failed { pending.append((m, r)) }
            else if let a = value as? ImageAttachment, !a.isLoaded, !a.loadFailed, a.source != nil { pending.append((a, r)) }
        }
        load(pending)
    }

    private func load(_ pending: [(NSTextAttachment, NSRange)]) {
        guard !pending.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? 2
        let maxW = max(200, contentWidth)
        for (value, range) in pending {
            if let m = value as? MermaidAttachment {
                renderMermaid(m, at: range, maxWidth: maxW)
                continue
            }
            if let t = value as? TableAttachment { loadTableCellImages(t, at: range); continue }
            guard let att = value as? ImageAttachment, let src = att.source else { continue }
            guard let url = ImageLoader.resolve(src, relativeTo: baseURL) else { att.loadFailed = true; continue }
            let inline = att.isInline
            let targetMaxWidth = inline ? style.baseSize * 12 : maxW
            ImageLoader.shared.load(url, maxPixelWidth: targetMaxWidth * scale) { [weak self] image in
                guard let self else { return }
                self.apply(image: image, to: att, at: range, maxWidth: targetMaxWidth, inline: inline)
            }
        }
    }

    private func renderMermaid(_ att: MermaidAttachment, at range: NSRange, maxWidth: CGFloat) {
        Task { @MainActor [weak self] in await self?.renderMermaidNow(att, at: range, maxWidth: maxWidth) }
    }

    private func renderMermaidNow(_ att: MermaidAttachment, at range: NSRange, maxWidth: CGFloat) async {
        do {
            let bg = style.theme.colors.background.hexString
            let img = try await MermaidRenderer.shared.render(source: att.source, theme: att.mermaidTheme, background: bg)
            att.isRendered = true
            var w = img.size.width, h = img.size.height
            if w > maxWidth { h *= maxWidth / w; w = maxWidth }
            img.accessibilityDescription = RL("Mermaid 图") + "\n" + att.source
            att.image = img
            att.bounds = CGRect(x: 0, y: 0, width: w.rounded(), height: h.rounded())
        } catch {
            att.failed = true
            let msg = String(format: RL("Mermaid 渲染失败：%@"), String(describing: error))
            let img = Self.errorImage(message: msg, source: att.source, width: maxWidth, style: style)
            att.image = img
            att.bounds = CGRect(origin: .zero, size: img.size)
        }
        relayoutAttachment(att, hint: range)
    }

    /// 导出 / 打印：把全部图片与 Mermaid 加载完再返回（并发；整体超时后带着已完成的部分返回）。
    /// `setRendered` 里的异步加载对打印没用——`NSPrintOperation.run()` 是同步的，跑完时图片还没回来，PDF 里全是占位框。
    public func loadAllAttachmentsForExport(timeout: TimeInterval = 20) async {
        guard let rendered, !rendered.blocks.isEmpty else { return }
        let maxW = max(200, contentWidth)
        let scale: CGFloat = 2
        var images: [(ImageAttachment, NSRange, URL, Bool)] = []   // (附件, 所在范围, URL, 在表格单元格里)
        var diagrams: [(MermaidAttachment, NSRange)] = []
        var tables: [(TableAttachment, NSRange)] = []
        forEachLoadableAttachment { value, range in
            if let m = value as? MermaidAttachment, !m.isRendered, !m.failed { diagrams.append((m, range)) }
            else if let a = value as? ImageAttachment, !a.isLoaded, !a.loadFailed, let src = a.source {
                if let url = ImageLoader.resolve(src, relativeTo: baseURL) { images.append((a, range, url, false)) } else { a.loadFailed = true }
            } else if let t = value as? TableAttachment {
                var any = false
                for a in t.cellImageAttachments where !a.isLoaded && !a.loadFailed {
                    guard let src = a.source, let url = ImageLoader.resolve(src, relativeTo: baseURL) else { a.loadFailed = true; continue }
                    images.append((a, range, url, true)); any = true
                }
                if any { tables.append((t, range)) }
            }
        }
        guard !images.isEmpty || !diagrams.isEmpty else { return }
        // 图片：全部同时发起（ImageLoader 内部并发解码），一个 continuation 等计数归零；超时直接放行
        if !images.isEmpty {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                final class Gate { var remaining: Int; var finished = false; init(_ n: Int) { remaining = n } }
                let gate = Gate(images.count)
                let finish: @MainActor () -> Void = { guard !gate.finished else { return }; gate.finished = true; done.resume() }
                for (att, range, url, inCell) in images {
                    let inline = att.isInline || inCell
                    let target = inline ? style.baseSize * 12 : maxW
                    ImageLoader.shared.load(url, maxPixelWidth: target * scale) { [weak self] img in
                        self?.apply(image: img, to: att, at: range, maxWidth: target, inline: inline)
                        gate.remaining -= 1
                        if gate.remaining <= 0 { finish() }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
            }
            for (t, range) in tables { t.invalidateLayout(); relayoutAttachment(t, hint: range) }
        }
        // Mermaid：渲染器本身串行，逐个 await
        let deadline = Date().addingTimeInterval(timeout)
        for (att, range) in diagrams where Date() < deadline {
            await renderMermaidNow(att, at: range, maxWidth: maxW)
        }
    }

    /// 错误框：消息 + 源码（等宽）
    static func errorImage(message: String, source: String, width: CGFloat, style: RenderStyle?) -> NSImage {
        let font = style?.codeFont ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let msgAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.systemRed]
        let srcAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style?.codeForeground ?? .labelColor]
        let pad: CGFloat = 12
        let m = NSAttributedString(string: message, attributes: msgAttrs)
        let src = NSAttributedString(string: source, attributes: srcAttrs)
        let inner = width - pad * 2
        let mh = m.boundingRect(with: CGSize(width: inner, height: 1000), options: [.usesLineFragmentOrigin]).height.rounded(.up)
        let sh = src.boundingRect(with: CGSize(width: inner, height: 4000), options: [.usesLineFragmentOrigin]).height.rounded(.up)
        let size = CGSize(width: width, height: mh + sh + pad * 3)
        return NSImage(size: size, flipped: true) { rect in
            (style?.codeBackground ?? NSColor.windowBackgroundColor).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            NSColor.systemRed.withAlphaComponent(0.4).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
            m.draw(with: CGRect(x: pad, y: pad, width: inner, height: mh), options: [.usesLineFragmentOrigin])
            src.draw(with: CGRect(x: pad, y: pad * 2 + mh, width: inner, height: sh), options: [.usesLineFragmentOrigin])
            return true
        }
    }

    /// 附件内容/尺寸变化后触发该处重排（附件位置可能已变化：按对象重新定位）。
    /// 重排会改变文档高度，TextKit 2 可能把视口漂到该块 —— 用"顶部块 + 块内偏移"锁住可见位置。
    private func relayoutAttachment(_ att: NSTextAttachment, hint range: NSRange) {
        guard let ts = textStorage else { return }
        var target = range
        if range.location >= ts.length || (ts.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment) !== att {
            var found: NSRange?
            forEachLoadableAttachment { v, r in if found == nil, v === att { found = r } }
            guard let f = found else { return }
            target = f
        }
        let anchor = captureScrollAnchor()
        ts.beginEditing()
        ts.addAttribute(.attachment, value: att, range: target)
        ts.endEditing()
        restoreScrollAnchor(anchor)
    }

    /// 可见位置锚点：顶部块下标 + 视口顶到该块顶的偏移
    private func captureScrollAnchor() -> (Int, CGFloat)? {
        guard let idx = topVisibleBlockIndex(), enclosingScrollView != nil, visibleTop > 0 else { return nil }
        return (idx, scrollOffset(withinBlock: idx))
    }

    private func restoreScrollAnchor(_ anchor: (Int, CGFloat)?) {
        guard let (idx, offset) = anchor, let rendered, idx < rendered.ranges.count, let sv = enclosingScrollView,
              let frag = layoutFragment(atCharacter: rendered.ranges[idx].location) else { return }
        let y = max(-topInset, frag.layoutFragmentFrame.minY + textContainerInset.height + offset - topInset)
        if abs(y - sv.contentView.bounds.minY) > 0.5 {
            sv.contentView.setBoundsOrigin(CGPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    private func apply(image: NSImage?, to att: ImageAttachment, at range: NSRange, maxWidth: CGFloat, inline: Bool) {
        guard let image else {
            // 加载失败和"还在加载"要分得开：换成错误框（带路径），而不是永远停在灰色占位
            att.loadFailed = true
            let msg = String(format: RL("图片加载失败：%@"), att.source ?? "")
            let img = Self.errorImage(message: msg, source: att.altText, width: inline ? style.baseSize * 12 : maxWidth, style: style)
            att.image = img
            att.bounds = CGRect(origin: .zero, size: inline ? CGSize(width: min(img.size.width, style.baseSize * 12), height: style.baseSize * 1.5) : img.size)
            relayoutAttachment(att, hint: range)
            return
        }
        att.isLoaded = true
        image.accessibilityDescription = att.altText.isEmpty ? RL("图片") : att.altText
        let size = Self.displaySize(natural: image.size, requested: att.requestedWidth, maxWidth: maxWidth, inline: inline, baseSize: style.baseSize)
        att.image = image
        att.bounds = CGRect(x: 0, y: inline ? -(size.height * 0.25) : 0, width: size.width, height: size.height)
        relayoutAttachment(att, hint: range)
    }

    // MARK: - 定位

    /// 目标块顶部与视口顶部的留白
    static let scrollTopMargin: CGFloat = 8

    /// 滚动到某个顶级块顶部；`completion` 在动画结束（或立即）时调用。
    /// TextKit 2 对视口外内容只估算高度，直接按估算 y 滚会落空；策略：先用 NSTextView 自己的
    /// scrollRangeToVisible 把目标拉进视口（内部会处理估算修正），再按真实片段位置对齐到顶部，必要时再修一次。
    /// 保证已布局的片段（TextKit 2 对未布局位置的 `textLayoutFragment(for:)` 会返回错误的片段）
    func layoutFragment(atCharacter offset: Int) -> NSTextLayoutFragment? {
        guard let tlm = textLayoutManager, let cs = textContentStorage,
              let loc = cs.location(cs.documentRange.location, offsetBy: offset) else { return nil }
        var result: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: loc, options: [.ensuresLayout]) { f in result = f; return false }
        return result
    }

    /// 滚动视图顶部被工具栏 / 标签栏盖住的高度（`automaticallyAdjustsContentInsets`）：
    /// 可见区顶部 = bounds.minY + 这个值；滚到顶时 bounds.minY 是负的
    private var topInset: CGFloat { enclosingScrollView?.contentInsets.top ?? 0 }
    /// 可见区顶部在文档坐标里的 y
    private var visibleTop: CGFloat { (enclosingScrollView?.contentView.bounds.minY ?? 0) + topInset }

    /// 滚到块顶（块顶在可见区顶部下方 scrollTopMargin），或按 offset（可见区顶到块顶的偏移）恢复位置。
    /// TextKit 2 是估算布局：先按估算位置滚过去，视口真实布局后再对齐，直到稳定。
    public func scroll(toBlock index: Int, animated: Bool = false, offset: CGFloat = 0, completion: (@MainActor () -> Void)? = nil) {
        guard let rendered, index < rendered.ranges.count, let sv = enclosingScrollView, let tlm = textLayoutManager else { completion?(); return }
        let r = rendered.ranges[index]
        let clip = sv.contentView
        if index == 0, offset <= 0 {
            clip.setBoundsOrigin(CGPoint(x: 0, y: -topInset)); sv.reflectScrolledClipView(clip); completion?(); return
        }
        let align: () -> CGPoint? = { [weak self] in
            guard let self, let frag = self.layoutFragment(atCharacter: r.location) else { return nil }
            // 目标是"可见区顶部"，bounds.minY 还要再减去被盖住的 topInset。
            // 不在这里按 frame 高度夹紧：内容刚替换时 frame 只是估算，会把目标夹到很靠前
            let y = frag.layoutFragmentFrame.minY + self.textContainerInset.height + (offset == 0 ? -Self.scrollTopMargin : offset) - self.topInset
            return CGPoint(x: 0, y: max(-self.topInset, y))
        }
        // 同步收敛：设视口 → 布局视口 → 重算，最多 4 轮；最后按真实 frame 夹紧
        let settle: () -> Void = {
            for _ in 0..<4 {
                guard let t = align(), abs(t.y - clip.bounds.minY) > 0.5 else { break }
                clip.setBoundsOrigin(t)
                sv.reflectScrolledClipView(clip)
                tlm.textViewportLayoutController.layoutViewport()
            }
            let constrained = clip.constrainBoundsRect(clip.bounds)
            if abs(constrained.minY - clip.bounds.minY) > 0.5 { clip.setBoundsOrigin(constrained.origin); sv.reflectScrolledClipView(clip) }
        }
        guard let target = align() else { completion?(); return }
        if animated, abs(target.y - sv.contentView.bounds.minY) < sv.contentView.bounds.height * 3 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                sv.contentView.animator().setBoundsOrigin(target)
            }, completionHandler: {
                sv.reflectScrolledClipView(sv.contentView)
                settle()
                completion?()
            })
        } else {
            settle()
            DispatchQueue.main.async { settle(); completion?() }   // 下一轮再校一次（视口布局后的估算修正）
        }
    }

    /// 文档坐标 y 处的顶级块下标
    private func blockIndex(atY y: CGFloat) -> Int? {
        guard let rendered, let tlm = textLayoutManager, let cs = textContentStorage else { return nil }
        guard let frag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y - textContainerInset.height))) else { return nil }
        let offset = cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location)
        return rendered.blockIndex(at: offset)
    }

    /// 可见区顶部所在的顶级块下标（取样点在留白之下，保证刚滚到的目标块被算作"当前块"）。用于滚动同步 / 位置锚点。
    public func topVisibleBlockIndex() -> Int? {
        guard enclosingScrollView != nil else { return nil }
        return blockIndex(atY: visibleTop + Self.scrollTopMargin + 4)
    }

    /// 侧栏"当前章节"用的块下标：读者的注意力在可见区上部，不是最顶上一行——
    /// 取样点在可见区顶部往下 40%，下一标题升到屏幕中线以上就算读到它了；
    /// 顶上刚好是标题（如刚从侧栏跳过来）时以它为准；滚到底时取最后一块，让末章也能高亮。
    public func sectionBlockIndex() -> Int? {
        guard let rendered, let sv = enclosingScrollView else { return nil }
        let clip = sv.contentView
        if clip.bounds.maxY >= frame.height + sv.contentInsets.bottom - 1, !rendered.blocks.isEmpty { return rendered.blocks.count - 1 }
        if let top = topVisibleBlockIndex(), case .heading = rendered.blocks[top].block.kind { return top }
        let visibleH = clip.bounds.height - topInset - sv.contentInsets.bottom
        return blockIndex(atY: visibleTop + visibleH * 0.4)
    }

    /// 可见区顶部到指定块顶部的像素偏移（用于重载后恢复位置）
    public func scrollOffset(withinBlock index: Int) -> CGFloat {
        guard let rendered, index < rendered.ranges.count, enclosingScrollView != nil,
              let frag = layoutFragment(atCharacter: rendered.ranges[index].location) else { return 0 }
        return visibleTop - (frag.layoutFragmentFrame.minY + textContainerInset.height)
    }

    /// 恢复位置：块 index 顶部到视口顶部的偏移为 offset（由 scrollOffset(withinBlock:) 得到）
    public func scroll(toBlock index: Int, offset: CGFloat) {
        scroll(toBlock: index, animated: false, offset: offset)
    }
}

