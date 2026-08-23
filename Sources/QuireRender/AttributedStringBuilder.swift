import AppKit
import QuireCore
import CQuireAttr

/// Block / Inline → NSAttributedString。无共享可变状态（缓存有锁），可在后台线程使用。
///
/// 性能原则（实测驱动，见 ADR-11）：
/// 1. **只做顺序 append**，不在已构建范围上回头 addAttribute（O(runs) 字典合并）。
/// 2. 每个 run 的属性字典**预先 uniqued 并缓存**，通过 `QAAppendRun` 走 ObjC 直通，不经 Swift 字典桥接。
public final class AttributedStringBuilder: @unchecked Sendable {
    public let style: RenderStyle
    public let highlighter: SyntaxHighlighter

    /// uniqued 的属性字典（NSAttributeDictionary，按引用复用）
    typealias Attrs = AnyObject

    private var paragraphStyleCache: [String: NSParagraphStyle] = [:]
    private var attrsCache: [RunKey: Attrs] = [:]
    private var checkboxCache: [Bool: NSAttributedString] = [:]
    private var codeAttrCache: [String: [Attrs]] = [:]     // 按 TokenKind.tokenIndex 索引
    private let cacheLock = NSLock()

    public init(style: RenderStyle, highlighter: SyntaxHighlighter = SyntaxHighlighter()) {
        self.style = style
        self.highlighter = highlighter
    }

    // MARK: - 上下文

    struct BlockContext {
        var listDepth = 0
        var quoteDepth = 0
        var indent: CGFloat = 0           // 当前左缩进（列表 + 引用累计）
        var marker: NSAttributedString?   // 列表项首段的标记（• / 1. / 复选框）
        var markerWidth: CGFloat = 0
        var isFirstInItem = false
    }

    /// 段级上下文：一段内所有 run 共享的属性 + 缓存键
    struct ParagraphContext {
        var base: [NSAttributedString.Key: Any]
        var key: String
        var quote: Bool
        var baseFont: NSFont?          // 标题等覆盖字体
        var color: NSColor?            // 覆盖颜色
    }

    struct InlineContext {
        var para: ParagraphContext
        var bold = false, italic = false, strike = false
        var link: String? = nil
        var tooltip: String? = nil
    }

    struct RunKey: Hashable {
        var para: String
        var flags: UInt8      // bold | italic<<1 | strike<<2 | inlineCode<<3 | muted<<4 | link<<5
    }

    // MARK: - 入口

    /// 渲染一个顶级块。返回的字符串以段落分隔符结尾。
    public func build(_ block: Block, index: Int) -> NSAttributedString {
        build(block, index: index).attributed
    }

    /// 同上，并报告该块是否含需要异步加载的附件（图片 / Mermaid），供 loadImages 跳过无关块，
    /// 避免对整份 1 MB 文档做属性枚举（实测 ~100 ms/次）。
    public func build(_ block: Block, index: Int) -> (attributed: NSAttributedString, hasLoadableAttachments: Bool) {
        let out = NSMutableAttributedString()
        appendedLoadableAttachment = false
        out.beginEditing()
        append(block, into: out, ctx: BlockContext())
        out.endEditing()
        return (out, appendedLoadableAttachment)
    }
    private var appendedLoadableAttachment = false

    // MARK: - 块

    func append(_ block: Block, into out: NSMutableAttributedString, ctx: BlockContext) {
        switch block.kind {
        case .heading(let level, let inlines, let id):
            appendHeading(level: level, inlines: inlines, id: id, into: out, ctx: ctx)
        case .paragraph(let inlines):
            appendParagraph(inlines, into: out, ctx: ctx)
        case .codeBlock(let lang, let code):
            appendCode(code, language: lang, role: .codeBlock, into: out, ctx: ctx)
        case .mermaid(let source):
            if MermaidRenderer.isAvailable, !style.options.largeFile { appendMermaid(source, into: out, ctx: ctx) }
            else { appendCode(source, language: "mermaid", role: .codeBlock, into: out, ctx: ctx) }
        case .html(let html):
            appendCode(html, language: "html", role: .htmlBlock, into: out, ctx: ctx)
        case .frontMatter(let yaml):
            appendCode(yaml, language: "yaml", role: .frontMatter, into: out, ctx: ctx)
        case .blockQuote(let blocks):
            var c = ctx
            c.quoteDepth += 1
            c.indent += style.blockquoteBarWidth + style.baseSize * 0.9
            c.marker = nil; c.isFirstInItem = false
            for (i, b) in blocks.enumerated() {
                var cc = c
                if i == 0, ctx.isFirstInItem { cc.marker = ctx.marker; cc.markerWidth = ctx.markerWidth; cc.isFirstInItem = true }
                append(b, into: out, ctx: cc)
            }
        case .list(let ordered, let start, let items):
            appendList(ordered: ordered, start: start, items: items, into: out, ctx: ctx)
        case .thematicBreak:
            appendThematicBreak(into: out, ctx: ctx)
        case .image(let src, let title, let alt):
            appendImageBlock(source: src, title: title, alt: alt, into: out, ctx: ctx)
        case .table(let table):
            appendTablePlaceholder(table, into: out, ctx: ctx)
        case .footnoteDefinition(let label, let blocks):
            appendFootnoteDefinition(label: label, blocks: blocks, into: out, ctx: ctx)
        }
    }

    /// 段级基础属性 + 缓存键
    private func paragraphContext(role: BlockRole, psKey: String, ps: NSParagraphStyle, ctx: BlockContext, extra: [NSAttributedString.Key: Any] = [:], extraKey: String = "") -> ParagraphContext {
        var a: [NSAttributedString.Key: Any] = [.paragraphStyle: ps, QuireAttribute.blockRole: role.rawValue]
        if ctx.quoteDepth > 0 { a[QuireAttribute.quoteDepth] = ctx.quoteDepth }
        for (k, v) in extra { a[k] = v }
        return ParagraphContext(base: a, key: "\(psKey)|\(role.rawValue)|\(ctx.quoteDepth)|\(ctx.listDepth)|\(extraKey)", quote: ctx.quoteDepth > 0, baseFont: nil, color: nil)
    }

    private func appendHeading(level: Int, inlines: [Inline], id: String, into out: NSMutableAttributedString, ctx: BlockContext) {
        let font = style.headingFont(level: level)
        let psKey = "h\(level)-\(ctx.indent)-\(ctx.quoteDepth)"
        let ps = paragraphStyle(key: psKey) { p in
            let lh = (font.pointSize * 1.3).rounded()
            p.minimumLineHeight = lh; p.maximumLineHeight = lh
            p.paragraphSpacingBefore = (style.baseSize * CGFloat(style.theme.typography.headingSpacingBefore) * (level == 1 ? 1.0 : 0.8)).rounded()
            p.paragraphSpacing = (style.baseSize * 0.6).rounded()
            p.headIndent = ctx.indent; p.firstLineHeadIndent = ctx.indent
        }
        var para = paragraphContext(role: .heading, psKey: psKey, ps: ps, ctx: ctx, extra: [QuireAttribute.headingLevel: level], extraKey: "L\(level)")
        para.baseFont = font; para.color = style.heading
        let ic = InlineContext(para: para)
        if let marker = ctx.marker, ctx.isFirstInItem { appendMarker(marker, into: out, para: para); appendRun("\t", into: out, ctx: ic) }
        appendInlines(inlines, into: out, ctx: ic)
        appendRun("\n", into: out, ctx: ic)
        _ = id   // 锚点跳转按 Block.kind 查，不需要写进属性
    }

    private func appendParagraph(_ inlines: [Inline], into out: NSMutableAttributedString, ctx: BlockContext) {
        let (psKey, ps) = bodyParagraphStyle(ctx: ctx)
        let para = paragraphContext(role: ctx.listDepth > 0 ? .listItem : .body, psKey: psKey, ps: ps, ctx: ctx)
        let ic = InlineContext(para: para)
        if let marker = ctx.marker, ctx.isFirstInItem {
            appendMarker(marker, into: out, para: para)
            appendRun("\t", into: out, ctx: ic)
        }
        appendInlines(inlines, into: out, ctx: ic)
        appendRun("\n", into: out, ctx: ic)
    }

    /// 列表标记必须带上所在段落的段落样式（TextKit 取段首字符的样式），否则整段缩进/制表位失效
    private func appendMarker(_ marker: NSAttributedString, into out: NSMutableAttributedString, para: ParagraphContext) {
        let start = out.length
        out.append(marker)
        out.addAttributes(para.base, range: NSRange(location: start, length: marker.length)) // 1–3 个字符，便宜
    }

    private func bodyParagraphStyle(ctx: BlockContext) -> (String, NSParagraphStyle) {
        let hasMarker = ctx.marker != nil && ctx.isFirstInItem
        let key = "p-\(ctx.indent)-\(ctx.quoteDepth)-\(ctx.listDepth)-\(hasMarker ? ctx.markerWidth : 0)"
        let ps = paragraphStyle(key: key) { p in
            p.minimumLineHeight = style.lineHeight; p.maximumLineHeight = style.lineHeight
            p.paragraphSpacing = ctx.listDepth > 0 ? (style.paragraphSpacing * 0.25).rounded() : style.paragraphSpacing
            p.headIndent = ctx.indent
            p.firstLineHeadIndent = hasMarker ? ctx.indent - ctx.markerWidth : ctx.indent
            if hasMarker { p.tabStops = [NSTextTab(textAlignment: .left, location: ctx.indent)]; p.defaultTabInterval = ctx.indent }
        }
        return (key, ps)
    }

    private func appendList(ordered: Bool, start: Int, items: [ListItem], into out: NSMutableAttributedString, ctx: BlockContext) {
        let depth = ctx.listDepth + 1
        let markerWidth = (style.baseSize * 1.75).rounded()
        let indent = ctx.indent + markerWidth
        let markerFont = style.bodyFont
        let bulletChars = ["•", "◦", "▪"]
        let color: NSColor = ctx.quoteDepth > 0 ? style.quoteForeground : style.foreground
        let bullet = NSAttributedString(string: bulletChars[(depth - 1) % bulletChars.count], attributes: [.font: markerFont, .foregroundColor: color])
        for (i, item) in items.enumerated() {
            let marker: NSAttributedString
            if let cb = item.checkbox {
                marker = checkboxAttachment(checked: cb == .checked, font: markerFont)
            } else if ordered {
                marker = NSAttributedString(string: "\(start + i).", attributes: [.font: markerFont, .foregroundColor: color])
            } else {
                marker = bullet
            }
            var c = ctx
            c.listDepth = depth; c.indent = indent; c.marker = marker; c.markerWidth = markerWidth
            let blocks = item.blocks.isEmpty ? [Block(kind: .paragraph([]))] : item.blocks
            for (j, b) in blocks.enumerated() {
                var cc = c
                cc.isFirstInItem = (j == 0)
                if j > 0 { cc.marker = nil }
                append(b, into: out, ctx: cc)
            }
        }
    }

    private func checkboxAttachment(checked: Bool, font: NSFont) -> NSAttributedString {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = checkboxCache[checked] { return c }
        let size = (font.pointSize * 0.95).rounded()
        let accent = style.accent, muted = style.muted, bg = style.background
        // 矢量绘制（PDF / 打印上下文同样正确；不用 destinationIn 合成）
        let img = NSImage(size: CGSize(width: size, height: size), flipped: false) { rect in
            let r = rect.insetBy(dx: 0.75, dy: 0.75)
            let path = NSBezierPath(roundedRect: r, xRadius: size * 0.22, yRadius: size * 0.22)
            if checked {
                accent.setFill(); path.fill()
                let check = NSBezierPath()
                check.lineWidth = max(1.5, size * 0.14)
                check.lineCapStyle = .round; check.lineJoinStyle = .round
                check.move(to: CGPoint(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.50))
                check.line(to: CGPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.31))
                check.line(to: CGPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.68))
                bg.setStroke(); check.stroke()
            } else {
                path.lineWidth = 1.2
                muted.setStroke(); path.stroke()
            }
            return true
        }
        let att = NSTextAttachment()
        att.image = img
        att.bounds = CGRect(x: 0, y: (font.capHeight - size) / 2 + 1, width: size, height: size)
        let s = NSMutableAttributedString(attachment: att)
        s.addAttributes([.font: font], range: NSRange(location: 0, length: s.length))
        checkboxCache[checked] = s
        return s
    }

    /// 代码块每种 token 的 uniqued 属性字典，按 (role, indent, quote, lang) 缓存；下标 = TokenKind.tokenIndex
    private func codeAttributes(role: BlockRole, ps: NSParagraphStyle, language: String?, ctx: BlockContext) -> [Attrs] {
        let key = "\(role.rawValue)-\(ctx.indent)-\(ctx.quoteDepth)-\(language ?? "")"
        cacheLock.lock()
        if let c = codeAttrCache[key] { cacheLock.unlock(); return c }
        cacheLock.unlock()
        var base: [NSAttributedString.Key: Any] = [.paragraphStyle: ps, QuireAttribute.blockRole: role.rawValue, .font: style.codeFont]
        if ctx.quoteDepth > 0 { base[QuireAttribute.quoteDepth] = ctx.quoteDepth }
        if let language { base[QuireAttribute.codeLanguage] = language }
        var table: [Attrs] = []
        table.reserveCapacity(TokenKind.byIndex.count)
        for k in TokenKind.byIndex {
            var a = base
            a[.foregroundColor] = k == .plain ? (role == .frontMatter ? style.muted : style.codeForeground) : style.syntaxColor(k)
            table.append(QAUniqueAttributes(a as NSDictionary) as AnyObject)
        }
        cacheLock.lock(); codeAttrCache[key] = table; cacheLock.unlock()
        return table
    }

    private func appendCode(_ code: String, language: String?, role: BlockRole, into out: NSMutableAttributedString, ctx: BlockContext) {
        let pad = style.codeBlockPadding
        let ps = paragraphStyle(key: "code-\(ctx.indent)-\(ctx.quoteDepth)") { p in
            let lh = (style.codeSize * 1.5).rounded()
            p.minimumLineHeight = lh; p.maximumLineHeight = lh
            p.paragraphSpacingBefore = pad
            p.paragraphSpacing = pad + style.paragraphSpacing
            p.headIndent = ctx.indent + pad + style.codeGutterWidth; p.firstLineHeadIndent = ctx.indent + pad + style.codeGutterWidth
            p.tailIndent = -pad
            p.lineBreakMode = .byCharWrapping
            p.tabStops = []; p.defaultTabInterval = style.codeFont.pointSize * 0.6 * 4
        }
        if let marker = ctx.marker, ctx.isFirstInItem {
            let (psKey, bps) = bodyParagraphStyle(ctx: ctx)
            let mpara = paragraphContext(role: .listItem, psKey: psKey, ps: bps, ctx: ctx)
            appendMarker(marker, into: out, para: mpara)
            appendRun("\n", into: out, ctx: InlineContext(para: mpara))
        }
        let attrs = codeAttributes(role: role, ps: ps, language: language, ctx: ctx)
        let plain = attrs[0]
        let start = out.length
        // 原生 NSString（UTF-16 存储）：后续按 UTF-16 范围操作是 O(1)，避免 Swift String 的索引换算
        let ns = NSMutableString(string: code.isEmpty ? " " : code)
        ns.replaceOccurrences(of: "\n", with: String(codeLineSeparator), options: [], range: NSRange(location: 0, length: ns.length))
        let n = ns.length
        QAAppendRun(out, ns, plain)

        var tokens: [Token] = []
        if !style.options.largeFile, let language, highlighter.supports(language) {
            tokens = highlighter.highlight(code, language: language) // \n → U+2028 同为 1 单元，偏移一致
        }
        if !tokens.isEmpty {
            // token → 每 UTF-16 单元的 kind（后写覆盖先写：字符串里的转义序列胜出）
            var kinds = [UInt8](repeating: 0, count: n)
            for t in tokens where t.kind != .plain {
                let lo = max(0, t.range.lowerBound), hi = min(n, t.range.upperBound)
                if lo < hi { let k = UInt8(t.kind.tokenIndex); for i in lo..<hi { kinds[i] = k } }
            }
            // 从左到右只覆盖非 plain 的 run：每次 setAttributes 都在 run 表尾部附近分裂，近似 O(1)
            var runStart = 0
            var i = 1
            while i <= n {
                if i == n || kinds[i] != kinds[runStart] {
                    let k = kinds[runStart]
                    if k != 0 { QASetRunAttributes(out, attrs[Int(k)], UInt(start + runStart), UInt(i - runStart)) }
                    runStart = i
                }
                i += 1
            }
        }
        QAAppendRun(out, "\n" as NSString, plain)
    }

    private func appendThematicBreak(into out: NSMutableAttributedString, ctx: BlockContext) {
        let psKey = "hr-\(ctx.indent)"
        let ps = paragraphStyle(key: psKey) { p in
            let h = (style.paragraphSpacing * 2).rounded()
            p.minimumLineHeight = h; p.maximumLineHeight = h
            p.paragraphSpacing = style.paragraphSpacing * 0.5
            p.headIndent = ctx.indent; p.firstLineHeadIndent = ctx.indent
        }
        var para = paragraphContext(role: .thematicBreak, psKey: psKey, ps: ps, ctx: ctx)
        para.color = .clear
        appendRun("\u{00A0}\n", into: out, ctx: InlineContext(para: para))
    }

    private func appendImageBlock(source: String?, title: String?, alt: String, into out: NSMutableAttributedString, ctx: BlockContext) {
        let psKey = "img-\(ctx.indent)-\(title == nil)"
        let ps = paragraphStyle(key: psKey) { p in
            p.alignment = .center
            p.paragraphSpacing = title == nil ? style.paragraphSpacing : 4
            p.paragraphSpacingBefore = 4
            p.headIndent = ctx.indent; p.firstLineHeadIndent = ctx.indent
        }
        let para = paragraphContext(role: .image, psKey: psKey, ps: ps, ctx: ctx)
        let ic = InlineContext(para: para)
        appendImageAttachment(source: source, alt: alt, inline: false, into: out, ctx: ic)
        appendRun("\n", into: out, ctx: ic)
        if let title, !title.isEmpty {
            let cKey = "imgcap-\(ctx.indent)"
            let cps = paragraphStyle(key: cKey) { p in
                p.alignment = .center
                p.paragraphSpacing = style.paragraphSpacing
                p.headIndent = ctx.indent; p.firstLineHeadIndent = ctx.indent
            }
            var cpara = paragraphContext(role: .image, psKey: cKey, ps: cps, ctx: ctx)
            cpara.baseFont = NSFont(descriptor: style.bodyFont.fontDescriptor, size: (style.baseSize * 0.85).rounded()) ?? style.bodyFont
            cpara.color = style.muted
            appendRun(title + "\n", into: out, ctx: InlineContext(para: cpara))
        }
    }

    /// 脚注定义：像有序列表项一样带 "n." 标记与悬挂缩进，小号弱化，段首带锚点属性
    private func appendFootnoteDefinition(label: String, blocks: [Block], into out: NSMutableAttributedString, ctx: BlockContext) {
        let markerWidth = (style.baseSize * 1.75).rounded()
        let capFont = NSFont(descriptor: style.bodyFont.fontDescriptor, size: (style.baseSize * 0.85).rounded()) ?? style.bodyFont
        let marker = NSAttributedString(string: "\(label).", attributes: [.font: capFont, .foregroundColor: style.accent])
        var c = ctx
        c.listDepth = ctx.listDepth + 1
        c.indent = ctx.indent + markerWidth
        c.marker = marker; c.markerWidth = markerWidth
        let start = out.length
        let items = blocks.isEmpty ? [Block(kind: .paragraph([]))] : blocks
        for (j, b) in items.enumerated() {
            var cc = c
            cc.isFirstInItem = (j == 0)
            if j > 0 { cc.marker = nil }
            append(b, into: out, ctx: cc)
        }
        let range = NSRange(location: start, length: out.length - start)
        // 弱化 + 小号（一处 enumerate，脚注很短）
        out.enumerateAttribute(.font, in: range) { v, r, _ in
            if let f = v as? NSFont, f.pointSize >= style.baseSize - 0.5 {
                out.addAttribute(.font, value: NSFont(descriptor: f.fontDescriptor, size: (f.pointSize * 0.85).rounded()) ?? f, range: r)
            }
        }
    }

    /// Mermaid：占位附件（缓存命中则直接带图），实际渲染由 ReaderTextView 触发 MermaidRenderer
    private func appendMermaid(_ source: String, into out: NSMutableAttributedString, ctx: BlockContext) {
        let psKey = "mermaid-\(ctx.indent)"
        let ps = paragraphStyle(key: psKey) { p in
            p.alignment = .center
            p.paragraphSpacing = style.paragraphSpacing
            p.paragraphSpacingBefore = 4
            p.headIndent = ctx.indent; p.firstLineHeadIndent = ctx.indent
        }
        let para = paragraphContext(role: .mermaid, psKey: psKey, ps: ps, ctx: ctx)
        let att = MermaidAttachment(source: source, mermaidTheme: style.theme.mermaid.theme)
        appendedLoadableAttachment = true
        let key = MermaidCache.key(source: source, theme: style.theme.mermaid.theme + "|" + style.theme.colors.background.hexString)
        if let cached = MermaidCache.shared.image(forKey: key) {
            att.image = cached
            att.isRendered = true
            let maxW = max(200, style.maxContentWidth > 0 ? style.maxContentWidth : 760) - ctx.indent
            var size = cached.size
            if size.width > maxW { size.height *= maxW / size.width; size.width = maxW }
            att.bounds = CGRect(x: 0, y: 0, width: size.width.rounded(), height: size.height.rounded())
        } else {
            att.bounds = CGRect(x: 0, y: 0, width: 240, height: style.baseSize * 4)
            att.image = ImageAttachment.placeholder(size: att.bounds.size, alt: "Mermaid…", style: style)
            att.image?.accessibilityDescription = RL("Mermaid 图") + "\n" + source
        }
        var a = para.base
        a[.font] = style.bodyFont
        a[.attachment] = att
        out.append(NSAttributedString(string: "\u{FFFC}", attributes: a))
        appendRun("\n", into: out, ctx: InlineContext(para: para))
    }

    /// 图片附件：占位尺寸，实际图片由 ImageLoader 异步填充
    private func appendImageAttachment(source: String?, alt: String, inline: Bool, into out: NSMutableAttributedString, ctx: InlineContext) {
        let att = ImageAttachment()
        appendedLoadableAttachment = true
        att.source = source
        att.altText = alt
        att.isInline = inline
        let h: CGFloat = inline ? style.baseSize * 1.2 : style.baseSize * 4
        att.bounds = CGRect(x: 0, y: inline ? -style.baseSize * 0.2 : 0, width: inline ? h : min(style.maxContentWidth * 0.6, 240), height: h)
        att.image = ImageAttachment.placeholder(size: att.bounds.size, alt: alt, style: style)
        att.image?.accessibilityDescription = alt.isEmpty ? RL("图片") : alt
        var a = ctx.para.base
        a[.font] = font(for: ctx)
        a[.attachment] = att
        out.append(NSAttributedString(string: "\u{FFFC}", attributes: a))
    }

    /// 表格：单元格属性字符串在这里（后台）生成，视图由 TableAttachmentViewProvider 按宽度排版
    private func appendTablePlaceholder(_ table: TableModel, into out: NSMutableAttributedString, ctx: BlockContext) {
        let cellPara = ParagraphContext(base: [:], key: "tblcell", quote: false, baseFont: nil, color: nil)
        func cell(_ inlines: [Inline], bold: Bool) -> NSAttributedString {
            let m = NSMutableAttributedString()
            var ic = InlineContext(para: cellPara); ic.bold = bold
            appendInlines(inlines, into: m, ctx: ic)
            if m.length == 0 { appendRun(" ", into: m, ctx: ic) }
            return m
        }
        let header = table.header.map { cell($0, bold: true) }
        let rows = table.rows.map { row in row.map { cell($0, bold: false) } }
        let att = TableAttachment(model: table, header: header, rows: rows, style: style)

        let psKey = "tbl-\(ctx.indent)-\(ctx.quoteDepth)"
        let ps = paragraphStyle(key: psKey) { p in
            p.paragraphSpacing = style.paragraphSpacing
            p.paragraphSpacingBefore = 2
            p.headIndent = ctx.indent; p.firstLineHeadIndent = ctx.indent
            p.lineBreakMode = .byClipping
        }
        let para = paragraphContext(role: .table, psKey: psKey, ps: ps, ctx: ctx)
        var a = para.base
        a[.attachment] = att
        a[.font] = style.bodyFont
        out.append(NSAttributedString(string: "\u{FFFC}", attributes: a))
        appendRun("\n", into: out, ctx: InlineContext(para: para))
    }

    // MARK: - 行内

    func appendInlines(_ inlines: [Inline], into out: NSMutableAttributedString, ctx: InlineContext) {
        for i in inlines { appendInline(i, into: out, ctx: ctx) }
    }

    private func font(for ctx: InlineContext) -> NSFont {
        if let base = ctx.para.baseFont {
            var f = base
            if ctx.bold { f = RenderStyle.variant(f, traits: .boldFontMask) }
            if ctx.italic { f = RenderStyle.variant(f, traits: .italicFontMask) }
            return f
        }
        switch (ctx.bold, ctx.italic) {
        case (true, true): return style.bodyBoldItalic
        case (true, false): return style.bodyBold
        case (false, true): return style.bodyItalic
        default: return style.bodyFont
        }
    }

    /// 取（或建）当前上下文的 uniqued 属性字典
    private func runAttributes(_ ctx: InlineContext, inlineCode: Bool = false, muted: Bool = false, codePad: Bool = false) -> Attrs {
        var flags: UInt8 = 0
        if ctx.bold { flags |= 1 }; if ctx.italic { flags |= 2 }; if ctx.strike { flags |= 4 }
        if inlineCode { flags |= 8 }; if muted { flags |= 16 }; if ctx.link != nil { flags |= 32 }; if codePad { flags |= 64 }
        let key = RunKey(para: ctx.para.key + (ctx.para.baseFont.map { "|\($0.fontName)\($0.pointSize)" } ?? "") + (ctx.para.color.map { "|\($0.description)" } ?? ""), flags: flags)
        cacheLock.lock()
        if let a = attrsCache[key] { cacheLock.unlock(); return a }
        cacheLock.unlock()

        var a = ctx.para.base
        let color: NSColor = ctx.link != nil ? style.accent : (ctx.para.color ?? (ctx.para.quote ? style.quoteForeground : style.foreground))
        if inlineCode {
            let base = ctx.para.baseFont.map { NSFont(descriptor: style.inlineCodeFont.fontDescriptor, size: ($0.pointSize * CGFloat(style.theme.typography.codeSize)).rounded()) ?? style.inlineCodeFont } ?? style.inlineCodeFont
            a[.font] = ctx.bold ? RenderStyle.variant(base, traits: .boldFontMask) : base
            a[QuireAttribute.inlineCode] = true
            a[.foregroundColor] = ctx.link != nil ? style.accent : style.inlineCodeForeground
        } else if muted {
            a[.font] = style.inlineCodeFont
            a[.foregroundColor] = style.muted
        } else if codePad {
            // 行内代码框两侧的留白：正文字体的窄空格（不能放在代码字体 run 里，CJK 回退字体会把它撑宽）
            a[.font] = style.bodyFont
            a[.foregroundColor] = color
            a[QuireAttribute.inlineCode] = true
        } else {
            a[.font] = font(for: ctx)
            a[.foregroundColor] = color
        }
        if ctx.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; a[.strikethroughColor] = a[.foregroundColor] }
        if ctx.link != nil {
            a[.cursor] = NSCursor.pointingHand
            if style.options.linkUnderline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        }
        let u = QAUniqueAttributes(a as NSDictionary) as AnyObject
        cacheLock.lock(); attrsCache[key] = u; cacheLock.unlock()
        return u
    }

    /// 追加一个文本 run（链接 / tooltip 作为 extra 属性叠加，不进缓存）
    private func appendRun(_ s: String, into out: NSMutableAttributedString, ctx: InlineContext, inlineCode: Bool = false, muted: Bool = false, codePad: Bool = false) {
        let attrs = runAttributes(ctx, inlineCode: inlineCode, muted: muted, codePad: codePad)
        if let link = ctx.link {
            let value: Any = URL(string: link) ?? link
            let start = out.length
            QAAppendRunWithExtra(out, s as NSString, attrs, .link, value)
            if let tip = ctx.tooltip { out.addAttribute(.toolTip, value: tip, range: NSRange(location: start, length: out.length - start)) }
        } else {
            QAAppendRun(out, s as NSString, attrs)
        }
    }

    private func appendInline(_ inline: Inline, into out: NSMutableAttributedString, ctx: InlineContext) {
        switch inline {
        case .text(let s):
            appendRun(s, into: out, ctx: ctx)
        case .softBreak:
            appendRun(" ", into: out, ctx: ctx)
        case .lineBreak:
            appendRun("\u{2028}", into: out, ctx: ctx)
        case .emphasis(let c):
            var x = ctx; x.italic = true; appendInlines(c, into: out, ctx: x)
        case .strong(let c):
            var x = ctx; x.bold = true; appendInlines(c, into: out, ctx: x)
        case .strikethrough(let c):
            var x = ctx; x.strike = true; appendInlines(c, into: out, ctx: x)
        case .code(let s):
            // 两侧留白用正文字体的窄空格（独立 run，同样带 inlineCode 标记，一起纳入背景框）
            appendRun("\u{2009}\u{2009}\u{2009}", into: out, ctx: ctx, codePad: true)
            appendRun(s, into: out, ctx: ctx, inlineCode: true)
            appendRun("\u{2009}\u{2009}\u{2009}", into: out, ctx: ctx, codePad: true)
        case .link(let dest, let title, let children):
            var x = ctx; x.link = dest ?? ""
            if let title, !title.isEmpty { x.tooltip = title }
            appendInlines(children, into: out, ctx: x)
        case .image(let src, _, let alt):
            appendImageAttachment(source: src, alt: alt, inline: true, into: out, ctx: ctx)
        case .html(let raw):
            // 行内 HTML：常见 <br> 换行，其他原样弱化显示
            if raw.lowercased().hasPrefix("<br") { appendRun("\u{2028}", into: out, ctx: ctx) }
            else { appendRun(raw, into: out, ctx: ctx, muted: true) }
        case .footnoteReference(let label):
            // 用 baselineOffset + 小字号，而不是 legacy 的 .superscript（后者会干扰同一行的删除线绘制）
            var a = ctx.para.base
            let f = font(for: ctx)
            a[.font] = NSFont(descriptor: f.fontDescriptor, size: (f.pointSize * 0.7).rounded()) ?? f
            a[.baselineOffset] = (f.pointSize * 0.35).rounded()
            a[.foregroundColor] = style.accent
            a[.link] = URL(string: "#fn-\(label)") ?? "#fn-\(label)"
            out.append(NSAttributedString(string: label, attributes: a))
        }
    }

    // MARK: - 段落样式缓存

    func paragraphStyle(key: String, _ configure: (NSMutableParagraphStyle) -> Void) -> NSParagraphStyle {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let p = paragraphStyleCache[key] { return p }
        let p = NSMutableParagraphStyle()
        p.lineBreakStrategy = []
        configure(p)
        let frozen = p.copy() as! NSParagraphStyle
        paragraphStyleCache[key] = frozen
        return frozen
    }
}

extension TokenKind {
    /// 稳定的小整数索引（用于每字符 kind 数组）；0 = plain
    static let byIndex: [TokenKind] = [.plain] + TokenKind.allCases.filter { $0 != .plain }
    private static let indexOf: [TokenKind: Int] = Dictionary(uniqueKeysWithValues: byIndex.enumerated().map { ($1, $0) })
    var tokenIndex: Int { TokenKind.indexOf[self] ?? 0 }
}
