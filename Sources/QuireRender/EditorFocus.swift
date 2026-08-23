import AppKit
import NaturalLanguage

/// 专注模式（iA Writer 式）：句子 / 段落 淡化其余文字；打字机 把光标行锁在视口中线。
public enum EditorFocusMode: Int, CaseIterable, Sendable {
    case off = 0, sentence, paragraph, typewriter
    public var next: EditorFocusMode { EditorFocusMode(rawValue: (rawValue + 1) % EditorFocusMode.allCases.count)! }
}

extension EditorTextView {
    /// 光标所在句子 / 段落的范围（句子用 NLTokenizer 切；CJK 标点也认）
    func focusRange(for mode: EditorFocusMode) -> NSRange? {
        guard let ns = textStorage?.string as NSString?, ns.length > 0 else { return nil }
        let sel = selectedRange()
        let loc = min(sel.location, ns.length)
        var para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        // 段落末尾的换行不算
        if para.length > 0, ns.character(at: para.location + para.length - 1) == 0x0A { para.length -= 1 }
        guard mode == .sentence, para.length > 0 else { return para }
        let text = ns.substring(with: para)
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        let rel = loc - para.location
        var best: NSRange = para
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let nsr = NSRange(r, in: text)
            // 光标在句内，或正好在句尾（刚打完句号）→ 该句
            if rel >= nsr.location && rel <= nsr.location + nsr.length { best = NSRange(location: para.location + nsr.location, length: nsr.length); return false }
            return true
        }
        return best
    }

    /// 淡化焦点范围之外的文字。不用渲染属性——实测 NSTextView 在视口布局时会用自己的临时属性覆盖
    /// `setRenderingAttributes`，且 `removeRenderingAttribute` 对子范围是空操作；也不能在 `draw(_:)` 里画——
    /// TextKit 2 把片段画在子 layer 里，view 自己的绘制在其下面。改为一个置顶的透明子视图盖一层
    /// 半透明背景色（奇偶裁剪掉焦点范围的行段），能精确到句子中段，不改 textStorage，零布局开销。
    func applyFocusDim() {
        let dimming = focusMode == .sentence || focusMode == .paragraph
        let newRange = dimming ? focusRange(for: focusMode) : nil
        guard newRange != lastFocusRange || dimming != focusDimActive else { return }
        lastFocusRange = newRange
        focusDimActive = dimming
        if dimming {
            if dimOverlay == nil {
                let o = FocusDimOverlay(frame: bounds)
                o.autoresizingMask = [.width, .height]
                addSubview(o)
                dimOverlay = o
            }
            dimOverlay?.isHidden = false
            dimOverlay?.needsDisplay = true
        } else {
            dimOverlay?.isHidden = true
        }
    }

    /// 焦点范围在视图坐标里的行段矩形
    func focusSegmentRects() -> [NSRect] {
        guard let r = lastFocusRange, let tlm = textLayoutManager, let cs = textContentStorage,
              let s = cs.location(cs.documentRange.location, offsetBy: r.location),
              let e = cs.location(cs.documentRange.location, offsetBy: r.location + max(r.length, 1)),
              let tr = NSTextRange(location: s, end: e) else { return [] }
        var rects: [NSRect] = []
        let inset = textContainerInset
        tlm.enumerateTextSegments(in: tr, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: inset.width, dy: inset.height).insetBy(dx: -2, dy: 0))
            return true
        }
        return rects
    }

    func drawFocusDim(in dirtyRect: NSRect) {
        guard focusDimActive else { return }
        let path = NSBezierPath(rect: dirtyRect)
        for r in focusSegmentRects() where r.intersects(dirtyRect) { path.appendRect(r) }
        path.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        style.background.withAlphaComponent(0.62).setFill()   // 留 ~40% 的可读度：上下文还能扫到，又分得清焦点
        dirtyRect.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 打字机：让光标所在行居中（只在键盘引起的变化时调用，鼠标点击不强行居中）
    func centerCaretLine() {
        guard let sv = enclosingScrollView, let tlm = textLayoutManager, let cs = textContentStorage else { return }
        let loc = selectedRange().location
        guard let l = cs.location(cs.documentRange.location, offsetBy: loc) else { return }
        var frag: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: l, options: [.ensuresLayout]) { f in frag = f; return false }
        guard let frag else { return }
        var lineMidY = frag.layoutFragmentFrame.midY
        let rel = loc - cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location)
        for line in frag.textLineFragments where rel >= line.characterRange.location && rel <= line.characterRange.location + line.characterRange.length {
            lineMidY = frag.layoutFragmentFrame.minY + line.typographicBounds.midY; break
        }
        let visibleH = sv.contentView.bounds.height - sv.contentInsets.top
        let y = lineMidY + textContainerInset.height - sv.contentInsets.top - visibleH / 2
        let clip = sv.contentView
        let target = clip.constrainBoundsRect(NSRect(x: 0, y: y, width: clip.bounds.width, height: clip.bounds.height)).origin
        if abs(target.y - clip.bounds.minY) > 0.5 {
            clip.setBoundsOrigin(target); sv.reflectScrolledClipView(clip)
        }
    }

    /// 打字机模式需要上下各半屏留白，文首 / 文末的行才能到中线
    func updateTypewriterInset() {
        guard let sv = enclosingScrollView else { return }
        let h = focusMode == .typewriter ? ((sv.contentView.bounds.height - sv.contentInsets.top) / 2).rounded() : 16
        if abs(textContainerInset.height - h) > 0.5 { textContainerInset = CGSize(width: textContainerInset.width, height: h) }
    }
}

/// 专注淡化层：不拦截鼠标，置顶，随文本视图滚动
final class FocusDimOverlay: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.zPosition = 1_000
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        (superview as? EditorTextView)?.drawFocusDim(in: dirtyRect)
    }
}
