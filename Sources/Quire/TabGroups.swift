import AppKit
import QuireRender

/// 自己的标签页：一组文档窗口共用同一个框，同一时刻只显示选中的那个，其余 orderOut；标签条是主题铬色画的标题栏附件。
/// 不用系统标签组（macOS 26 的系统标签栏是一条改不了颜色、多标签时也藏不掉的系统件；胶囊样式也和主题格格不入）。
/// 保留的系统行为：⌘⇧] / ⌘⇧[ 切换、每个文档仍是独立 NSDocument / 窗口（关闭询问、脏标记、窗口菜单都照旧）。
/// 不做：把标签拖出去成独立窗口（用「窗口 → 移到新窗口」）、跨组拖动。
@MainActor
final class TabGroups {
    static let shared = TabGroups()
    static let didChange = Notification.Name("com.korako.quire.tabGroupsDidChange")

    final class Group {
        var windows: [NSWindow] = []
        weak var selected: NSWindow?
        var frame: NSRect?
    }
    private(set) var groups: [Group] = []

    func group(of w: NSWindow) -> Group? { groups.first { $0.windows.contains { $0 === w } } }

    /// 把窗口并进 `target` 所在的组（target 为 nil = 自己一组），并选中它
    func add(_ w: NSWindow, joining target: NSWindow?) {
        if let existing = group(of: w) {
            if let target, let tg = group(of: target), tg !== existing { remove(w) } else { select(w); return }
        }
        let g: Group
        if let target, let tg = group(of: target) { g = tg } else { g = Group(); groups.append(g) }
        g.windows.append(w)
        select(w)
    }

    func remove(_ w: NSWindow) {
        guard let g = group(of: w), let i = g.windows.firstIndex(where: { $0 === w }) else { return }
        g.windows.remove(at: i)
        if g.windows.isEmpty { groups.removeAll { $0 === g } }
        else if g.selected === w || g.selected == nil {
            let next = g.windows[min(i, g.windows.count - 1)]
            g.selected = next
            if let f = g.frame { next.setFrame(f, display: false) }
            next.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func select(_ w: NSWindow) {
        guard let g = group(of: w) else { return }
        if let f = g.frame ?? g.selected?.frame, w.frame != f { w.setFrame(f, display: false) }
        g.selected = w
        g.frame = w.frame
        w.makeKeyAndOrderFront(nil)
        for other in g.windows where other !== w && other.isVisible { other.orderOut(nil) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func selectNext(from w: NSWindow, offset: Int) {
        guard let g = group(of: w), g.windows.count > 1, let i = g.windows.firstIndex(where: { $0 === w }) else { return }
        select(g.windows[(i + offset + g.windows.count) % g.windows.count])
    }

    func move(_ w: NSWindow, to index: Int) {
        guard let g = group(of: w), let i = g.windows.firstIndex(where: { $0 === w }), i != index, index >= 0, index < g.windows.count else { return }
        g.windows.remove(at: i); g.windows.insert(w, at: index)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 选中的窗口移了 / 改了大小：整组跟着记
    func frameDidChange(_ w: NSWindow) {
        guard let g = group(of: w), g.selected === w else { return }
        g.frame = w.frame
    }

    /// 「移到新窗口」：从组里拆出来，自己一组，错开一点显示
    func detach(_ w: NSWindow) {
        guard let g = group(of: w), g.windows.count > 1 else { return }
        remove(w)
        let ng = Group(); ng.windows = [w]; ng.selected = w
        groups.append(ng)
        var f = w.frame; f.origin.x += 40; f.origin.y -= 40
        w.setFrame(f, display: false); ng.frame = f
        w.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 「合并所有窗口」：全并进 keep 所在的组
    func mergeAll(into keep: NSWindow) {
        let all = groups.flatMap(\.windows).filter { $0 !== keep }
        for w in all { add(w, joining: keep) }
        select(keep)
    }

    /// 当前可以并入的组：key 窗口所在的组（文档窗口）
    var currentTarget: NSWindow? {
        if let k = NSApp.keyWindow, group(of: k) != nil { return k }
        return groups.first?.selected
    }
}

/// 标签条：标题栏附件（工具栏之下，全宽）。只在组里多于一个窗口时显示
@MainActor
final class TabStripController: NSTitlebarAccessoryViewController {
    static let height: CGFloat = 30
    private let strip = TabStripView()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var titleObservers: [NSKeyValueObservation] = []
    /// 沉浸模式：藏起来
    var suppressed = false { didSet { refresh() } }

    init() {
        super.init(nibName: nil, bundle: nil)
        strip.frame = NSRect(x: 0, y: 0, width: 800, height: Self.height)
        view = strip
        layoutAttribute = .bottom
        fullScreenMinHeight = 0
        isHidden = true
        strip.onSelect = { w in TabGroups.shared.select(w) }
        strip.onClose = { w in w.performClose(nil) }
        strip.onNew = { NSDocumentController.shared.newDocument(nil) }
        strip.onMove = { w, i in TabGroups.shared.move(w, to: i) }
        for name in [TabGroups.didChange, ThemeManager.didChange, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func refresh() {
        guard let window = view.window else { return }
        let g = TabGroups.shared.group(of: window)
        let tabs = g?.windows ?? [window]
        isHidden = tabs.count <= 1 || suppressed
        strip.tabs = tabs
        strip.selected = g?.selected ?? window
        strip.needsDisplay = true
        titleObservers = tabs.map { w in w.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.strip.needsDisplay = true } } }
    }
}

final class TabStripView: NSView {
    var tabs: [NSWindow] = []
    weak var selected: NSWindow?
    var onSelect: ((NSWindow) -> Void)?
    var onClose: ((NSWindow) -> Void)?
    var onNew: (() -> Void)?
    var onMove: ((NSWindow, Int) -> Void)?
    private var hoverIndex: Int?
    private var hoverClose = false
    private var tracking: NSTrackingArea?
    private var dragging: NSWindow?
    private let plusWidth: CGFloat = 34
    private let closeSize: CGFloat = 14
    private let maxTabWidth: CGFloat = 240

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tabWidth: CGFloat { min(maxTabWidth, (bounds.width - plusWidth) / CGFloat(max(1, tabs.count))) }
    private func tabRect(_ i: Int) -> NSRect { NSRect(x: CGFloat(i) * tabWidth, y: 0, width: tabWidth, height: bounds.height) }
    private func closeRect(_ i: Int) -> NSRect { let r = tabRect(i); return NSRect(x: r.minX + 8, y: (r.height - closeSize) / 2, width: closeSize, height: closeSize) }
    private var plusRect: NSRect { NSRect(x: tabWidth * CGFloat(tabs.count), y: 0, width: plusWidth, height: bounds.height) }

    override func draw(_ dirtyRect: NSRect) {
        let style = ThemeManager.shared.currentStyle
        let page = style.background
        let band = ChromeColors.elevated(page)
        band.setFill(); bounds.fill()
        let titleFont = NSFont.systemFont(ofSize: 12)
        for (i, w) in tabs.enumerated() {
            let r = tabRect(i)
            let isSel = w === selected
            if isSel {
                // 选中的标签和正文连成一片；顶边一条 1 pt 主题 accent 线做标记
                page.setFill(); r.fill()
                style.accent.setFill(); NSRect(x: r.minX, y: 0, width: r.width, height: 2).fill()
            } else if hoverIndex == i {
                ChromeColors.elevated(band).setFill(); r.fill()
            }
            if i > 0, !isSel, tabs.indices.contains(i - 1), tabs[i - 1] !== selected {
                style.border.setFill(); NSRect(x: r.minX, y: 8, width: 1, height: r.height - 16).fill()
            }
            let color = isSel ? style.foreground : style.muted
            var title = w.title.isEmpty ? "Untitled" : w.title
            if let doc = w.windowController?.document as? NSDocument, doc.isDocumentEdited { title = "• " + title }
            let attrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: color]
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
                (isSel ? style.foreground : style.muted).setStroke(); x.stroke()
            }
        }
        let pr = plusRect
        let plus = NSBezierPath(); plus.lineWidth = 1.2
        plus.move(to: NSPoint(x: pr.midX - 5, y: pr.midY)); plus.line(to: NSPoint(x: pr.midX + 5, y: pr.midY))
        plus.move(to: NSPoint(x: pr.midX, y: pr.midY - 5)); plus.line(to: NSPoint(x: pr.midX, y: pr.midY + 5))
        style.muted.setStroke(); plus.stroke()
        // 底边：主题 border 线（和侧栏分隔线同一支笔），选中标签处断开
        style.border.setFill()
        let selIdx = tabs.firstIndex { $0 === selected }
        let line = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        if let s = selIdx { let r = tabRect(s); NSRect(x: 0, y: line.minY, width: r.minX, height: 1).fill(); NSRect(x: r.maxX, y: line.minY, width: bounds.width - r.maxX, height: 1).fill() }
        else { line.fill() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    private func index(at p: NSPoint) -> Int? { tabs.indices.first { tabRect($0).contains(p) } }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = index(at: p)
        let close = idx.map { closeRect($0).contains(p) } ?? false
        if idx != hoverIndex || close != hoverClose { hoverIndex = idx; hoverClose = close; needsDisplay = true }
        toolTip = idx.map { tabs[$0].title } ?? (plusRect.contains(p) ? L("新建标签页") : nil)
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; hoverClose = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if plusRect.contains(p) { onNew?(); return }
        guard let i = index(at: p) else { dragging = nil; window?.performDrag(with: event); return }
        if closeRect(i).contains(p) { onClose?(tabs[i]); return }
        dragging = tabs[i]
        if tabs[i] !== selected { onSelect?(tabs[i]) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let target = max(0, min(tabs.count - 1, Int(p.x / max(1, tabWidth))))
        if let cur = tabs.firstIndex(where: { $0 === dragging }), cur != target { onMove?(dragging, target) }
    }
    override func mouseUp(with event: NSEvent) { dragging = nil }
    override func otherMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.buttonNumber == 2, let i = index(at: p) { onClose?(tabs[i]) }
    }
}
