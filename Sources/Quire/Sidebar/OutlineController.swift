import AppKit
import QuireCore

/// 「大纲」段：只显示当前文档的标题（来自解析结果），跟随阅读位置高亮，可折叠 / 平铺。
@MainActor
final class OutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
        let entry: Outline.Entry
        var children: [Node] = []
        weak var parent: Node?
        init(_ e: Outline.Entry, parent: Node?) { entry = e; self.parent = parent }
    }

    let outlineView = SidebarRowStyle.makeOutlineView()
    private(set) lazy var scrollView = SidebarRowStyle.makeScrollView(outlineView)
    private(set) var roots: [Node] = []
    private var flat: [Node] = []
    private var suppressSelection = false
    private var lastBlockIndex: Int?

    var outline = Outline(entries: []) { didSet { if outline != oldValue { rebuild() } } }
    var isFlat: Bool = SidebarSettings.outlineFlat { didSet { SidebarSettings.outlineFlat = isFlat; rebuild() } }
    var onSelect: ((Outline.Entry) -> Void)?
    var count: Int { outline.entries.count }

    override init() {
        super.init()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.indentationPerLevel = 12
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.onKeyDown = { [weak self] e in self?.keyDown(e) ?? false }
        outlineView.setAccessibilityLabel(L("大纲"))
    }

    private func rebuild() {
        roots = []; flat = []
        var stack: [Node] = []
        for e in outline.entries {
            let n = Node(e, parent: nil)
            flat.append(n)
            if isFlat { roots.append(n); continue }
            while let last = stack.last, last.entry.level >= e.level { stack.removeLast() }
            if let p = stack.last { n.parent = p; p.children.append(n) } else { roots.append(n) }
            stack.append(n)
        }
        outlineView.reloadData()
        // 标题多时只展开到 H2，免得一屏都是三级标题
        if outline.entries.count > 200 { for n in roots { outlineView.expandItem(n); for c in n.children { outlineView.expandItem(c) } } }
        else { outlineView.expandItem(nil, expandChildren: true) }
        if let b = lastBlockIndex { highlight(blockIndex: b) }
    }

    func expandAll() { outlineView.expandItem(nil, expandChildren: true) }
    func collapseAll() { for n in roots { outlineView.collapseItem(n, collapseChildren: true) } }

    /// 阅读视图当前章节 → 高亮对应标题（祖先折叠着就展开）
    func highlight(blockIndex: Int) {
        lastBlockIndex = blockIndex
        var target: Node?
        for n in flat { if n.entry.blockIndex <= blockIndex { target = n } else { break } }
        guard let target else { return }
        var p = target.parent
        var chain: [Node] = []
        while let x = p { chain.append(x); p = x.parent }
        for a in chain.reversed() where !outlineView.isItemExpanded(a) { outlineView.expandItem(a) }
        let row = outlineView.row(forItem: target)
        guard row >= 0, outlineView.selectedRow != row else { return }
        suppressSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        suppressSelection = false
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let n = outlineView.item(atRow: row) as? Node else { return }
        onSelect?(n.entry)
    }
    private func keyDown(_ e: NSEvent) -> Bool {
        guard e.keyCode == 36 || e.keyCode == 76, let n = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return false }
        onSelect?(n.entry); return true
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? Node)?.children ?? roots).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { SidebarRowStyle.outlineRowHeight }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let cell = SidebarRowStyle.cell(in: outlineView)
        cell.imageView?.isHidden = true
        let tf = cell.textField!
        tf.isEditable = false
        tf.stringValue = n.entry.title.isEmpty ? L("（无标题）") : n.entry.title
        tf.font = n.entry.level <= 1 ? .systemFont(ofSize: 12.5, weight: .medium) : .systemFont(ofSize: 12.5)
        tf.textColor = n.entry.level >= 4 ? .secondaryLabelColor : .labelColor
        tf.toolTip = n.entry.title
        // 平铺模式：用缩进表达层级
        cell.textField?.attributedStringValue = NSAttributedString(string: tf.stringValue, attributes: [.font: tf.font!, .foregroundColor: tf.textColor!, .paragraphStyle: { let p = NSMutableParagraphStyle(); p.firstLineHeadIndent = isFlat ? CGFloat(max(0, n.entry.level - 1)) * 12 : 0; p.lineBreakMode = .byTruncatingTail; return p }()])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let n = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return }
        onSelect?(n.entry)   // 键盘上下走标题也跳转
    }
}
