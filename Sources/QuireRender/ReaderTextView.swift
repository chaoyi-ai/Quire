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

    // MARK: - 布局：内容列居中

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContentInsets()
    }

    private func updateContentInsets() {
        let w = bounds.width
        let maxW = style.maxContentWidth
        var inset = style.horizontalPadding
        if maxW > 0, w - inset * 2 > maxW {
            inset = ((w - maxW) / 2).rounded(.down)
        }
        if textContainerInset.width != inset {
            textContainerInset = CGSize(width: inset, height: style.verticalPadding)
        }
    }

    /// 内容列宽度（pt）
    public var contentWidth: CGFloat { bounds.width - textContainerInset.width * 2 }

    // MARK: - NSTextLayoutManagerDelegate

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let f = BlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
        f.style = style
        return f
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

    /// 扫描附件，异步加载未加载的图片 / 渲染 Mermaid
    public func loadImages() {
        guard let ts = textStorage, ts.length > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let maxW = max(200, contentWidth)
        ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length), options: [.longestEffectiveRangeNotRequired]) { value, range, _ in
            if let m = value as? MermaidAttachment, !m.isRendered, !m.failed {
                renderMermaid(m, at: range, maxWidth: maxW)
                return
            }
            guard let att = value as? ImageAttachment, !att.isLoaded, !att.loadFailed, let src = att.source else { return }
            guard let url = ImageLoader.resolve(src, relativeTo: baseURL) else { att.loadFailed = true; return }
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

    /// 附件内容/尺寸变化后触发该处重排（附件位置可能已变化：按对象重新定位）
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
        ts.beginEditing()
        ts.addAttribute(.attachment, value: att, range: target)
        ts.endEditing()
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

    /// 滚动到某个顶级块顶部
    public func scroll(toBlock index: Int, animated: Bool = false) {
        guard let rendered, index < rendered.ranges.count, let tlm = textLayoutManager, let cs = textContentStorage else { return }
        let r = rendered.ranges[index]
        guard let loc = cs.location(cs.documentRange.location, offsetBy: r.location) else { return }
        tlm.ensureLayout(for: NSTextRange(location: loc))
        guard let frag = tlm.textLayoutFragment(for: loc) else { return }
        var y = frag.layoutFragmentFrame.minY + textContainerInset.height - 8
        y = max(0, y)
        let target = CGPoint(x: 0, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                enclosingScrollView?.contentView.animator().setBoundsOrigin(target)
            }
        } else {
            enclosingScrollView?.contentView.setBoundsOrigin(target)
        }
        enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
    }

    /// 视口顶部所在的顶级块下标
    public func topVisibleBlockIndex() -> Int? {
        guard let rendered, let tlm = textLayoutManager, let cs = textContentStorage, let sv = enclosingScrollView else { return nil }
        let y = sv.contentView.bounds.minY - textContainerInset.height + 4
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
        o.y = max(0, o.y + 8 + offset)
        sv.contentView.setBoundsOrigin(o)
        sv.reflectScrolledClipView(sv.contentView)
    }
}
