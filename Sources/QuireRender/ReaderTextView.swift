import AppKit
import QuireCore

/// 只读 Markdown 阅读视图（TextKit 2）。
/// - 内容列居中并受 `maxContentWidth` 约束
/// - 自定义布局片段绘制代码块背景 / 引用条 / 分割线
/// - 复制时把代码块内 U+2028 换回换行
/// - 图片异步加载 + downsample
@MainActor
public final class ReaderTextView: NSTextView, @preconcurrency NSTextLayoutManagerDelegate {
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

    private func commonInit() {
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
        ts.beginEditing()
        ts.setAttributedString(doc.attributed)
        ts.endEditing()
        loadImages()
    }

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
        loadImages()
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

    /// 让块级图片 / Mermaid 附件的显示宽度不超过内容列宽（保持纵横比；缩小或恢复到自然尺寸）
    private func fitAttachmentsToWidth() {
        guard let ts = textStorage, ts.length > 0 else { return }
        let maxW = max(100, contentWidth)
        var changes: [(NSTextAttachment, NSRange)] = []
        ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length), options: [.longestEffectiveRangeNotRequired]) { v, r, _ in
            guard let att = v as? NSTextAttachment, let img = att.image else { return }
            let isBlockImage = (att as? ImageAttachment).map { !$0.isInline && $0.isLoaded } ?? false
            let isMermaid = (att as? MermaidAttachment)?.isRendered ?? false
            guard isBlockImage || isMermaid else { return }
            let natural = img.size
            guard natural.width > 0, natural.height > 0 else { return }
            var w = min(natural.width, maxW)
            let h = (natural.height * w / natural.width).rounded()
            w = w.rounded()
            if abs(att.bounds.width - w) > 0.5 {
                att.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                changes.append((att, r))
            }
        }
        guard !changes.isEmpty else { return }
        ts.beginEditing()
        for (att, r) in changes { ts.addAttribute(.attachment, value: att, range: r) }
        ts.endEditing()
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

    private func computePageRects(pageHeight: CGFloat) -> [CGRect] {
        guard let tlm = textLayoutManager, pageHeight > 10 else { return [bounds] }
        var rects: [CGRect] = []
        var pageTop: CGFloat = 0
        var lastBottom: CGFloat = 0
        let width = bounds.width
        tlm.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { frag in
            let f = frag.layoutFragmentFrame
            let bottom = f.maxY + self.textContainerInset.height
            if bottom - pageTop > pageHeight {
                // 当前片段放不下：在它之前分页（若它本身超过一页，硬切）
                if lastBottom > pageTop { rects.append(CGRect(x: 0, y: pageTop, width: width, height: lastBottom - pageTop)); pageTop = lastBottom }
                while bottom - pageTop > pageHeight {
                    rects.append(CGRect(x: 0, y: pageTop, width: width, height: pageHeight)); pageTop += pageHeight
                }
            }
            lastBottom = bottom
            return true
        }
        if lastBottom > pageTop { rects.append(CGRect(x: 0, y: pageTop, width: width, height: lastBottom - pageTop)) }
        return rects.isEmpty ? [bounds] : rects
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

    /// 打印时不画背景外的选区、光标等
    public override var isFlipped: Bool { true }

    // MARK: - NSTextLayoutManagerDelegate

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let f = BlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
        f.style = style
        return f
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

    public override func resetCursorRects() {
        super.resetCursorRects()
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

    private var imageRequestsInFlight = 0

    /// 扫描附件，异步加载未加载的图片 / 渲染 Mermaid（可见区域优先）
    public func loadImages() {
        guard let ts = textStorage, ts.length > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let maxW = max(200, contentWidth)
        // 收集后按"离视口的距离"排序：Mermaid 渲染是串行的，先渲染看得见的
        var pending: [(NSTextAttachment, NSRange)] = []
        ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length), options: [.longestEffectiveRangeNotRequired]) { value, range, _ in
            if let m = value as? MermaidAttachment, !m.isRendered, !m.failed { pending.append((m, range)) }
            else if let a = value as? ImageAttachment, !a.isLoaded, !a.loadFailed, a.source != nil { pending.append((a, range)) }
        }
        guard !pending.isEmpty else { return }
        let visibleTop = topVisibleBlockIndex().flatMap { rendered?.ranges[$0].location } ?? 0
        pending.sort { abs($0.1.location - visibleTop) < abs($1.1.location - visibleTop) }
        for (value, range) in pending {
            if let m = value as? MermaidAttachment {
                renderMermaid(m, at: range, maxWidth: maxW)
                continue
            }
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
        Task { @MainActor [weak self] in
            do {
                let bg = self?.style.theme.colors.background.hexString ?? "transparent"
                let img = try await MermaidRenderer.shared.render(source: att.source, theme: att.mermaidTheme, background: bg)
                att.isRendered = true
                var w = img.size.width, h = img.size.height
                if w > maxWidth { h *= maxWidth / w; w = maxWidth }
                att.image = img
                att.bounds = CGRect(x: 0, y: 0, width: w.rounded(), height: h.rounded())
            } catch {
                att.failed = true
                att.errorText = "\(error)"
                let msg = "Mermaid 渲染失败：\(error)"
                let img = Self.errorImage(message: msg, source: att.source, width: maxWidth, style: self?.style)
                att.image = img
                att.bounds = CGRect(origin: .zero, size: img.size)
            }
            self?.relayoutAttachment(att, hint: range)
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
            ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length), options: []) { v, r, stop in
                if (v as? NSTextAttachment) === att { found = r; stop.pointee = true }
            }
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
        guard let idx = topVisibleBlockIndex(), let sv = enclosingScrollView, sv.contentView.bounds.minY > 0 else { return nil }
        return (idx, scrollOffset(withinBlock: idx))
    }

    private func restoreScrollAnchor(_ anchor: (Int, CGFloat)?) {
        guard let (idx, offset) = anchor, let rendered, idx < rendered.ranges.count,
              let tlm = textLayoutManager, let cs = textContentStorage, let sv = enclosingScrollView,
              let loc = cs.location(cs.documentRange.location, offsetBy: rendered.ranges[idx].location) else { return }
        // 该块就在视口附近，布局是真实的
        tlm.ensureLayout(for: NSTextRange(location: loc))
        guard let frag = tlm.textLayoutFragment(for: loc) else { return }
        let y = max(0, frag.layoutFragmentFrame.minY + textContainerInset.height + offset)
        if abs(y - sv.contentView.bounds.minY) > 0.5 {
            sv.contentView.setBoundsOrigin(CGPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    private func apply(image: NSImage?, to att: ImageAttachment, at range: NSRange, maxWidth: CGFloat, inline: Bool) {
        guard let image else { att.loadFailed = true; return }
        att.isLoaded = true
        var size = image.size
        if size.width <= 0 || size.height <= 0 { size = CGSize(width: 100, height: 100) }
        let inlineMaxH = style.baseSize * 1.5
        var w = size.width, h = size.height
        if inline {
            if h > inlineMaxH { w *= inlineMaxH / h; h = inlineMaxH }
        }
        if w > maxWidth { h *= maxWidth / w; w = maxWidth }
        att.image = image
        att.bounds = CGRect(x: 0, y: inline ? -(h * 0.25) : 0, width: w.rounded(), height: h.rounded())
        relayoutAttachment(att, hint: range)
    }

    // MARK: - 定位

    /// 目标块顶部与视口顶部的留白
    static let scrollTopMargin: CGFloat = 8

    /// 滚动到某个顶级块顶部；`completion` 在动画结束（或立即）时调用。
    /// TextKit 2 对视口外内容只估算高度，直接按估算 y 滚会落空；策略：先用 NSTextView 自己的
    /// scrollRangeToVisible 把目标拉进视口（内部会处理估算修正），再按真实片段位置对齐到顶部，必要时再修一次。
    public func scroll(toBlock index: Int, animated: Bool = false, completion: (@MainActor () -> Void)? = nil) {
        guard let rendered, index < rendered.ranges.count, let sv = enclosingScrollView else { completion?(); return }
        let r = rendered.ranges[index]
        if index == 0 {
            sv.contentView.setBoundsOrigin(.zero); sv.reflectScrolledClipView(sv.contentView); completion?(); return
        }
        // 第一步：进入视口（非动画）
        scrollRangeToVisible(NSRange(location: r.location, length: 0))
        // 第二步：对齐到顶部（此时目标片段已真实布局）
        let align: () -> CGPoint? = { [weak self] in
            guard let self, let tlm = self.textLayoutManager, let cs = self.textContentStorage,
                  let loc = cs.location(cs.documentRange.location, offsetBy: r.location),
                  let frag = tlm.textLayoutFragment(for: loc) else { return nil }
            var y = frag.layoutFragmentFrame.minY + self.textContainerInset.height - Self.scrollTopMargin
            let maxY = max(0, self.frame.height - sv.contentView.bounds.height)
            y = min(max(0, y), maxY)
            return CGPoint(x: 0, y: y)
        }
        guard let target = align() else { completion?(); return }
        let finish: @MainActor () -> Void = { [weak self] in
            // 视口移动后 TextKit 可能再次修正估算：再对齐一次（无动画、幅度小）
            if let self, let t2 = align(), abs(t2.y - sv.contentView.bounds.minY) > 1 {
                sv.contentView.setBoundsOrigin(t2); sv.reflectScrolledClipView(sv.contentView)
                _ = self
            }
            completion?()
        }
        if animated, abs(target.y - sv.contentView.bounds.minY) < sv.contentView.bounds.height * 3 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                sv.contentView.animator().setBoundsOrigin(target)
            }, completionHandler: {
                sv.reflectScrolledClipView(sv.contentView)
                finish()
            })
        } else {
            sv.contentView.setBoundsOrigin(target)
            sv.reflectScrolledClipView(sv.contentView)
            DispatchQueue.main.async { finish() }
        }
    }

    /// 视口顶部所在的顶级块下标（取样点在留白之下，保证刚滚到的目标块被算作"当前块"）
    public func topVisibleBlockIndex() -> Int? {
        guard let rendered, let tlm = textLayoutManager, let cs = textContentStorage, let sv = enclosingScrollView else { return nil }
        let y = sv.contentView.bounds.minY - textContainerInset.height + Self.scrollTopMargin + 4
        let point = CGPoint(x: 0, y: max(0, y))
        guard let frag = tlm.textLayoutFragment(for: point) else { return nil }
        let offset = cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location)
        return rendered.blockIndex(at: offset)
    }

    /// 视口顶部到指定块顶部的像素偏移（用于重载后恢复位置）
    public func scrollOffset(withinBlock index: Int) -> CGFloat {
        guard let rendered, index < rendered.ranges.count, let tlm = textLayoutManager, let cs = textContentStorage, let sv = enclosingScrollView else { return 0 }
        guard let loc = cs.location(cs.documentRange.location, offsetBy: rendered.ranges[index].location), let frag = tlm.textLayoutFragment(for: loc) else { return 0 }
        return sv.contentView.bounds.minY - (frag.layoutFragmentFrame.minY + textContainerInset.height)
    }

    public func scroll(toBlock index: Int, offset: CGFloat) {
        scroll(toBlock: index)
        guard let sv = enclosingScrollView else { return }
        var o = sv.contentView.bounds.origin
        o.y = max(0, o.y + Self.scrollTopMargin + offset)
        sv.contentView.setBoundsOrigin(o)
        sv.reflectScrolledClipView(sv.contentView)
    }
}
