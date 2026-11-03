import AppKit
import QuireRender

/// 标签条：工具栏里的一项（工具栏行 = 标签行，在侧栏列右侧；docs/research/window-chrome.md §3）。
///
/// 规则（DESIGN.md §8.1「颜色表示层，状态是同一层上朝墨走的一步」）：
/// - 选中标签 = 一块底板，和同一行里模式分段控件的选中段同高（22 pt）、同圆角、同方向（深色主题变亮、浅色变暗），标题 semibold。
///   整条只有这一块底板。不用正文色：正文色只属于正文——浮在铬上的正文色块在深色主题里读成"洞"（合成一行时的教训，window-chrome.md §3）。
/// - 悬停不加底（加了就成了两块差不多的底板，分不清哪个是当前），只把标题提亮一档、在标题左边出 ×。
/// - 只有一个标签时不画底板，名字像窗口标题一样贴左，+ 紧跟。
/// - 所有颜色从主题背景推出来（`ChromeColors.ink`），不用主题的 muted / border——那两个是按正文底色调的，画在铬上会看不见或反向。
/// 不用系统标签组：系统标签栏是一条改不了颜色、多标签时也藏不掉的系统件，而且它横跨整个窗口（压在侧栏上面）。
@MainActor
final class TabStripView: NSView {
    /// NSToolbar 把它竖直居中在 38 pt 的行里（5–33）；上下各 5 pt 留给标题栏（拖窗口、双击）
    static let height: CGFloat = 28
    /// 多个标签时每个单元的上限（等宽，不随标题变：单击侧栏换掉临时标签时右边的标签和 + 不会跳）
    static let maxTabWidth: CGFloat = 200

    struct Item: Equatable {
        var title: String
        var path: String?
        var ephemeral: Bool
        var selected: Bool
    }
    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true; refreshHover() } } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onPin: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?
    /// 右键：由工作区给菜单（固定 / 关闭 / 关闭其他 / 在 Finder 中显示 / 复制路径）——窗口标题隐藏了，⌘点标题看路径的习惯由这里接住
    var onContextMenu: ((Int) -> NSMenu?)?
    /// 窗口是否在前台（由窗口控制器按自己的窗口和 App 激活状态设——全屏时这个视图所在的可能是单独的工具栏窗口）
    var isActive = true { didSet { if isActive != oldValue { needsDisplay = true } } }
    /// 系统「增强对比度」
    var increaseContrast = false { didSet { if increaseContrast != oldValue { needsDisplay = true } } }

    private enum Pressed: Equatable { case plus, close(Int) }
    private(set) var hoverIndex: Int?
    private var hoverClose = false
    private var hoverPlus = false
    private var pressed: Pressed?
    private var pressedInside = false
    private var draggingIndex: Int?
    /// 刚点完 × / +：连按的下一下落到挪过来的东西上，不算数（否则窗口缩放、邻居被固定或被关）。按时间算：空白处的单击不经过这里，清不掉标记
    private var ignoresRepeatClickUntil: TimeInterval = 0
    private func isRepeatOfOwnClick(_ event: NSEvent) -> Bool { event.clickCount > 1 && event.timestamp < ignoresRepeatClickUntil }
    private var tracking: NSTrackingArea?

    private let plusGap: CGFloat = 4, plusWidth: CGFloat = 28
    private let plateInset: CGFloat = 4, plateHeight: CGFloat = 22, radius: CGFloat = 5
    private let closeSlot: CGFloat = 16
    private let titleFont = NSFont.systemFont(ofSize: 12)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// 这个视图在标题栏里：isOpaque = false 的视图默认算窗口拖动区，按住一动窗口就走，这里收不到 mouseDragged，拖动排序和"按下后拖出去取消"都没了。
    /// 唯一的临时标签要拖窗口：mouseDown 里 performDrag
    override var mouseDownCanMoveWindow: Bool { false }
    /// 空白处就是标题栏：不接事件，单击拖窗口、双击（系统设置里的填充 / 缩放 / 最小化 / 不动）都由系统的标题栏处理。
    /// 唯一的固定标签读作窗口标题，左键同样交给标题栏（× 除外；右键、中键还是它的）
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        // 系统的双击在松开时才判定，会再问一次命中；Ctrl+点击是右键（菜单）
        let click = NSApp.currentEvent.flatMap { [.leftMouseDown, .leftMouseUp].contains($0.type) && !$0.modifierFlags.contains(.control) ? $0 : nil }
        if let click, isRepeatOfOwnClick(click) { return super.hitTest(point) }   // 连按的下一下落到空白处也不能变成标题栏双击（窗口缩放），在 mouseDown 里吃掉
        if let i = index(at: p) {
            let readsAsTitle = click != nil && isLone && !items[i].ephemeral && !(hoverIndex == i && closeRect(i)?.contains(p) == true)
            return readsAsTitle ? nil : super.hitTest(point)
        }
        return plusRect.contains(p) ? super.hitTest(point) : nil
    }

    // MARK: - 几何

    private var isLone: Bool { items.count == 1 }
    /// 标题左右留的边（× 放在标题左边，所以左右都留出一个 × 槽的位置，标题才能居中）
    static func textInset(plateWidth: CGFloat) -> CGFloat { min(22, max(6, (plateWidth - 40) / 2)) }

    private func font(for item: Item, emphasized: Bool) -> NSFont {
        let f = NSFont.systemFont(ofSize: 12, weight: emphasized ? .semibold : .regular)
        return item.ephemeral ? NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) : f
    }
    private var cellWidth: CGFloat {
        if isLone, let item = items.first {
            // 一个标签：贴着名字（左边留 × 的位置，右边一点点），像窗口标题
            let w = (item.title as NSString).size(withAttributes: [.font: font(for: item, emphasized: true)]).width
            return min(Self.maxTabWidth, ceil(w) + 22 + 8 + 2 * plateInset, max(0, bounds.width - plusGap - plusWidth))
        }
        return floor(min(Self.maxTabWidth, max(0, bounds.width - plusGap - plusWidth) / CGFloat(max(1, items.count))))
    }
    /// 命中区（全高，点击 / 拖动排序用）
    private func cellRect(_ i: Int) -> NSRect { NSRect(x: CGFloat(i) * cellWidth, y: 0, width: cellWidth, height: bounds.height) }
    private func plateRect(_ i: Int) -> NSRect {
        let c = cellRect(i)
        return NSRect(x: c.minX + plateInset, y: (bounds.midY - plateHeight / 2).rounded(), width: c.width - 2 * plateInset, height: plateHeight)
    }
    /// 标题实际占的矩形（居中、超长时中间省略）
    private func titleRect(_ i: Int) -> NSRect {
        let item = items[i]
        let p = plateRect(i)
        let emph = item.selected || isLone
        let size = (item.title as NSString).size(withAttributes: [.font: font(for: item, emphasized: emph)])
        let lineH = ceil(size.height)
        if isLone {
            let x = p.minX + 22
            return NSRect(x: x, y: (bounds.midY - lineH / 2).rounded(), width: min(ceil(size.width), max(0, p.maxX - 8 - x)), height: lineH)
        }
        let inset = Self.textInset(plateWidth: p.width)
        let area = p.insetBy(dx: inset, dy: 0)
        let w = min(ceil(size.width), max(0, area.width))
        return NSRect(x: (area.midX - w / 2).rounded(), y: (bounds.midY - lineH / 2).rounded(), width: w, height: lineH)
    }
    /// × 的槽：紧挨标题左边；底板太窄（放不下）时不出 ×（⌘W、中键、右键菜单照样能关）
    private func closeRect(_ i: Int) -> NSRect? {
        let p = plateRect(i)
        guard p.width >= 80 || isLone else { return nil }
        let t = titleRect(i)
        let x = max(p.minX + 3, t.minX - 6 - closeSlot)
        return NSRect(x: x, y: (bounds.midY - closeSlot / 2).rounded(), width: closeSlot, height: closeSlot)
    }
    private var plusRect: NSRect { NSRect(x: CGFloat(items.count) * cellWidth + plusGap, y: 0, width: plusWidth, height: bounds.height) }

    // MARK: - 颜色（ChromeColors 的墨阶；不活跃时变淡，增强对比度时加强）

    private struct Inks {
        let plate, plateStroke, separator, plusHover, pressed, closeHover, closePressed: NSColor
        let primary, hover, secondary, glyph: NSColor
        let strokeWidth: CGFloat
    }
    private func inks() -> Inks {
        let bg = ThemeManager.shared.currentStyle.background
        let dark = ChromeColors.isDark(bg)
        let ic = increaseContrast, on = isActive
        func ink(_ t: CGFloat) -> NSColor { ChromeColors.ink(bg, t) }
        let secondary = ic ? 0.72 : ChromeStep.secondaryText(dark: dark)
        return Inks(
            plate: ink(ChromeStep.selected(dark: dark) * (ic ? 2 : 1)),
            plateStroke: ink(0.30),
            separator: ink(ic ? 0.20 : ChromeStep.separator),
            plusHover: ink(ic ? 0.054 : ChromeStep.hoverFill),
            pressed: ink(ic ? 0.16 : ChromeStep.pressedFill),
            closeHover: ink(ic ? 0.16 : ChromeStep.pressedFill),
            closePressed: ink(ic ? 0.24 : 0.16),
            primary: ink(on ? (ic ? 0.95 : ChromeStep.primaryText) : secondary),
            hover: ink(on ? (ic ? 0.85 : ChromeStep.hoverText) : secondary / 2),
            secondary: ink(on ? secondary : secondary / 2),
            glyph: ink((ic ? 0.70 : ChromeStep.glyph(dark: dark)) * (on ? 1 : 0.5)),
            strokeWidth: ic ? 1 : 0)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let c = inks()
        let mid = bounds.midY
        // 底板：只给多个标签时的选中项
        if !isLone, let s = items.firstIndex(where: \.selected) {
            let path = NSBezierPath(roundedRect: plateRect(s), xRadius: radius, yRadius: radius)
            c.plate.setFill(); path.fill()
            if c.strokeWidth > 0 {
                let inner = NSBezierPath(roundedRect: plateRect(s).insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                inner.lineWidth = c.strokeWidth; c.plateStroke.setStroke(); inner.stroke()
            }
        }
        // 分隔线：两个"安静"的相邻标签之间（选中 / 悬停的两侧不画）
        if !isLone {
            for i in 1..<max(1, items.count) {
                let quiet = { (k: Int) in !self.items[k].selected && self.hoverIndex != k }
                guard quiet(i), quiet(i - 1) else { continue }
                c.separator.setFill(); NSRect(x: floor(cellRect(i).minX), y: (mid - 7).rounded(), width: 1, height: 14).fill()
            }
        }
        for (i, item) in items.enumerated() {
            let emph = item.selected || isLone
            let color = emph ? c.primary : (hoverIndex == i ? c.hover : c.secondary)
            let ps = NSMutableParagraphStyle(); ps.alignment = .center; ps.lineBreakMode = .byTruncatingMiddle
            (item.title as NSString).draw(in: titleRect(i), withAttributes: [.font: font(for: item, emphasized: emph), .foregroundColor: color, .paragraphStyle: ps])
            if hoverIndex == i, let cr = closeRect(i) {
                if pressed == .close(i), pressedInside { c.closePressed.setFill(); NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4).fill() }
                else if hoverClose { c.closeHover.setFill(); NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4).fill() }
                drawSymbol("xmark", pointSize: 9, weight: .semibold, color: color, centre: NSPoint(x: cr.midX, y: cr.midY))
            }
        }
        let pr = plusRect
        let square = NSRect(x: (pr.midX - 11).rounded(), y: (mid - 11).rounded(), width: 22, height: 22)
        if pressed == .plus, pressedInside { c.pressed.setFill(); NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius).fill() }
        else if hoverPlus { c.plusHover.setFill(); NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius).fill() }
        drawSymbol("plus", pointSize: 13, weight: .regular, color: c.glyph, centre: NSPoint(x: pr.midX, y: mid))
    }

    private func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, centre: NSPoint) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let r = NSRect(x: (centre.x - img.size.width / 2).rounded(), y: (centre.y - img.size.height / 2).rounded(), width: img.size.width, height: img.size.height)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: - 鼠标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    private func index(at p: NSPoint) -> Int? { items.indices.first { cellRect($0).contains(p) } }
    private func rect(of pressed: Pressed) -> NSRect? {
        switch pressed {
        case .plus: return plusRect
        case .close(let i): return items.indices.contains(i) ? closeRect(i) : nil
        }
    }
    private func updateHover(at point: NSPoint?) {
        let idx = point.flatMap { index(at: $0) }
        let close = point.flatMap { p in idx.flatMap { closeRect($0) }?.contains(p) } ?? false
        let plus = point.map { plusRect.contains($0) } ?? false
        if idx != hoverIndex || close != hoverClose || plus != hoverPlus { hoverIndex = idx; hoverClose = close; hoverPlus = plus; needsDisplay = true }
        toolTip = idx.map { items[$0].path ?? items[$0].title } ?? (plus ? L("新建标签页") : nil)
    }
    /// 标签在指针底下变了（关掉、拖动排序），或者菜单、按住期间指针走了：这些时候收不到 mouseMoved，按指针现在的位置重算，否则 × 留在原位或已经不存在的下标上
    private func refreshHover() { updateHover(at: window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }) }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { updateHover(at: nil) }
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) { super.didCloseMenu(menu, with: event); refreshHover() }
    override func mouseDown(with event: NSEvent) {
        if isRepeatOfOwnClick(event) { return }
        ignoresRepeatClickUntil = 0
        let p = convert(event.locationInWindow, from: nil)
        if plusRect.contains(p) { pressed = .plus; pressedInside = true; needsDisplay = true; return }
        guard let i = index(at: p) else { return }
        if let cr = closeRect(i), hoverIndex == i, cr.contains(p) { pressed = .close(i); pressedInside = true; needsDisplay = true; return }
        if event.clickCount == 2 { onPin?(i); return }
        if isLone { window?.performDrag(with: event); return }   // 唯一的标签读作窗口标题：按住拖动窗口
        draggingIndex = i
        if !items[i].selected { onSelect?(i) }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let pressed {
            let inside = rect(of: pressed)?.contains(p) ?? false
            if inside != pressedInside { pressedInside = inside; needsDisplay = true }
            return
        }
        guard let from = draggingIndex, items.count > 1 else { return }
        let to = max(0, min(items.count - 1, Int(p.x / max(1, cellWidth))))
        if from != to { onMove?(from, to); draggingIndex = to }
    }
    override func mouseUp(with event: NSEvent) {
        defer { refreshHover() }
        draggingIndex = nil
        guard let was = pressed else { return }
        let fire = pressedInside
        pressed = nil; pressedInside = false; needsDisplay = true
        guard fire else { return }   // 按下后拖出去 = 取消
        ignoresRepeatClickUntil = event.timestamp + NSEvent.doubleClickInterval
        switch was {
        case .plus: onNew?()
        case .close(let i): if items.indices.contains(i) { onClose?(i) }
        }
    }
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
