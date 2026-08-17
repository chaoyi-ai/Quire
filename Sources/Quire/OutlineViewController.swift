import AppKit
import QuireCore

/// 目录侧栏：标题树；点击跳转；滚动联动高亮。
@MainActor
final class OutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
        let entry: Outline.Entry
        var children: [Node] = []
        init(_ e: Outline.Entry) { entry = e }
    }

    var outline: Outline = Outline(entries: []) { didSet { rebuild() } }
    var onSelect: ((Outline.Entry) -> Void)?

    private var roots: [Node] = []
    private var flat: [Node] = []          // 按文档顺序
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var suppressSelection = false

    override func loadView() {
        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 12
        outlineView.autoresizesOutlineColumn = true
        outlineView.allowsEmptySelection = true
        let col = NSTableColumn(identifier: .init("title"))
        col.isEditable = false
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        emptyLabel = NSTextField(labelWithString: "无标题")
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 220, height: 600)
        view = container
        rebuild()
    }

    private func rebuild() {
        guard isViewLoaded else { return }
        roots = []; flat = []
        var stack: [Node] = []
        for e in outline.entries {
            let node = Node(e)
            flat.append(node)
            while let last = stack.last, last.entry.level >= e.level { stack.removeLast() }
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            stack.append(node)
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        emptyLabel.isHidden = !flat.isEmpty
    }

    /// 高亮包含 blockIndex 的最近标题
    func highlight(blockIndex: Int) {
        guard isViewLoaded, !flat.isEmpty else { return }
        var target: Node?
        for n in flat { if n.entry.blockIndex <= blockIndex { target = n } else { break } }
        guard let target else { return }
        let row = outlineView.row(forItem: target)
        guard row >= 0, outlineView.selectedRow != row else { return }
        suppressSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        suppressSelection = false
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node else { return }
        onSelect?(node.entry)
    }

    // MARK: DataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = node.entry.title.isEmpty ? "（无标题）" : node.entry.title
        cell.textField?.font = node.entry.level <= 1 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12.5)
        cell.textField?.textColor = node.entry.level >= 4 ? .secondaryLabelColor : .labelColor
        cell.toolTip = node.entry.title
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 24 }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        // 键盘导航也跳转
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node else { return }
        onSelect?(node.entry)
    }
}
