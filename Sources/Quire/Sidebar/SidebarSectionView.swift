import AppKit

/// 侧栏分段：段头（三角 + 标题 + 计数 + 悬停出现的动作按钮）+ 内容。折叠时只剩段头。
/// VS Code 资源管理器那种"上下堆叠、各自可折叠"的骨架用它拼出来。
@MainActor
final class SidebarSectionView: NSView {
    static let headerHeight: CGFloat = 26

    struct Action { let symbol: String; let tooltip: String; let handler: () -> Void }

    let header = NSView()
    let content = NSView()
    private let disclosure = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let actionsStack = NSStackView()
    private var actions: [Action] = []
    private var tracking: NSTrackingArea?

    var title: String { didSet { titleLabel.stringValue = title } }
    var count: String = "" { didSet { countLabel.stringValue = count; countLabel.isHidden = count.isEmpty } }
    /// 折叠状态变化（用户点段头）
    var onToggle: ((Bool) -> Void)?
    private(set) var isCollapsed = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header); addSubview(content)

        disclosure.bezelStyle = .inline
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.imageScaling = .scaleProportionallyDown
        disclosure.contentTintColor = .tertiaryLabelColor
        disclosure.target = self; disclosure.action = #selector(toggle(_:))
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.setAccessibilityLabel(L("折叠 / 展开"))
        updateDisclosureImage()

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.isHidden = true
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        actionsStack.orientation = .horizontal
        actionsStack.spacing = 2
        actionsStack.alphaValue = 0
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(disclosure); header.addSubview(titleLabel); header.addSubview(countLabel); header.addSubview(actionsStack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            disclosure.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            disclosure.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 14), disclosure.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 5),
            countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            actionsStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            actionsStack.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 6),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggle(_:)))
        header.addGestureRecognizer(click)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// 段头右侧的小按钮（悬停显示）
    func setActions(_ actions: [Action]) {
        self.actions = actions
        actionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, a) in actions.enumerated() {
            let b = NSButton()
            b.bezelStyle = .inline
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.tooltip)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = a.tooltip
            b.tag = i
            b.target = self; b.action = #selector(runAction(_:))
            b.setAccessibilityLabel(a.tooltip)
            b.widthAnchor.constraint(equalToConstant: 20).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            actionsStack.addArrangedSubview(b)
        }
    }

    /// 放内容视图（填满 content）
    func setContentView(_ v: NSView) {
        content.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: content.topAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    func setCollapsed(_ collapsed: Bool, notify: Bool = false) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        content.isHidden = collapsed
        updateDisclosureImage()
        if notify { onToggle?(collapsed) }
    }

    private func updateDisclosureImage() {
        disclosure.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
    }

    @objc private func toggle(_ sender: Any?) { setCollapsed(!isCollapsed, notify: true) }
    @objc private func runAction(_ sender: NSButton) { guard sender.tag < actions.count else { return }; actions[sender.tag].handler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { actionsStack.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { actionsStack.animator().alphaValue = 0 }
}

/// 侧栏用的 NSOutlineView：把回车 / 空格等交给控制器（方向键、←→ 折叠展开保留系统行为）；右键先选中该行
final class SidebarOutlineView: NSOutlineView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onMenu: ((Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return onMenu?(row) ?? super.menu(for: event)
    }
}

/// 侧栏统一的行样式：图标 + 文字，13 pt（HIG 侧栏标准）
@MainActor
enum SidebarRowStyle {
    static let rowHeight: CGFloat = 24
    static let outlineRowHeight: CGFloat = 22
    static let font = NSFont.systemFont(ofSize: 13)
    static let cellID = NSUserInterfaceItemIdentifier("sidebar.cell")

    static func makeOutlineView() -> SidebarOutlineView {
        let v = SidebarOutlineView()
        v.headerView = nil
        v.style = .sourceList
        v.rowSizeStyle = .default
        v.floatsGroupRows = false
        v.indentationPerLevel = 16
        v.indentationMarkerFollowsCell = true
        v.autoresizesOutlineColumn = true
        v.allowsEmptySelection = true
        v.usesAutomaticRowHeights = false
        v.focusRingType = .none
        let col = NSTableColumn(identifier: .init("main"))
        col.isEditable = true
        v.addTableColumn(col)
        v.outlineTableColumn = col
        return v
    }

    static func makeScrollView(_ inner: NSView) -> NSScrollView {
        let sv = NSScrollView()
        sv.documentView = inner
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }

    /// 复用的 cell（图标 + 单行文字）
    static func cell(in outlineView: NSOutlineView) -> NSTableCellView {
        if let reused = outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView { return reused }
        let cell = NSTableCellView()
        cell.identifier = cellID
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyDown
        iv.contentTintColor = .secondaryLabelColor
        let tf = NSTextField(labelWithString: "")
        tf.font = font
        tf.lineBreakMode = .byTruncatingTail
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.truncatesLastVisibleLine = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iv); cell.addSubview(tf)
        cell.imageView = iv; cell.textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }
}
