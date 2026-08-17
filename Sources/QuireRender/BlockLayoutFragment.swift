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
        let full = CGRect(x: -pad, y: -2, width: layoutFragmentFrame.width + pad * 2, height: layoutFragmentFrame.height + 4)
        return r.union(full)
    }

    public override func draw(at point: CGPoint, in context: CGContext) {
        guard let style else { super.draw(at: point, in: context); return }
        let attrs = paragraphAttributes
        let role = self.role
        let ps = attrs[.paragraphStyle] as? NSParagraphStyle
        let frame = layoutFragmentFrame
        // 片段坐标：以 point 为原点（对应 frame.origin）
        let width = frame.width
        let height = frame.height
        let quoteDepth = attrs[QuireAttribute.quoteDepth] as? Int ?? 0

        context.saveGState()

        // 引用竖条（可与代码块叠加）
        if quoteDepth > 0 {
            let step = style.blockquoteBarWidth + style.baseSize * 0.9
            // 竖条起点：段落 headIndent 减去每层缩进
            let baseX = (ps?.headIndent ?? 0) - CGFloat(quoteDepth) * step
            for d in 0..<quoteDepth {
                let x = point.x + baseX + CGFloat(d) * step
                let barRect = CGRect(x: x, y: point.y, width: style.blockquoteBarWidth, height: height - (ps?.paragraphSpacing ?? 0) * (isLastQuoteParagraph ? 0.5 : 0))
                context.setFillColor(style.quoteBorder.cgColor)
                context.fill(barRect)
            }
            if style.quoteBackground.alphaComponent > 0.01 {
                let x = point.x + baseX
                let bg = CGRect(x: x, y: point.y, width: width - baseX, height: height - (ps?.paragraphSpacing ?? 0) * (isLastQuoteParagraph ? 0.5 : 0))
                context.setFillColor(style.quoteBackground.cgColor)
                context.fill(bg)
            }
        }

        switch role {
        case .codeBlock, .mermaid, .htmlBlock, .frontMatter:
            let pad = style.codeBlockPadding
            let spacingBefore = ps?.paragraphSpacingBefore ?? pad
            let spacingAfter = ps?.paragraphSpacing ?? pad
            let left = (ps?.headIndent ?? pad) - pad
            let rect = CGRect(x: point.x + left,
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
            // 语言标签（右上角，小字，弱化）
            if let lang = attrs[QuireAttribute.codeLanguage] as? String, role != .frontMatter, role != .htmlBlock, rect.height > 30 {
                let label = NSAttributedString(string: lang, attributes: [.font: NSFont.systemFont(ofSize: max(9, style.codeSize * 0.75)), .foregroundColor: style.muted.withAlphaComponent(0.8)])
                let sz = label.size()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                label.draw(at: CGPoint(x: rect.maxX - sz.width - pad * 0.75, y: rect.minY + pad * 0.5))
                NSGraphicsContext.restoreGraphicsState()
            }
        case .thematicBreak:
            let y = point.y + height / 2 - (ps?.paragraphSpacing ?? 0) / 2
            let x0 = point.x + (ps?.headIndent ?? 0)
            context.setFillColor(style.border.cgColor)
            context.fill(CGRect(x: x0, y: y.rounded() - 0.5, width: width - (ps?.headIndent ?? 0), height: 1))
        case .heading:
            if let level = attrs[QuireAttribute.headingLevel] as? Int, level <= 2 {
                let y = point.y + height - (ps?.paragraphSpacing ?? 0) + style.baseSize * 0.2
                let x0 = point.x + (ps?.headIndent ?? 0)
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
