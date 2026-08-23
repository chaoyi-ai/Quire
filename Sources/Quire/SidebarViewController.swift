import AppKit
import Quartz
import QuireCore
import QuireRender

/// 侧栏节点：文件夹 / 文件 / 标题。子节点懒加载。
@MainActor
final class SidebarNode {
    enum Kind { case folder, file, heading, hit, tag, section }   // hit = 全局搜索命中行；tag = 标签；section = 收藏 / 最近 / 标签 的虚拟分组
    let kind: Kind
    let url: URL?                 // folder / file
    var name: String
    var level = 0                 // heading
    var line: Int?                // heading（其他文件用行号跳转；当前文件用 blockIndex）
    var blockIndex: Int?
    var hitRange: NSRange?        // hit：命中在 name 里的范围
    var children: [SidebarNode]?  // nil = 未加载
    var isLoading = false
    var onLoaded: [@MainActor @Sendable () -> Void] = []   // 加载完成后的回调（可能在加载中被多次请求）
    weak var parent: SidebarNode?

    init(kind: Kind, url: URL?, name: String, parent: SidebarNode?) {
        self.kind = kind; self.url = url; self.name = name; self.parent = parent
    }

    var isMarkdown: Bool {
        guard kind == .file, let ext = url?.pathExtension.lowercased() else { return false }
        return QuireDocumentController.markdownExtensions.contains(ext) || Preferences.shared.extraExtensionSet.contains(ext)
    }
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
    // 全局搜索
    private var searchField: NSSearchField!
    private var searchFieldHeight: NSLayoutConstraint!
    private var searchRoot: SidebarNode?
    private var searchWork: DispatchWorkItem?
    private var activeSearch: ContentSearch?
    private let searchQueue = DispatchQueue(label: "com.korako.quire.search", qos: .userInitiated)
    private var isSearching: Bool { searchRoot != nil }
    private var watcher: FolderWatcher?
    private var suppressSelection = false
    private var headingCache: [URL: (mtime: Date, headings: [HeadingScanner.Heading])] = [:]
    private let ioQueue = DispatchQueue(label: "com.korako.quire.sidebar.io", qos: .userInitiated)
    nonisolated private static let maxChildren = 5000
    nonisolated private static let maxScanBytes = 4 * 1024 * 1024

    private static let folderIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: L("文件夹"))
    private static let fileIcon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: L("文档"))
    private static let otherIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: L("文件"))

    override func loadView() {
        outlineView = SidebarOutlineView()
        (outlineView as? SidebarOutlineView)?.onKeyDown = { [weak self] e in self?.outlineViewKeyDown(e) ?? false }
        (outlineView as? SidebarOutlineView)?.onMenu = { [weak self] row in self?.outlineViewMenu(for: row) }
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
        pathControl.placeholderString = L("选择文件夹…")
        pathControl.font = .systemFont(ofSize: 11)
        pathControl.controlSize = .small
        pathControl.target = self
        pathControl.action = #selector(pathChanged(_:))
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        searchField = NSSearchField()
        searchField.placeholderString = L("搜索文件内容…")
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isHidden = true

        emptyLabel = NSTextField(wrappingLabelWithString: L("存储文档后显示所在文件夹的文件树"))
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState
        container.addSubview(pathControl)
        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        searchFieldHeight = searchField.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            pathControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            pathControl.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            pathControl.heightAnchor.constraint(equalToConstant: 22),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 6),
            searchFieldHeight,
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
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
        prefsObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let rules = Preferences.shared.sidebarRules
                if rules != self.lastRules { self.lastRules = rules; self.reloadTree() }
            }
        }
        lastRules = Preferences.shared.sidebarRules
    }
    private var prefsObserver: NSObjectProtocol?
    private var lastRules: Preferences.SidebarRules?

    /// 规则变了：重扫所有已加载的文件夹（保持展开状态）
    private func reloadTree() {
        guard let root = rootNode else { return }
        func walk(_ n: SidebarNode) {
            if n.kind == .folder, n.children != nil { loadChildren(of: n) }
            for c in n.children ?? [] where c.kind == .folder { walk(c) }
        }
        walk(root)
    }

    // MARK: - 根目录 / 当前文档

    /// 空态 / 树 的显示只由"有没有根目录"决定（以前只在 currentURL 变化时切，未命名文档设了根目录仍显示"存储后显示"）
    private func updateEmptyState() {
        let hasRoot = rootURL != nil
        emptyLabel.isHidden = hasRoot; scrollView.isHidden = !hasRoot; pathControl.isHidden = !hasRoot
    }

    private func currentURLDidChange() {
        guard outlineView != nil else { return }
        guard let url = currentURL else { updateEmptyState(); return }
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
        guard outlineView != nil, let root = rootURL else { updateEmptyState(); return }
        pathControl.url = root
        updateEmptyState()
        rootNode = SidebarNode(kind: .folder, url: root, name: root.lastPathComponent, parent: nil)
        currentFileNode = nil
        sectionNodes = [:]; seenSections = []; tagStore = nil; tagToken = nil
        outlineView.reloadData()
        loadChildren(of: rootNode!) { [weak self] in self?.revealCurrentFile() }
        watcher = FolderWatcher(url: root) { [weak self] dirs in
            Task { @MainActor [weak self] in
                self?.foldersDidChange(dirs)
                if let r = self?.rootURL { FileIndex.index(for: r).directoriesChanged() }   // 快速打开索引共用这一条 FSEvents 流
            }
        }
        _ = FileIndex.index(for: root)   // 预热：打开文件夹时就开始后台扫
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
            let n = SidebarNode(kind: .heading, url: fileNode.url, name: title.isEmpty ? L("（无标题）") : title, parent: parent)
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
            let rules = Preferences.shared.sidebarRules
            ioQueue.async {
                let entries = Self.listFolder(url, rules: rules)
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
        case .heading, .hit, .tag, .section:
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
        if node === rootNode { outlineView.reloadData(); expandSectionsIfNew() } else { outlineView.reloadItem(node, reloadChildren: true) }
    }

    /// 目录列表（后台）：可见项，文件夹优先，自然排序；只列 Markdown 文件与文件夹
    nonisolated private static func listFolder(_ url: URL, rules: Preferences.SidebarRules) -> [(URL, Bool)] {
        let fm = FileManager.default
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !rules.showHidden { opts.insert(.skipsHiddenFiles) }
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isPackageKey], options: opts) else { return [] }
        var folders: [(URL, Bool)] = [], files: [(URL, Bool)] = []
        for u in items {
            guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { continue }
            let ext = u.pathExtension.lowercased()
            if v.isDirectory == true, v.isPackage != true { folders.append((u, true)) }
            else if QuireDocumentController.markdownExtensions.contains(ext) || rules.extraExtensions.contains(ext) || rules.showOthers { files.append((u, false)) }
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
        for c in node.children ?? [] { if let u = c.url, c.kind != .section { existing[u.standardizedFileURL.path] = c } }
        var children = entries.map { url, isDir -> SidebarNode in
            if let old = existing[url.standardizedFileURL.path] { return old }
            return SidebarNode(kind: isDir ? .folder : .file, url: url, name: url.lastPathComponent, parent: node)
        }
        if node === rootNode { children = virtualSections() + children }   // 收藏 / 最近 / 标签 挂在根的最上面
        node.children = children
    }

    // MARK: - 虚拟分组：收藏 / 最近 / 标签

    private var sectionNodes: [String: SidebarNode] = [:]
    private var tagStore: TagIndexStore?
    private var tagToken: ChangeObservers.Token?
    nonisolated(unsafe) private var favoritesObserver: NSObjectProtocol?

    private func virtualSections() -> [SidebarNode] {
        func section(_ key: String, _ title: String) -> SidebarNode {
            if let n = sectionNodes[key] { n.name = title; return n }
            let n = SidebarNode(kind: .section, url: rootURL, name: title, parent: rootNode)
            n.children = []
            sectionNodes[key] = n
            return n
        }
        let fav = section("fav", L("收藏")), recent = section("recent", L("最近")), tags = section("tags", L("标签"))
        refreshFavorites(fav); refreshRecents(recent); refreshTags(tags)
        if tagStore == nil, let root = rootURL {
            tagStore = TagIndexStore.store(for: root)
            tagToken = tagStore?.observers.add { [weak self] in self?.reinsertSections() }
            if favoritesObserver == nil {
                favoritesObserver = NotificationCenter.default.addObserver(forName: Favorites.didChange, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reinsertSections() }
                }
            }
        }
        return [fav, recent, tags].filter { !($0.children?.isEmpty ?? true) }
    }

    /// 分组内容变了（标签扫完 / 收藏改了）：重建根的前几个虚拟节点，保留真实目录节点
    private func reinsertSections() {
        guard let root = rootNode, !isSearching else { return }
        let real = (root.children ?? []).filter { $0.kind != .section }
        root.children = virtualSections() + real
        outlineView.reloadData()
        expandSectionsIfNew()
    }

    /// 分组首次出现时默认展开；用户手动折叠过的不再打开（节点对象复用，reloadData 会保留展开状态）
    private var seenSections: Set<ObjectIdentifier> = []
    private func expandSectionsIfNew() {
        for n in rootNode?.children ?? [] where n.kind == .section {
            let id = ObjectIdentifier(n)
            if !seenSections.contains(id) { seenSections.insert(id); outlineView.expandItem(n) }
        }
    }

    private func fileNode(_ url: URL, parent: SidebarNode) -> SidebarNode {
        let n = SidebarNode(kind: .file, url: url, name: url.lastPathComponent, parent: parent)
        n.children = []   // 虚拟分组里的文件不展开大纲
        return n
    }
    private func refreshFavorites(_ n: SidebarNode) {
        n.children = Favorites.urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { fileNode($0, parent: n) }
    }
    private func refreshRecents(_ n: SidebarNode) {
        let recents = NSDocumentController.shared.recentDocumentURLs.prefix(10)
        n.children = recents.map { fileNode($0, parent: n) }
    }
    private func refreshTags(_ n: SidebarNode) {
        guard let store = tagStore else { n.children = []; return }
        n.children = store.tags.prefix(200).map { t in
            let node = SidebarNode(kind: .tag, url: nil, name: "#\(t.tag)", parent: n)
            node.level = t.files.count
            return node
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


    func outlineViewMenu(for row: Int) -> NSMenu? {
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode, node.kind == .file, let url = node.url else { return nil }
        let menu = NSMenu()
        let fav = NSMenuItem(title: Favorites.contains(url) ? L("从收藏移除") : L("加入收藏"), action: #selector(toggleFavorite(_:)), keyEquivalent: "")
        fav.representedObject = url; fav.target = self
        menu.addItem(fav)
        let reveal = NSMenuItem(title: L("在 Finder 中显示"), action: #selector(revealNode(_:)), keyEquivalent: "")
        reveal.representedObject = url; reveal.target = self
        menu.addItem(reveal)
        return menu
    }
    @objc private func toggleFavorite(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { Favorites.toggle(u) } }
    @objc private func revealNode(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }

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
        case .section: break
        case .tag:
            // 点标签 = 全局搜索该标签
            showSearch(); searchField.stringValue = node.name; searchChanged(nil)
        case .hit:
            if let url = node.parent?.url { onOpenFile?(url, node.line) }
        case .heading:
            if let file = fileNode(of: node), file === currentFileNode, let bi = node.blockIndex {
                onSelectHeading?(Outline.Entry(id: "", level: node.level, title: node.name, blockIndex: bi, line: node.line))
            } else if let url = node.url {
                onOpenFile?(url, node.line)
            }
        case .file:
            guard let url = node.url else { return }
            if !node.isMarkdown { NSWorkspace.shared.open(url); return }   // 非 Markdown：交给默认 App
            if url.standardizedFileURL != currentURL?.standardizedFileURL { onOpenFile?(url, nil) }
        case .folder:
            break
        }
    }

    /// 键盘：回车打开 / 跳转，空格 Quick Look，←→ 折叠展开由 NSOutlineView 自带
    func outlineViewKeyDown(_ event: NSEvent) -> Bool {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode else { return false }
        switch event.keyCode {
        case 36, 76:   // Return / Enter
            if node.kind == .folder { outlineView.isItemExpanded(node) ? outlineView.collapseItem(node) : outlineView.expandItem(node) } else { activate(node) }
            return true
        case 49:       // Space → Quick Look
            guard node.kind == .file || node.kind == .folder, let url = node.url else { return false }
            quickLookURL = url
            if let panel = QLPreviewPanel.shared() {
                if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
            }
            return true
        default: return false
        }
    }
    private var quickLookURL: URL?

    private func fileNode(of heading: SidebarNode) -> SidebarNode? {
        var n: SidebarNode? = heading
        while let cur = n, cur.kind == .heading { n = cur.parent }
        return n
    }

    // MARK: - 拖放（打开 Markdown 文件）

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard DropSupport.fileURLs(from: info).contains(where: { DropSupport.isMarkdown($0) || DropSupport.isDirectory($0) }) else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let all = DropSupport.fileURLs(from: info)
        if let dir = all.first(where: DropSupport.isDirectory) { setRoot(dir) }
        let urls = all.filter(DropSupport.isMarkdown)
        guard !urls.isEmpty else { return false }
        FileOpener.open(urls)
        return true
    }

    // MARK: - DataSource

    private var displayRoot: SidebarNode? { searchRoot ?? rootNode }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? SidebarNode) ?? displayRoot
        guard let node else { return 0 }
        if node.children == nil { loadChildren(of: node); return 0 }
        return node.children!.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? SidebarNode) ?? displayRoot!
        return node.children![index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? SidebarNode else { return false }
        switch n.kind {
        case .folder: return true
        case .file: return n.isMarkdown && (n.children?.isEmpty == false || n.children == nil)
        case .heading: return !(n.children?.isEmpty ?? true)
        case .hit, .tag: return false
        case .section: return !(n.children?.isEmpty ?? true)
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
        cell.textField?.usesSingleLineMode = false
        cell.textField?.lineBreakMode = .byTruncatingTail
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
        case .section:
            cell.imageView?.image = NSImage(systemSymbolName: node.name == L("收藏") ? "star" : (node.name == L("最近") ? "clock" : "number"), accessibilityDescription: node.name)
            cell.imageView?.isHidden = false
            cell.imageView?.contentTintColor = .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.stringValue = node.name.uppercased()
        case .tag:
            cell.imageView?.image = nil
            cell.imageView?.isHidden = true
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = .labelColor
            cell.textField?.stringValue = "\(node.name)  ·  \(node.level)"
        case .hit:
            cell.imageView?.image = nil
            cell.imageView?.isHidden = true
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.usesSingleLineMode = true
            cell.textField?.cell?.wraps = false
            cell.textField?.cell?.truncatesLastVisibleLine = true
            cell.textField?.lineBreakMode = .byTruncatingTail
            let prefix = "\(node.line ?? 0)  "
            let s = NSMutableAttributedString(string: prefix, attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)])
            s.append(NSAttributedString(string: node.name, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11.5)]))
            if let r = node.hitRange, r.location + r.length <= (node.name as NSString).length {
                s.addAttributes([.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.35)], range: NSRange(location: r.location + (prefix as NSString).length, length: r.length))
            }
            cell.textField?.attributedStringValue = s
            cell.toolTip = node.name
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
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode, node.kind == .heading || node.kind == .hit else { return }
        activate(node)   // 键盘导航标题 / 命中行也跳转
    }

    // MARK: - 全局搜索（⌘⇧F）

    /// 显示搜索框并聚焦；空查询时树照旧
    func showSearch() {
        guard rootURL != nil else { NSSound.beep(); return }
        searchField.isHidden = false
        searchFieldHeight.constant = 24
        view.window?.makeFirstResponder(searchField)
        if !searchField.stringValue.isEmpty { searchField.selectText(nil) }
    }

    func hideSearch() {
        searchField.stringValue = ""
        searchField.isHidden = true
        searchFieldHeight.constant = 0
        clearSearch()
        view.window?.makeFirstResponder(outlineView)
    }

    @objc private func searchChanged(_ sender: Any?) {
        searchWork?.cancel()
        let q = searchField.stringValue
        guard !q.isEmpty else { clearSearch(); return }
        let w = DispatchWorkItem { [weak self] in self?.runSearch(q) }
        searchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func clearSearch() {
        activeSearch?.cancel(); activeSearch = nil
        guard searchRoot != nil else { return }
        searchRoot = nil
        outlineView.reloadData()
        revealCurrentFile()
    }

    private func runSearch(_ query: String) {
        guard let root = rootURL else { return }
        activeSearch?.cancel()
        let index = FileIndex.index(for: root)
        let files = index.relativePaths.map { index.url(for: $0) }
        let results = SidebarNode(kind: .folder, url: root, name: "", parent: nil)
        results.children = []
        searchRoot = results
        outlineView.reloadData()
        let search = ContentSearch()
        activeSearch = search
        let opts = ContentSearch.Options()
        let maxFiles = 500
        searchQueue.async { [weak self] in
            var batch: [ContentSearch.FileResult] = []
            var lastFlush = ProcessInfo.processInfo.systemUptime
            var total = 0
            func flush() {
                guard !batch.isEmpty else { return }
                let b = batch; batch = []
                DispatchQueue.main.async { [weak self] in self?.appendSearchResults(b, for: search) }
            }
            let summary = search.run(query: query, files: files, options: opts) { r in
                batch.append(r); total += 1
                if total >= maxFiles { search.cancel() }
                let now = ProcessInfo.processInfo.systemUptime
                if batch.count >= 20 || now - lastFlush > 0.05 { flush(); lastFlush = now }
            }
            flush()
            let truncatedIndex = index.truncated
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeSearch === search else { return }
                var notes: [String] = []
                if self.searchRoot?.children?.isEmpty ?? true { notes.append(L("没有找到")) }
                // 没搜到的和"有文件没搜"要分开说
                let skipped = summary.skippedTooLarge + summary.skippedUnreadable
                if skipped > 0 { notes.append(String(format: L("（%d 个文件过大或读不了，没有搜）"), skipped)) }
                if truncatedIndex { notes.append(String(format: L("（文件超过 %d 个，只搜了前面的）"), FileIndex.maxFiles)) }
                if total >= maxFiles { notes.append(String(format: L("（命中文件超过 %d 个，只显示前面的）"), maxFiles)) }
                if !notes.isEmpty {
                    self.searchRoot?.children?.append(contentsOf: notes.map { SidebarNode(kind: .hit, url: nil, name: $0, parent: self.searchRoot) })
                    self.outlineView.reloadData()
                }
            }
        }
    }

    private func appendSearchResults(_ batch: [ContentSearch.FileResult], for search: ContentSearch) {
        guard activeSearch === search, let root = searchRoot, let rootURL else { return }
        let prefix = rootURL.standardizedFileURL.path + "/"
        for r in batch {
            let path = r.url.standardizedFileURL.path
            let file = SidebarNode(kind: .file, url: r.url, name: path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : r.url.lastPathComponent, parent: root)
            file.children = r.hits.prefix(50).map { h in
                // 片段：命中前最多 12 个字符，前面截断加 …（侧栏窄，命中要看得见）
                let ns = h.text as NSString
                var start = max(0, h.range.lowerBound - 12)
                var text = ns.substring(from: start)
                var shift = start
                if start > 0 { text = "…" + text; shift = start - 1 }
                text = text.trimmingCharacters(in: .newlines)
                let n = SidebarNode(kind: .hit, url: r.url, name: text, parent: file)
                n.line = h.line
                n.hitRange = NSRange(location: h.range.lowerBound - shift, length: h.range.count)
                start = 0
                return n
            }
            root.children?.append(file)
        }
        outlineView.reloadData()
        for f in root.children ?? [] { outlineView.expandItem(f) }
    }
}

extension SidebarViewController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if searchField.stringValue.isEmpty { hideSearch() } else { searchField.stringValue = ""; clearSearch() }
            return true
        }
        if sel == #selector(NSResponder.moveDown(_:)) || sel == #selector(NSResponder.insertNewline(_:)) {
            // 进结果列表：选中第一个命中
            guard isSearching, outlineView.numberOfRows > 0 else { return false }
            view.window?.makeFirstResponder(outlineView)
            var row = 0
            while row < outlineView.numberOfRows, (outlineView.item(atRow: row) as? SidebarNode)?.kind != .hit { row += 1 }
            if row < outlineView.numberOfRows { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            return true
        }
        return false
    }
}


/// 侧栏用的 NSOutlineView：把回车 / 空格交给控制器（方向键、←→ 折叠展开保留系统行为）
final class SidebarOutlineView: NSOutlineView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onMenu: ((Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return onMenu?(row) ?? super.menu(for: event)
    }
}

extension SidebarViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self; panel.delegate = self }   // CI 的 Swift 6.1 把这两个方法当 nonisolated
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil; panel.delegate = nil }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { quickLookURL as NSURL? }
}
