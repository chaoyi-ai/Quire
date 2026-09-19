import AppKit
import QuireRender

/// 标签条（正文列顶部，侧栏右侧；docs/research/window-chrome.md §3 规则 2）。自己画：铬色底、选中标签 = 正文色 + 2 pt accent 顶线、
/// 临时标签斜体、悬停出 ×、`+` 新建、拖动排序、中键关闭、双击固定临时标签。
/// 不用系统标签组：系统标签栏是一条改不了颜色、多标签时也藏不掉的系统件，而且它横跨整个窗口（压在侧栏上面）。
@MainActor
final class TabStripView: NSView {
    static let height: CGFloat = 30

    struct Item: Equatable {
        var title: String
        var path: String?
        var edited: Bool
        var ephemeral: Bool
        var selected: Bool
    }
    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true } } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onPin: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?
    /// 右键：由工作区给菜单（固定 / 关闭 / 关闭其他 / 在 Finder 中显示 / 复制路径）——窗口标题隐藏了，⌘点标题看路径的习惯由这里接住
    var onContextMenu: ((Int) -> NSMenu?)?

    private var hoverIndex: Int?
    private var hoverClose = false
    private var tracking: NSTrackingArea?
    private var draggingIndex: Int?
    private let plusWidth: CGFloat = 34
    private let closeSize: CGFloat = 14
    private let maxTabWidth: CGFloat = 240

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tabWidth: CGFloat { min(maxTabWidth, (bounds.width - plusWidth) / CGFloat(max(1, items.count))) }
    private func tabRect(_ i: Int) -> NSRect { NSRect(x: CGFloat(i) * tabWidth, y: 0, width: tabWidth, height: bounds.height) }
    private func closeRect(_ i: Int) -> NSRect { let r = tabRect(i); return NSRect(x: r.minX + 8, y: (r.height - closeSize) / 2, width: closeSize, height: closeSize) }
    private var plusRect: NSRect { NSRect(x: tabWidth * CGFloat(items.count), y: 0, width: plusWidth, height: bounds.height) }

    override func draw(_ dirtyRect: NSRect) {
        let style = ThemeManager.shared.currentStyle
        let page = style.background
        let band = ChromeColors.elevated(page)
        band.setFill(); bounds.fill()
        let font = NSFont.systemFont(ofSize: 12)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for (i, item) in items.enumerated() {
            let r = tabRect(i)
            if item.selected {
                // 选中的标签和正文连成一片；顶边一条 2 pt 主题 accent 线做标记
                page.setFill(); r.fill()
                style.accent.setFill(); NSRect(x: r.minX, y: 0, width: r.width, height: 2).fill()
            } else if hoverIndex == i {
                ChromeColors.elevated(band).setFill(); r.fill()
            }
            if i > 0, !item.selected, !items[i - 1].selected {
                style.border.setFill(); NSRect(x: r.minX, y: 8, width: 1, height: r.height - 16).fill()
            }
            let color = item.selected ? style.foreground : style.muted
            let title = (item.edited ? "• " : "") + item.title
            let attrs: [NSAttributedString.Key: Any] = [.font: item.ephemeral ? italic : font, .foregroundColor: color]
            let size = (title as NSString).size(withAttributes: attrs)
            let pad = closeSize + 12
            let textW = min(size.width, max(0, r.width - 2 * pad))
            let tr = NSRect(x: r.midX - textW / 2, y: (r.height - size.height) / 2, width: textW, height: size.height)
            let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingMiddle
            (title as NSString).draw(in: tr, withAttributes: attrs.merging([.paragraphStyle: ps]) { $1 })
            if hoverIndex == i {
                let cr = closeRect(i)
                if hoverClose { style.border.setFill(); NSBezierPath(ovalIn: cr).fill() }
                let x = NSBezierPath(); x.lineWidth = 1.2
                let inset: CGFloat = 4
                x.move(to: NSPoint(x: cr.minX + inset, y: cr.minY + inset)); x.line(to: NSPoint(x: cr.maxX - inset, y: cr.maxY - inset))
                x.move(to: NSPoint(x: cr.maxX - inset, y: cr.minY + inset)); x.line(to: NSPoint(x: cr.minX + inset, y: cr.maxY - inset))
                (item.selected ? style.foreground : style.muted).setStroke(); x.stroke()
            }
        }
        let pr = plusRect
        let plus = NSBezierPath(); plus.lineWidth = 1.2
        plus.move(to: NSPoint(x: pr.midX - 5, y: pr.midY)); plus.line(to: NSPoint(x: pr.midX + 5, y: pr.midY))
        plus.move(to: NSPoint(x: pr.midX, y: pr.midY - 5)); plus.line(to: NSPoint(x: pr.midX, y: pr.midY + 5))
        style.muted.setStroke(); plus.stroke()
        // 底边：主题 border 线（和侧栏分隔线同一支笔），选中标签处断开
        style.border.setFill()
        let line = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        if let s = items.firstIndex(where: \.selected) {
            let r = tabRect(s)
            NSRect(x: 0, y: line.minY, width: r.minX, height: 1).fill()
            NSRect(x: r.maxX, y: line.minY, width: bounds.width - r.maxX, height: 1).fill()
        } else { line.fill() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    private func index(at p: NSPoint) -> Int? { items.indices.first { tabRect($0).contains(p) } }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = index(at: p)
        let close = idx.map { closeRect($0).contains(p) } ?? false
        if idx != hoverIndex || close != hoverClose { hoverIndex = idx; hoverClose = close; needsDisplay = true }
        toolTip = idx.map { items[$0].path ?? items[$0].title } ?? (plusRect.contains(p) ? L("新建标签页") : nil)
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; hoverClose = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if plusRect.contains(p) { onNew?(); return }
        guard let i = index(at: p) else { draggingIndex = nil; window?.performDrag(with: event); return }
        if closeRect(i).contains(p) { onClose?(i); return }
        if event.clickCount == 2 { onPin?(i); return }
        draggingIndex = i
        if !items[i].selected { onSelect?(i) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let from = draggingIndex else { return }
        let p = convert(event.locationInWindow, from: nil)
        let to = max(0, min(items.count - 1, Int(p.x / max(1, tabWidth))))
        if from != to { onMove?(from, to); draggingIndex = to }
    }
    override func mouseUp(with event: NSEvent) { draggingIndex = nil }
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else { return nil }
        return onContextMenu?(i)
    }
    override func otherMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.buttonNumber == 2, let i = index(at: p) { onClose?(i) }
    }
}

/// 正文列：标签条在顶、正文分栏在下（侧栏不参与，所以标签条永远不会盖到侧栏）
@MainActor
final class ContentColumnView: NSView {
    let strip = TabStripView()
    let split: NSSplitView
    /// 沉浸模式：藏标签条
    var stripHidden = false { didSet { if stripHidden != oldValue { needsLayout = true } } }

    init(split: NSSplitView) {
        self.split = split
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        addSubview(split)
        addSubview(strip)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = stripHidden ? 0 : TabStripView.height
        strip.isHidden = stripHidden
        strip.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        split.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - h)
    }
    override func resize(withOldSuperviewSize oldSize: NSSize) { super.resize(withOldSuperviewSize: oldSize); needsLayout = true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
}
