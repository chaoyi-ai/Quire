import AppKit
import QuireCore

/// TextKit 2 布局片段子类：按段落角色绘制装饰（代码块背景、引用竖条、分割线、标题底线）。
/// 每个段落 = 一个片段；代码块靠 U+2028 保持单段落。
public final class BlockLayoutFragment: NSTextLayoutFragment {
    weak var style: RenderStyle?

    private var paragraphAttributes: [NSAttributedString.Key: Any] {
        guard let p = textElement as? NSTextParagraph, p.attributedString.length > 0 else { return [:] }
        return p.attributedString.attributes(at: 0, effectiveRange: nil)
    }

    private var role: BlockRole {
        (paragraphAttributes[QuireAttribute.blockRole] as? Int).flatMap(BlockRole.init(rawValue:)) ?? .body
    }

    /// 装饰可能超出文本行边界（代码块内边距、引用竖条在缩进区），扩大绘制面
    public override var renderingSurfaceBounds: CGRect {
        let r = super.renderingSurfaceBounds
        guard let style else { return r }
        // 片段自身坐标系（原点 = frame.origin）：覆盖整个片段框并外扩内边距，装饰才不会被裁掉
        let pad = style.codeBlockPadding + 2
        let w = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let full = CGRect(x: -pad - layoutFragmentFrame.minX, y: -2, width: w + pad * 2, height: layoutFragmentFrame.height + 4)
        return r.union(full)
    }

    public override func draw(at point: CGPoint, in context: CGContext) {
        guard let style else { super.draw(at: point, in: context); return }
        let attrs = paragraphAttributes
        let role = self.role
        let ps = attrs[.paragraphStyle] as? NSParagraphStyle
        let frame = layoutFragmentFrame
        // point 对应 frame.origin，而 frame.minX 通常等于段落缩进；装饰一律以"内容列左缘"为基准：
        let originX = point.x - frame.minX
        let width = textLayoutManager?.textContainer?.size.width ?? frame.width
        let height = frame.height
        let quoteDepth = attrs[QuireAttribute.quoteDepth] as? Int ?? 0

        context.saveGState()

        // 引用竖条（可与代码块叠加）
        if quoteDepth > 0 {
            let step = style.blockquoteBarWidth + style.baseSize * 0.9
            // 竖条起点：段落 headIndent 减去每层缩进
            let baseX = (ps?.headIndent ?? 0) - CGFloat(quoteDepth) * step
            for d in 0..<quoteDepth {
                let x = originX + baseX + CGFloat(d) * step
                let barRect = CGRect(x: x, y: point.y, width: style.blockquoteBarWidth, height: height - (ps?.paragraphSpacing ?? 0) * (isLastQuoteParagraph ? 0.5 : 0))
                context.setFillColor(style.quoteBorder.cgColor)
                context.fill(barRect)
            }
            if style.quoteBackground.alphaComponent > 0.01 {
                let x = originX + baseX
                let bg = CGRect(x: x, y: point.y, width: width - baseX, height: height - (ps?.paragraphSpacing ?? 0) * (isLastQuoteParagraph ? 0.5 : 0))
                context.setFillColor(style.quoteBackground.cgColor)
                context.fill(bg)
            }
        }

        switch role {
        case .codeBlock, .htmlBlock, .frontMatter:
            let pad = style.codeBlockPadding
            let spacingBefore = ps?.paragraphSpacingBefore ?? pad
            let spacingAfter = ps?.paragraphSpacing ?? pad
            let gutter = role == .codeBlock ? style.codeGutterWidth : 0
            let left = (ps?.headIndent ?? pad) - pad - gutter
            let rect = CGRect(x: originX + left,
                              y: point.y + spacingBefore - pad,
                              width: width - left,
                              height: height - spacingBefore - spacingAfter + pad * 2)
            let path = CGPath(roundedRect: rect, cornerWidth: style.codeBlockRadius, cornerHeight: style.codeBlockRadius, transform: nil)
            context.addPath(path)
            context.setFillColor((role == .frontMatter ? style.codeBackground.withAlphaComponent(0.6) : style.codeBackground).cgColor)
            context.fillPath()
            if style.codeBorder.alphaComponent > 0.01 {
                context.addPath(path); context.setStrokeColor(style.codeBorder.cgColor); context.setLineWidth(1); context.strokePath()
            }
            // 行号（偏好开启时）：每个软换行前的"真行"编号
            if style.codeGutterWidth > 0, role == .codeBlock, let p = textElement as? NSTextParagraph {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let numFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, style.codeSize * 0.85), weight: .regular)
                let attrs: [NSAttributedString.Key: Any] = [.font: numFont, .foregroundColor: style.lineNumber]
                let text = p.attributedString.string as NSString
                var lineNo = 1
                var lastLineStart = -1
                let gutterRight = originX + left + pad + gutter - 8
                for lf in textLineFragments {
                    let r = lf.characterRange
                    // 该行片段起点是否是"真行"开头（前一个字符是 U+2028 或起点）
                    let isLineStart = r.location == 0 || (r.location > 0 && r.location - 1 < text.length && text.character(at: r.location - 1) == 0x2028)
                    if isLineStart, r.location != lastLineStart {
                        let s = NSAttributedString(string: "\(lineNo)", attributes: attrs)
                        let sz = s.size()
                        let y = point.y + lf.typographicBounds.minY + (lf.typographicBounds.height - sz.height) / 2
                        s.draw(at: CGPoint(x: gutterRight - sz.width, y: y))
                        lineNo += 1
                        lastLineStart = r.location
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            // 语言标签（右上角，小字，弱化）
            if let lang = attrs[QuireAttribute.codeLanguage] as? String, role != .frontMatter, role != .htmlBlock, rect.height > 30 {
                let label = NSAttributedString(string: lang, attributes: [.font: NSFont.systemFont(ofSize: max(9, style.codeSize * 0.75)), .foregroundColor: style.muted.withAlphaComponent(0.8)])
                let sz = label.size()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                // 右侧给复制按钮留 26pt
                label.draw(at: CGPoint(x: rect.maxX - sz.width - pad * 0.75 - 26, y: rect.minY + pad * 0.7))
                NSGraphicsContext.restoreGraphicsState()
            }
        case .thematicBreak:
            let y = point.y + height / 2 - (ps?.paragraphSpacing ?? 0) / 2
            let x0 = originX + (ps?.headIndent ?? 0)
            context.setFillColor(style.border.cgColor)
            context.fill(CGRect(x: x0, y: y.rounded() - 0.5, width: width - (ps?.headIndent ?? 0), height: 1))
        case .table:
            // 表格直接绘制在附件位置（附件本身不画图）
            if let p = textElement as? NSTextParagraph {
                var found: (TableAttachment, Int)?
                p.attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: p.attributedString.length), options: []) { v, r, stop in
                    if let t = v as? TableAttachment { found = (t, r.location); stop.pointee = true }
                }
                if let (att, _) = found, let tlm = textLayoutManager, let cs = tlm.textContentManager,
                   let loc = cs.location(rangeInElement.location, offsetBy: found!.1) {
                    let attRect = frameForTextAttachment(at: loc)  // 片段坐标
                    let layout = att.currentLayout ?? att.layout(available: attRect.width)
                    TableRenderer.draw(att, layout: layout, at: CGPoint(x: point.x + attRect.minX, y: point.y + attRect.minY), maxWidth: attRect.width, in: context)
                }
            }
        case .heading:
            if let level = attrs[QuireAttribute.headingLevel] as? Int, level <= 2 {
                let y = point.y + height - (ps?.paragraphSpacing ?? 0) * 0.5
                let x0 = originX + (ps?.headIndent ?? 0)
                context.setFillColor(style.border.cgColor)
                context.fill(CGRect(x: x0, y: y.rounded() - 0.5, width: width - (ps?.headIndent ?? 0), height: 1))
            }
        default:
            break
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }

    /// 是否是引用的最后一段（决定竖条是否延伸到段后间距）：由渲染层在属性里标记，暂按 false（竖条覆盖整个段落含间距，视觉上连续）
    private var isLastQuoteParagraph: Bool { paragraphAttributes[QuireAttribute.quoteLast] as? Bool ?? false }
}

extension QuireAttribute {
    /// 引用块最后一个段落标记（Bool），用于竖条收尾
    public static let quoteLast = NSAttributedString.Key("quire.quoteLast")
}
