import AppKit
import QuireCore
import QuireRender

/// 侧栏节点：文件夹 / 文件 / 标题。子节点懒加载。
@MainActor
final class SidebarNode {
    enum Kind { case folder, file, heading }
    let kind: Kind
    let url: URL?                 // folder / file
    var name: String
    var level = 0                 // heading
    var line: Int?                // heading（其他文件用行号跳转；当前文件用 blockIndex）
    var blockIndex: Int?
    var children: [SidebarNode]?  // nil = 未加载
    var isLoading = false
    var onLoaded: [@MainActor @Sendable () -> Void] = []   // 加载完成后的回调（可能在加载中被多次请求）
    weak var parent: SidebarNode?

    init(kind: Kind, url: URL?, name: String, parent: SidebarNode?) {
        self.kind = kind; self.url = url; self.name = name; self.parent = parent
    }

    var isMarkdown: Bool { kind == .file && QuireDocumentController.markdownExtensions.contains(url?.pathExtension.lowercased() ?? "") }
}

/// 侧栏：目录树 → Markdown 文件 → 文件内大纲（当前文档用完整解析结果，其他文件展开时快速扫描）。
/// 性能：目录/标题只在展开时后台加载；FSEvents 单流监听目录变化；图标为缓存的 SF Symbol；节点与行视图复用。
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    // 输入
    var currentURL: URL? { didSet { if currentURL != oldValue { currentURLDidChange() } } }
    var outline: Outline = Outline(entries: []) { didSet { if outline != oldValue { outlineDidChange() } } }
    // 输出
    var onSelectHeading: ((Outline.Entry) -> Void)?
    var onOpenFile: ((URL, Int?) -> Void)?

    private(set) var rootURL: URL? { didSet { if rootURL != oldValue { rootDidChange() } } }
    private var rootNode: SidebarNode?
    private var currentFileNode: SidebarNode?
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var pathControl: NSPathControl!
    private var emptyLabel: NSTextField!
    private var watcher: FolderWatcher?
    private var suppressSelection = false
    private var headingCache: [URL: (mtime: Date, headings: [HeadingScanner.Heading])] = [:]
    private let ioQueue = DispatchQueue(label: "com.korako.quire.sidebar.io", qos: .userInitiated)
    nonisolated private static let maxChildren = 5000
    nonisolated private static let maxScanBytes = 4 * 1024 * 1024

    private static let folderIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: "文件夹")
    private static let fileIcon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "文档")
    private static let otherIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: "文件")

    override func loadView() {
        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 12
        outlineView.autoresizesOutlineColumn = true
        outlineView.allowsEmptySelection = true
        outlineView.usesAutomaticRowHeights = false
        let col = NSTableColumn(identifier: .init("main"))
        col.isEditable = false
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        pathControl = NSPathControl()
        pathControl.pathStyle = .popUp
        pathControl.isEditable = true
        pathControl.allowedTypes = ["public.folder"]
        pathControl.placeholderString = "选择文件夹…"
        pathControl.font = .systemFont(ofSize: 11)
        pathControl.controlSize = .small
        pathControl.target = self
        pathControl.action = #selector(pathChanged(_:))
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        emptyLabel = NSTextField(wrappingLabelWithString: "存储文档后显示所在文件夹的文件树")
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState
        container.addSubview(pathControl)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            pathControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            pathControl.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            pathControl.heightAnchor.constraint(equalToConstant: 22),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        currentURLDidChange()
    }

    // MARK: - 根目录 / 当前文档

    private func currentURLDidChange() {
        guard outlineView != nil else { return }
        guard let url = currentURL else {
            if rootURL == nil { emptyLabel.isHidden = false; scrollView.isHidden = true; pathControl.isHidden = true }
            return
        }
        emptyLabel.isHidden = true; scrollView.isHidden = false; pathControl.isHidden = false
        let folder = url.deletingLastPathComponent()
        // 根目录未设置，或当前文档不在根目录下 → 根 = 文档所在目录
        if rootURL == nil || !url.standardizedFileURL.path.hasPrefix(rootURL!.standardizedFileURL.path + "/") {
            rootURL = folder
        } else {
            revealCurrentFile()
        }
    }

    /// 用户选择根目录（NSPathControl / 菜单）
    func setRoot(_ url: URL) { rootURL = url }

    /// 显示当前文件：若不在根目录下则把根切到其所在目录
    func revealCurrent() {
        guard let url = currentURL else { return }
        if let root = rootURL, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") { revealCurrentFile() }
        else { rootURL = url.deletingLastPathComponent() }
    }

    private func rootDidChange() {
        guard outlineView != nil, let root = rootURL else { return }
        pathControl.url = root
        rootNode = SidebarNode(kind: .folder, url: root, name: root.lastPathComponent, parent: nil)
        currentFileNode = nil
        outlineView.reloadData()
        loadChildren(of: rootNode!) { [weak self] in self?.revealCurrentFile() }
        watcher = FolderWatcher(url: root) { [weak self] dirs in
            Task { @MainActor [weak self] in self?.foldersDidChange(dirs) }
        }
    }

    @objc private func pathChanged(_ sender: NSPathControl) {
        if let item = sender.clickedPathItem, let url = item.url { rootURL = url; return }
        if let url = sender.url { rootURL = url }
    }

    /// 展开到当前文档并把它的大纲挂上
    private func revealCurrentFile() {
        guard let root = rootNode, let cur = currentURL?.standardizedFileURL else { return }
        let rootPath = root.url!.standardizedFileURL.path
        guard cur.path.hasPrefix(rootPath + "/") else { return }
        let rel = String(cur.path.dropFirst(rootPath.count + 1)).split(separator: "/").map(String.init)
        descend(node: root, components: rel[...])
    }

    private func descend(node: SidebarNode, components: ArraySlice<String>) {
        guard let name = components.first else { return }
        let rest = components.dropFirst()
        func proceed() {
            guard let child = node.children?.first(where: { $0.name == name }) else { return }
            if child.kind == .folder {
                outlineView.expandItem(child)
                if child.children == nil { loadChildren(of: child) { [weak self] in self?.descend(node: child, components: rest) } }
                else { descend(node: child, components: rest) }
            } else if rest.isEmpty {
                setCurrentFileNode(child)
            }
        }
        if node.children == nil { loadChildren(of: node) { proceed() } } else { proceed() }
    }

    private func setCurrentFileNode(_ node: SidebarNode) {
        let previous = currentFileNode
        currentFileNode = node
        applyOutline(to: node)
        if let previous, previous !== node { outlineView.reloadItem(previous, reloadChildren: false) }
        outlineView.reloadItem(node, reloadChildren: true)
        outlineView.expandItem(node, expandChildren: true)
        let row = outlineView.row(forItem: node)
        if row >= 0 { outlineView.scrollRowToVisible(row) }
    }

    private func outlineDidChange() {
        guard let node = currentFileNode else { return }
        applyOutline(to: node)
        outlineView.reloadItem(node, reloadChildren: true)
        outlineView.expandItem(node, expandChildren: true)
    }

    /// 当前文档：用完整解析的大纲建标题树
    private func applyOutline(to fileNode: SidebarNode) {
        fileNode.children = buildHeadingTree(fileNode: fileNode, entries: outline.entries.map { ($0.level, $0.title, $0.line, $0.blockIndex) })
    }

    private func buildHeadingTree(fileNode: SidebarNode, entries: [(Int, String, Int?, Int?)]) -> [SidebarNode] {
        var roots: [SidebarNode] = []
        var stack: [SidebarNode] = []
        for (level, title, line, blockIndex) in entries {
            while let last = stack.last, last.level >= level { stack.removeLast() }
            let parent = stack.last ?? fileNode
            let n = SidebarNode(kind: .heading, url: fileNode.url, name: title.isEmpty ? "（无标题）" : title, parent: parent)
            n.level = level; n.line = line; n.blockIndex = blockIndex
            n.children = []
            if let p = stack.last { p.children!.append(n) } else { roots.append(n) }
            stack.append(n)
        }
        return roots
    }

    // MARK: - 懒加载

    private func loadChildren(of node: SidebarNode, completion: (@MainActor @Sendable () -> Void)? = nil) {
        if let completion { node.onLoaded.append(completion) }
        guard !node.isLoading else { return }
        node.isLoading = true
        switch node.kind {
        case .folder:
            guard let url = node.url else { return }
            ioQueue.async {
                let entries = Self.listFolder(url)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    node.isLoading = false
                    self.mergeChildren(node, entries: entries)
                    self.reload(node)
                    self.fireLoaded(node)
                }
            }
        case .file:
            guard let url = node.url else { return }
            let cached = headingCache[url]
            ioQueue.async {
                var result: [HeadingScanner.Heading] = []
                var mtime = Date.distantPast
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let m = attrs[.modificationDate] as? Date, let size = attrs[.size] as? Int {
                    mtime = m
                    if let cached, cached.mtime == m { result = cached.headings }
                    else if size <= Self.maxScanBytes, let data = try? Data(contentsOf: url, options: .mappedIfSafe) { result = HeadingScanner.scan(data, maxHeadings: 500) }
                }
                let headings = result
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    node.isLoading = false
                    self.headingCache[url] = (mtime, headings)
                    if node !== self.currentFileNode {
                        node.children = self.buildHeadingTree(fileNode: node, entries: headings.map { ($0.level, $0.title, $0.line, nil) })
                    }
                    self.reload(node)
                    self.fireLoaded(node)
                }
            }
        case .heading:
            node.isLoading = false
            node.children = []
            fireLoaded(node)
        }
    }

    private func fireLoaded(_ node: SidebarNode) {
        let cbs = node.onLoaded; node.onLoaded = []
        // 下一轮执行：让 reload 后的行先建立
        DispatchQueue.main.async { cbs.forEach { $0() } }
    }

    /// 根节点不是 outline item（顶层 = nil 的子项），要整体 reload
    private func reload(_ node: SidebarNode) {
        if node === rootNode { outlineView.reloadData() } else { outlineView.reloadItem(node, reloadChildren: true) }
    }

    /// 目录列表（后台）：可见项，文件夹优先，自然排序；只列 Markdown 文件与文件夹
    nonisolated private static func listFolder(_ url: URL) -> [(URL, Bool)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var folders: [(URL, Bool)] = [], files: [(URL, Bool)] = []
        for u in items {
            guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { continue }
            if v.isDirectory == true, v.isPackage != true { folders.append((u, true)) }
            else if QuireDocumentController.markdownExtensions.contains(u.pathExtension.lowercased()) { files.append((u, false)) }
        }
        let cmp: ((URL, Bool), (URL, Bool)) -> Bool = { $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending }
        folders.sort(by: cmp); files.sort(by: cmp)
        var out = folders + files
        if out.count > maxChildren { out = Array(out.prefix(maxChildren)) }
        return out
    }

    /// 合并新列表到已有子节点（按 URL 复用旧节点，保持展开状态与已加载的子树）
    private func mergeChildren(_ node: SidebarNode, entries: [(URL, Bool)]) {
        var existing: [String: SidebarNode] = [:]
        for c in node.children ?? [] { if let u = c.url { existing[u.standardizedFileURL.path] = c } }
        node.children = entries.map { url, isDir in
            if let old = existing[url.standardizedFileURL.path] { return old }
            return SidebarNode(kind: isDir ? .folder : .file, url: url, name: url.lastPathComponent, parent: node)
        }
    }

    // MARK: - 目录变化（FSEvents）

    private func foldersDidChange(_ dirs: [URL]) {
        guard let root = rootNode else { return }
        var seen = Set<String>()
        for d in dirs {
            let p = d.standardizedFileURL.path
            guard seen.insert(p).inserted, let node = findFolderNode(path: p, from: root), node.children != nil else { continue }
            // 该目录下的文件可能变了：标题缓存失效；已展开的重扫
            for c in node.children ?? [] where c.kind == .file && c !== currentFileNode {
                if let u = c.url { headingCache.removeValue(forKey: u) }
                if c.children != nil, outlineView.isItemExpanded(c) { c.children = nil; loadChildren(of: c) }
            }
            loadChildren(of: node)   // 增删改名 → 重列（按 URL 复用节点）
        }
    }

    private func findFolderNode(path: String, from node: SidebarNode) -> SidebarNode? {
        guard let np = node.url?.standardizedFileURL.path else { return nil }
        if np == path { return node }
        guard path.hasPrefix(np + "/"), let children = node.children else { return nil }
        for c in children where c.kind == .folder {
            if let f = findFolderNode(path: path, from: c) { return f }
        }
        return nil
    }

    // MARK: - 高亮当前标题

    func highlight(blockIndex: Int) {
        guard let file = currentFileNode, let children = file.children, !children.isEmpty else { return }
        // 扁平化当前文件的标题
        var flat: [SidebarNode] = []
        func walk(_ n: SidebarNode) { for c in n.children ?? [] { flat.append(c); walk(c) } }
        walk(file)
        var target: SidebarNode?
        for n in flat { if let b = n.blockIndex, b <= blockIndex { target = n } else if n.blockIndex != nil { break } }
        guard let target else { return }
        let row = outlineView.row(forItem: target)
        guard row >= 0, outlineView.selectedRow != row else { return }
        suppressSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        suppressSelection = false
    }

    // MARK: - 交互


    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode else { return }
        activate(node)
    }
    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode else { return }
        if node.kind == .folder { outlineView.isItemExpanded(node) ? outlineView.collapseItem(node) : outlineView.expandItem(node) }
        else { activate(node) }
    }

    private var lastActivation: (ObjectIdentifier, TimeInterval)?
    private func activate(_ node: SidebarNode) {
        // 鼠标点击会同时触发 action 与 selectionDidChange：100 ms 内同一节点只处理一次
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastActivation, last.0 == ObjectIdentifier(node), now - last.1 < 0.1 { return }
        lastActivation = (ObjectIdentifier(node), now)
        switch node.kind {
        case .heading:
            if let file = fileNode(of: node), file === currentFileNode, let bi = node.blockIndex {
                onSelectHeading?(Outline.Entry(id: "", level: node.level, title: node.name, blockIndex: bi, line: node.line))
            } else if let url = node.url {
                onOpenFile?(url, node.line)
            }
        case .file:
            if let url = node.url, url.standardizedFileURL != currentURL?.standardizedFileURL { onOpenFile?(url, nil) }
        case .folder:
            break
        }
    }

    private func fileNode(of heading: SidebarNode) -> SidebarNode? {
        var n: SidebarNode? = heading
        while let cur = n, cur.kind == .heading { n = cur.parent }
        return n
    }

    // MARK: - 拖放（打开 Markdown 文件）

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard DropSupport.fileURLs(from: info).contains(where: DropSupport.isMarkdown) else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = DropSupport.fileURLs(from: info).filter(DropSupport.isMarkdown)
        guard !urls.isEmpty else { return false }
        FileOpener.open(urls)
        return true
    }

    // MARK: - DataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? SidebarNode) ?? rootNode
        guard let node else { return 0 }
        if node.children == nil { loadChildren(of: node); return 0 }
        return node.children!.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? SidebarNode) ?? rootNode!
        return node.children![index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? SidebarNode else { return false }
        switch n.kind {
        case .folder: return true
        case .file: return n.isMarkdown && (n.children?.isEmpty == false || n.children == nil)
        case .heading: return !(n.children?.isEmpty ?? true)
        }
    }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyDown
            iv.contentTintColor = .secondaryLabelColor
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv); cell.addSubview(tf)
            cell.imageView = iv; cell.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = node.name
        cell.toolTip = node.kind == .heading ? node.name : node.url?.path
        switch node.kind {
        case .folder:
            cell.imageView?.image = Self.folderIcon
            cell.imageView?.isHidden = false
            cell.textField?.font = .systemFont(ofSize: 12.5)
            cell.textField?.textColor = .labelColor
        case .file:
            cell.imageView?.image = node.isMarkdown ? Self.fileIcon : Self.otherIcon
            cell.imageView?.isHidden = false
            let isCurrent = node === currentFileNode
            cell.textField?.font = .systemFont(ofSize: 12.5, weight: isCurrent ? .semibold : .regular)
            cell.textField?.textColor = .labelColor
            cell.imageView?.contentTintColor = isCurrent ? .controlAccentColor : .secondaryLabelColor
        case .heading:
            cell.imageView?.image = nil
            cell.imageView?.isHidden = true
            cell.textField?.font = node.level <= 1 ? .systemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 12)
            cell.textField?.textColor = node.level >= 4 ? .secondaryLabelColor : .labelColor
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 22 }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        if node.children == nil { loadChildren(of: node) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode, node.kind == .heading else { return }
        activate(node)   // 键盘导航标题也跳转
    }
}
