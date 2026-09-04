import AppKit
import QuireCore

/// 「收藏」段：收藏的文件列表
@MainActor
final class FavoritesController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView = SidebarRowStyle.makeOutlineView()
    private(set) lazy var scrollView = SidebarRowStyle.makeScrollView(outlineView)
    private(set) var urls: [URL] = []
    var onOpenFile: ((URL) -> Void)?
    var onChange: (() -> Void)?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    override init() {
        super.init()
        outlineView.dataSource = self; outlineView.delegate = self
        outlineView.target = self; outlineView.action = #selector(rowClicked(_:))
        outlineView.onKeyDown = { [weak self] e in self?.keyDown(e) ?? false }
        outlineView.onMenu = { [weak self] row in self?.menu(forRow: row) }
        outlineView.setAccessibilityLabel(L("收藏"))
        observer = NotificationCenter.default.addObserver(forName: Favorites.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func reload() {
        urls = Favorites.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        outlineView.reloadData()
        onChange?()
    }
    var count: Int { urls.count }
    /// 内容高度（段展开时按需给高度，最多几行）
    var preferredHeight: CGFloat { CGFloat(max(1, min(urls.count, 6))) * SidebarRowStyle.rowHeight + 4 }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, row < urls.count else { return }
        onOpenFile?(urls[row])
    }
    private func keyDown(_ e: NSEvent) -> Bool {
        guard e.keyCode == 36 || e.keyCode == 76, outlineView.selectedRow >= 0, outlineView.selectedRow < urls.count else { return false }
        onOpenFile?(urls[outlineView.selectedRow]); return true
    }
    private func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < urls.count else { return nil }
        let menu = NSMenu()
        let rm = NSMenuItem(title: L("从收藏移除"), action: #selector(removeItem(_:)), keyEquivalent: ""); rm.target = self; rm.representedObject = urls[row]
        let rv = NSMenuItem(title: L("在 Finder 中显示"), action: #selector(revealItem(_:)), keyEquivalent: ""); rv.target = self; rv.representedObject = urls[row]
        menu.addItem(rm); menu.addItem(rv)
        return menu
    }
    @objc private func removeItem(_ s: NSMenuItem) { if let u = s.representedObject as? URL { Favorites.remove(u) } }
    @objc private func revealItem(_ s: NSMenuItem) { if let u = s.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? urls.count : 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { urls[index] as NSURL }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { SidebarRowStyle.rowHeight }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let u = item as? URL else { return nil }
        let cell = SidebarRowStyle.cell(in: outlineView)
        cell.imageView?.isHidden = false
        cell.imageView?.image = SidebarRowStyle.symbol("star.fill", L("收藏"))
        cell.imageView?.contentTintColor = .systemYellow
        cell.textField?.isEditable = false
        cell.textField?.stringValue = FileTreeController.displayName(u, ambiguous: false)
        cell.textField?.font = SidebarRowStyle.font
        cell.textField?.textColor = .labelColor
        cell.textField?.toolTip = u.path
        return cell
    }
}

/// 「标签」段：根目录下扫出来的 `#标签`，`#a/b` 按 `/` 嵌套成树；点标签 = 搜索它
@MainActor
final class TagsController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
        let name: String        // 本级名（b）
        let full: String        // 完整标签（a/b）
        var count = 0
        var children: [Node] = []
        init(name: String, full: String) { self.name = name; self.full = full }
    }
    let outlineView = SidebarRowStyle.makeOutlineView()
    private(set) lazy var scrollView = SidebarRowStyle.makeScrollView(outlineView)
    private(set) var roots: [Node] = []
    private(set) var totalTags = 0
    var onSearchTag: ((String) -> Void)?
    var onChange: (() -> Void)?
    private var store: TagIndexStore?
    private var token: ChangeObservers.Token?

    override init() {
        super.init()
        outlineView.dataSource = self; outlineView.delegate = self
        outlineView.indentationPerLevel = 14
        outlineView.target = self; outlineView.action = #selector(rowClicked(_:))
        outlineView.onKeyDown = { [weak self] e in self?.keyDown(e) ?? false }
        outlineView.setAccessibilityLabel(L("标签"))
    }

    var root: URL? {
        didSet {
            guard let root else { store = nil; token = nil; roots = []; totalTags = 0; outlineView.reloadData(); onChange?(); return }
            store = TagIndexStore.store(for: root)
            token = store?.observers.add { [weak self] in self?.reload() }
            reload()
        }
    }

    func reload() {
        let tags = store?.tags ?? []
        totalTags = tags.count
        let top = Node(name: "", full: "")
        var index: [String: Node] = ["": top]
        func node(_ full: String) -> Node {
            if let n = index[full] { return n }
            let parts = full.split(separator: "/")
            let parentFull = parts.dropLast().joined(separator: "/")
            let p = node(parentFull)
            let n = Node(name: String(parts.last ?? Substring(full)), full: full)
            p.children.append(n)
            index[full] = n
            return n
        }
        for t in tags.prefix(500) { node(t.tag).count = t.files.count }
        // 父级计数 = 自己 + 子级
        func total(_ n: Node) -> Int { n.count + n.children.reduce(0) { $0 + total($1) } }
        func sort(_ n: Node) { n.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }; n.children.forEach(sort) }
        sort(top)
        roots = top.children
        for n in roots where !n.children.isEmpty { n.count = total(n) }
        outlineView.reloadData()
        onChange?()
    }
    var count: Int { totalTags }
    var preferredHeight: CGFloat { CGFloat(max(1, min(roots.count, 8))) * SidebarRowStyle.rowHeight + 4 }

    @objc private func rowClicked(_ sender: Any?) {
        guard let n = outlineView.item(atRow: outlineView.clickedRow) as? Node else { return }
        onSearchTag?("#" + n.full)
    }
    private func keyDown(_ e: NSEvent) -> Bool {
        guard e.keyCode == 36 || e.keyCode == 76, let n = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return false }
        onSearchTag?("#" + n.full); return true
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? Node)?.children ?? roots).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { SidebarRowStyle.rowHeight }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let cell = SidebarRowStyle.cell(in: outlineView)
        cell.imageView?.isHidden = false
        cell.imageView?.image = SidebarRowStyle.symbol("number", L("标签"))
        cell.imageView?.contentTintColor = .secondaryLabelColor
        cell.textField?.isEditable = false
        let s = NSMutableAttributedString(string: n.name, attributes: [.font: SidebarRowStyle.font, .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: "  \(n.count)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]))
        cell.textField?.attributedStringValue = s
        cell.textField?.toolTip = "#" + n.full
        return cell
    }
}
