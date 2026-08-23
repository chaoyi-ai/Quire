import AppKit
import QuireCore

/// 代码块右上角的"复制"按钮：按视口惰性创建，滚动/重绘后重新定位；池化复用。
@MainActor
final class CodeBlockOverlayController {
    private weak var textView: ReaderTextView?
    private var pool: [CopyButton] = []
    private var pendingUpdate = false

    init(textView: ReaderTextView) { self.textView = textView }

    /// 合并多次调用为一次（draw 会被频繁触发）
    func setNeedsUpdate() {
        guard !pendingUpdate else { return }
        pendingUpdate = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingUpdate = false
            self?.update()
        }
    }

    func update() {
        guard let tv = textView, let tlm = tv.textLayoutManager, let sv = tv.enclosingScrollView else { return }
        let visible = sv.contentView.bounds   // 文本视图坐标（documentView）
        let inset = tv.textContainerInset
        let style = tv.style
        var used = 0
        // 从可见区顶部开始枚举片段
        let topPoint = CGPoint(x: 0, y: max(0, visible.minY - inset.height))
        guard let startFrag = tlm.textLayoutFragment(for: topPoint) else { hideUnused(from: 0); return }
        tlm.enumerateTextLayoutFragments(from: startFrag.rangeInElement.location, options: [.ensuresLayout]) { frag in
            let frame = frag.layoutFragmentFrame
            if frame.minY + inset.height > visible.maxY { return false }
            guard let p = frag.textElement as? NSTextParagraph, p.attributedString.length > 0 else { return true }
            let attrs = p.attributedString.attributes(at: 0, effectiveRange: nil)
            guard let roleRaw = attrs[QuireAttribute.blockRole] as? Int, roleRaw == BlockRole.codeBlock.rawValue else { return true }
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            let pad = style.codeBlockPadding
            let containerW = tlm.textContainer?.size.width ?? frame.width
            let top = frame.minY + (ps?.paragraphSpacingBefore ?? pad) - pad + inset.height
            let right = inset.width + containerW
            let button = self.button(at: used); used += 1
            let size: CGFloat = 22
            button.frame = CGRect(x: right - size - pad * 0.5, y: top + pad * 0.4, width: size, height: size)
            button.code = p.attributedString.string.replacingOccurrences(of: "\u{2028}", with: "\n").trimmingCharacters(in: .newlines)
            button.tint = style.muted
            button.isHidden = false
            if button.superview !== tv { tv.addSubview(button) }
            return true
        }
        hideUnused(from: used)
    }

    private func button(at i: Int) -> CopyButton {
        if i < pool.count { return pool[i] }
        let b = CopyButton()
        pool.append(b)
        return b
    }

    private func hideUnused(from i: Int) {
        for k in i..<pool.count { pool[k].isHidden = true }
    }

    func removeAll() { pool.forEach { $0.removeFromSuperview() }; pool.removeAll() }
}

@MainActor
final class CopyButton: NSButton {
    var code: String = ""
    var tint: NSColor = .secondaryLabelColor { didSet { contentTintColor = tint } }
    private var tracking: NSTrackingArea?
    private var confirmTask: Task<Void, Never>?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        bezelStyle = .inline
        isBordered = false
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: RL("复制代码"))?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        imagePosition = .imageOnly
        toolTip = RL("复制代码")
        alphaValue = 0.55
        target = self
        action = #selector(copyCode)
        setButtonType(.momentaryChange)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { animator().alphaValue = 0.55 }

    @objc private func copyCode() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: RL("已复制"))?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: RL("复制代码"))?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        }
    }
}
