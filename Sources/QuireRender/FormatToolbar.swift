import AppKit

/// 选中文字时浮在选区上方的格式工具条（Typora 1.14 / iA 式）：粗 / 斜 / 代码 / 链接 / 删除线 / H1–H3 / 引用 / 列表。
/// 挂在滚动视图上（不随文本滚动而错位：每次选区或滚动变化重新定位）；无选区即隐藏。
@MainActor
final class FormatToolbar: NSView {
    private weak var editor: EditorTextView?
    private var buttons: [NSButton] = []

    init(editor: EditorTextView) {
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.18; layer?.shadowRadius = 6; layer?.shadowOffset = CGSize(width: 0, height: -2)
        applyColors()
        let items: [(String, String, Selector)] = [
            ("bold", RL("粗体"), #selector(EditorTextView.toggleBold(_:))),
            ("italic", RL("斜体"), #selector(EditorTextView.toggleItalic(_:))),
            ("strikethrough", RL("删除线"), #selector(EditorTextView.toggleStrikethrough(_:))),
            ("chevron.left.forwardslash.chevron.right", RL("行内代码"), #selector(EditorTextView.toggleInlineCode(_:))),
            ("link", RL("链接"), #selector(EditorTextView.insertLink(_:))),
            ("1.square", "H1", #selector(EditorTextView.setHeading1(_:))),
            ("2.square", "H2", #selector(EditorTextView.setHeading2(_:))),
            ("3.square", "H3", #selector(EditorTextView.setHeading3(_:))),
            ("text.quote", RL("引用"), #selector(EditorTextView.toggleQuote(_:))),
            ("list.bullet", RL("列表"), #selector(EditorTextView.toggleBulletList(_:))),
        ]
        var x: CGFloat = 4
        for (symbol, tip, sel) in items {
            let b = NSButton(frame: NSRect(x: x, y: 3, width: 24, height: 22))
            b.bezelStyle = .inline; b.isBordered = false
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            b.imagePosition = .imageOnly
            b.contentTintColor = .labelColor
            b.toolTip = tip
            b.target = editor; b.action = sel
            b.setAccessibilityLabel(tip)
            addSubview(b); buttons.append(b)
            x += 26
        }
        frame.size.width = x + 2
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// 颜色按当前外观解析（layer 的 CGColor 不会随深浅色自动变）
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    /// 按当前选区定位：选区首行上方；无选区则隐藏
    func update() {
        guard let editor, let sv = editor.enclosingScrollView, superview != nil else { return }
        let sel = editor.selectedRange()
        guard sel.length > 0, editor.window?.firstResponder === editor else { isHidden = true; return }
        // 选区第一行的矩形（文档坐标）→ 滚动视图坐标
        guard let rect = editor.firstLineRect(for: sel) else { isHidden = true; return }
        let inClip = sv.contentView.convert(rect, from: editor)
        let inScroll = sv.convert(inClip, from: sv.contentView)
        var origin = CGPoint(x: inScroll.midX - frame.width / 2, y: inScroll.minY - frame.height - 6)
        if origin.y < sv.contentInsets.top + 4 { origin.y = inScroll.maxY + 6 }   // 顶部放不下 → 放下面
        origin.x = max(6, min(origin.x, sv.bounds.width - frame.width - 6))
        frame.origin = origin
        isHidden = false
    }
}
