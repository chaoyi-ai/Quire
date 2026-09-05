import AppKit
import Quartz
import QuireCore
import QuireRender

/// 文件树节点：文件夹 / 文件 / 搜索命中行 / 提示行。子节点懒加载。
@MainActor
final class SidebarNode {
    enum Kind { case folder, file, heading, hit, note }
    let kind: Kind
    let url: URL?
    var name: String              // 显示名（Markdown 文件不带扩展名）
    var level = 0                 // heading：级别
    var blockIndex: Int?          // heading（当前文档）：块下标
    var line: Int?                // hit / heading：行号
    var hitRange: NSRange?        // hit：命中在 name 里的范围
    var matchRange: NSRange?      // 筛选模式：名字里匹配的片段
    var children: [SidebarNode]?  // nil = 未加载
    var isLoading = false
    var onLoaded: [@MainActor @Sendable () -> Void] = []
    weak var parent: SidebarNode?

    init(kind: Kind, url: URL?, name: String, parent: SidebarNode?) {
        self.kind = kind; self.url = url; self.name = name; self.parent = parent
    }
    var isMarkdown: Bool {
        guard kind == .file, let ext = url?.pathExtension.lowercased() else { return false }
        return QuireDocumentController.markdownExtensions.contains(ext) || Preferences.shared.extraExtensionSet.contains(ext)
    }
}

/// 侧栏的偏好（只在侧栏内部用的键直接走 UserDefaults）
@MainActor
enum SidebarSettings {
    private static let d = UserDefaults.standard
    static var revealCurrent: Bool { get { d.object(forKey: "sidebar.revealCurrent") as? Bool ?? true } set { d.set(newValue, forKey: "sidebar.revealCurrent") } }
    static var showFavorites: Bool { get { d.object(forKey: "sidebar.showFavorites") as? Bool ?? true } set { d.set(newValue, forKey: "sidebar.showFavorites") } }
    static var showTags: Bool { get { d.object(forKey: "sidebar.showTags") as? Bool ?? true } set { d.set(newValue, forKey: "sidebar.showTags") } }
    static var outlineFlat: Bool { get { d.bool(forKey: "sidebar.outlineFlat") } set { d.set(newValue, forKey: "sidebar.outlineFlat") } }
    enum Sort: Int { case natural = 0, name = 1, modified = 2 }
    static var sort: Sort { get { Sort(rawValue: d.integer(forKey: "sidebar.sort")) ?? .natural } set { d.set(newValue.rawValue, forKey: "sidebar.sort") } }
    static func isCollapsed(_ section: String) -> Bool? { d.object(forKey: "sidebar.collapsed." + section) as? Bool }
    static func setCollapsed(_ section: String, _ v: Bool) { d.set(v, forKey: "sidebar.collapsed." + section) }
    /// 最近打开过的根目录（最多 8 个，最新在前）
    static var recentRoots: [URL] {
        get { (d.stringArray(forKey: "sidebar.recentRoots") ?? []).map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue.prefix(8).map(\.path), forKey: "sidebar.recentRoots") }
    }
    static func noteRoot(_ url: URL) {
        var r = recentRoots.filter { $0.standardizedFileURL.path != url.standardizedFileURL.path }
        r.insert(url, at: 0)
        recentRoots = r
    }
    static let didChange = Notification.Name("com.korako.quire.sidebarSettingsDidChange")
}

/// 「文件」段：根目录下的文件夹与 Markdown 文件。三种态：树 / 按名筛选（来自 FileIndex，全树匹配）/ 全文搜索结果。
/// 文件操作（新建 / 重命名 / 废纸篓）、Quick Look、拖放打开、键盘都在这里。
@MainActor
final class FileTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    let outlineView = SidebarRowStyle.makeOutlineView()
    private(set) lazy var scrollView = SidebarRowStyle.makeScrollView(outlineView)

    var root: URL? { didSet { if root?.standardizedFileURL != oldValue?.standardizedFileURL { rootDidChange() } } }
    var currentURL: URL? { didSet { if currentURL != oldValue { currentDidChange() } } }
    /// 打开文件（行号：搜索命中 / 其他文件的标题）
    var onOpenFile: ((URL, Int?) -> Void)?
    /// 当前文档的标题被点：跳转
    var onSelectHeading: ((Outline.Entry) -> Void)?
    /// 当前文档的大纲（解析结果）：挂在它的文件节点下面——文件树里能直接看到并跳转章节，这是 Quire 的特色
    var outline = Outline(entries: []) { didSet { if outline != oldValue { outlineDidChange() } } }
    private var headingCache: [URL: (mtime: Date, headings: [HeadingScanner.Heading])] = [:]
    nonisolated private static let maxScanBytes = 4 * 1024 * 1024
    /// 态变了（树 / 筛选 / 搜索、结果数）：容器刷新段头
    var onStateChange: (() -> Void)?

    enum Mode: Equatable { case tree, filter(String), search(String) }
    private(set) var mode: Mode = .tree
    /// 搜索 / 筛选结果里的文件数
    private(set) var resultCount = 0
    var searchNotes: [String] = []

    private var rootNode: SidebarNode?
    private var displayRoot: SidebarNode?     // 筛选 / 搜索态的临时树
    private var currentFileNode: SidebarNode?
    private var watcher: FolderWatcher?
    private var indexToken: ChangeObservers.Token?
    private var suppressSelection = false
    private var renamingNode: SidebarNode?
    private var pendingRename: URL?
    private var quickLookURL: URL?
    private var lastActivation: (ObjectIdentifier, TimeInterval)?
    private var activeSearch: ContentSearch?
    private let searchQueue = DispatchQueue(label: "com.korako.quire.search", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.korako.quire.sidebar.io", qos: .userInitiated)
    nonisolated private static let maxChildren = 5000

    private static let folderIcon = SidebarRowStyle.symbol("folder.fill", L("文件夹"))
    private static let fileIcon = SidebarRowStyle.symbol("doc.text", L("文档"))
    private static let otherIcon = SidebarRowStyle.symbol("doc", L("文件"))
    private static let headingIcon = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: L("标题"))?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))

    override init() {
        super.init()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.onKeyDown = { [weak self] e in self?.keyDown(e) ?? false }
        outlineView.onMenu = { [weak self] row in self?.menu(forRow: row) }
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)     // 树内拖 = 移动
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)    // 拖到 Finder / 别的 App = 复制
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))
        outlineView.setAccessibilityLabel(L("文件"))
    }

    // MARK: - 根 / 当前文件

    private func rootDidChange() {
        activeSearch?.cancel(); activeSearch = nil
        displayRoot = nil; mode = .tree
        currentFileNode = nil
        guard let root else { rootNode = nil; watcher = nil; outlineView.reloadData(); onStateChange?(); return }
        rootNode = SidebarNode(kind: .folder, url: root, name: root.lastPathComponent, parent: nil)
        outlineView.reloadData()
        loadChildren(of: rootNode!) { [weak self] in self?.revealCurrent() }
        watcher = FolderWatcher(url: root) { [weak self] dirs in
            Task { @MainActor [weak self] in
                self?.foldersDidChange(dirs)
                if let r = self?.root { FileIndex.index(for: r).directoriesChanged() }   // 快速打开索引共用这一条 FSEvents 流
            }
        }
        let index = FileIndex.index(for: root)   // 预热：打开文件夹时就开始后台扫（筛选 / 搜索 / wikilink 都用它）
        indexToken = index.observers.add { [weak self] in
            guard let self, case .filter(let q) = self.mode else { return }
            self.applyFilter(q)   // 索引扫完：筛选结果补全
        }
        onStateChange?()
    }

    private func currentDidChange() {
        guard mode == .tree else { return }
        if SidebarSettings.revealCurrent { revealCurrent() } else { updateCurrentHighlight() }
    }

    /// 展开到当前文档并选中它
    func revealCurrent() {
        guard let rootNode, let cur = currentURL?.standardizedFileURL, let rootPath = root?.standardizedFileURL.path,
              cur.path.hasPrefix(rootPath + "/") else { updateCurrentHighlight(); return }
        let rel = String(cur.path.dropFirst(rootPath.count + 1)).split(separator: "/").map(String.init)
        descend(node: rootNode, components: rel[...])
    }

    private func descend(node: SidebarNode, components: ArraySlice<String>) {
        guard let name = components.first else { return }
        let rest = components.dropFirst()
        func proceed() {
            guard let child = node.children?.first(where: { $0.url?.lastPathComponent == name }) else { return }
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
        guard row >= 0 else { return }
        suppressSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        suppressSelection = false
    }

    private func outlineDidChange() {
        guard let node = currentFileNode else { return }
        applyOutline(to: node)
        outlineView.reloadItem(node, reloadChildren: true)
        outlineView.expandItem(node, expandChildren: true)
        if let b = lastBlockIndex { highlight(blockIndex: b) }
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

    /// 阅读视图当前章节 → 高亮当前文档树下对应的标题
    private var lastBlockIndex: Int?
    func highlight(blockIndex: Int) {
        lastBlockIndex = blockIndex
        guard mode == .tree, let file = currentFileNode, let children = file.children, !children.isEmpty else { return }
        var flat: [SidebarNode] = []
        func walk(_ n: SidebarNode) { for c in n.children ?? [] { flat.append(c); walk(c) } }
        walk(file)
        var target: SidebarNode?
        for n in flat { if let b = n.blockIndex, b <= blockIndex { target = n } else if n.blockIndex != nil { break } }
        guard let target else { return }
        var p = target.parent
        while let x = p, x.kind == .heading { if !outlineView.isItemExpanded(x) { outlineView.expandItem(x) }; p = x.parent }
        let row = outlineView.row(forItem: target)
        guard row >= 0, outlineView.selectedRow != row else { return }
        suppressSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        suppressSelection = false
    }

    private func fileNode(of heading: SidebarNode) -> SidebarNode? {
        var n: SidebarNode? = heading
        while let cur = n, cur.kind == .heading { n = cur.parent }
        return n
    }

    /// 不展开、不滚动：只把选中态对到当前文件（它在视图里的话）
    private func updateCurrentHighlight() {
        guard mode == .tree, let rootNode else { return }
        let cur = currentURL?.standardizedFileURL.path
        func find(_ n: SidebarNode) -> SidebarNode? {
            for c in n.children ?? [] {
                if c.kind == .file, c.url?.standardizedFileURL.path == cur { return c }
                if c.kind == .folder, let f = find(c) { return f }
            }
            return nil
        }
        if let cur, let n = find(rootNode) { setCurrentFileNode(n) } else { currentFileNode = nil; if outlineView.selectedRow >= 0 { suppressSelection = true; outlineView.deselectAll(nil); suppressSelection = false } }
    }

    // MARK: - 懒加载 / 目录

    private func loadChildren(of node: SidebarNode, completion: (@MainActor @Sendable () -> Void)? = nil) {
        if let completion { node.onLoaded.append(completion) }
        guard !node.isLoading else { return }
        if node.kind == .file, node.isMarkdown, mode == .tree, let url = node.url {
            // 其他文件展开：快速扫标题（当前文档用解析结果，见 applyOutline）
            node.isLoading = true
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
                    if node !== self.currentFileNode { node.children = self.buildHeadingTree(fileNode: node, entries: headings.map { ($0.level, $0.title, $0.line, nil) }) }
                    self.outlineView.reloadItem(node, reloadChildren: true)
                    self.fireLoaded(node)
                }
            }
            return
        }
        guard node.kind == .folder, let url = node.url else { node.children = node.children ?? []; node.isLoading = false; fireLoaded(node); return }
        node.isLoading = true
        let rules = Preferences.shared.sidebarRules
        let sort = SidebarSettings.sort
        ioQueue.async {
            let entries = Self.listFolder(url, rules: rules, sort: sort)
            Task { @MainActor [weak self] in
                guard let self else { return }
                node.isLoading = false
                self.mergeChildren(node, entries: entries)
                if node === self.rootNode { self.outlineView.reloadData() } else { self.outlineView.reloadItem(node, reloadChildren: true) }
                self.fireLoaded(node)
            }
        }
    }

    private func fireLoaded(_ node: SidebarNode) {
        let cbs = node.onLoaded; node.onLoaded = []
        DispatchQueue.main.async { cbs.forEach { $0() } }   // 下一轮：让 reload 后的行先建立
    }

    /// 目录列表（后台）：文件夹优先；只列 Markdown 文件与文件夹（或按规则列其他文件）
    nonisolated static func listFolder(_ url: URL, rules: Preferences.SidebarRules, sort: SidebarSettings.Sort) -> [(URL, Bool, Date)] {
        let fm = FileManager.default
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !rules.showHidden { opts.insert(.skipsHiddenFiles) }
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey], options: opts) else { return [] }
        var folders: [(URL, Bool, Date)] = [], files: [(URL, Bool, Date)] = []
        for u in items {
            guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]) else { continue }
            let ext = u.pathExtension.lowercased()
            let m = v.contentModificationDate ?? .distantPast
            if v.isDirectory == true, v.isPackage != true { folders.append((u, true, m)) }
            else if QuireDocumentController.markdownExtensions.contains(ext) || rules.extraExtensions.contains(ext) || rules.showOthers { files.append((u, false, m)) }
        }
        let cmp: ((URL, Bool, Date), (URL, Bool, Date)) -> Bool
        switch sort {
        case .natural: cmp = { $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending }
        case .name: cmp = { $0.0.lastPathComponent.localizedCaseInsensitiveCompare($1.0.lastPathComponent) == .orderedAscending }
        case .modified: cmp = { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending }
        }
        folders.sort(by: cmp); files.sort(by: cmp)
        var out = folders + files
        if out.count > maxChildren { out = Array(out.prefix(maxChildren)) }
        return out
    }

    /// 合并新列表到已有子节点（按 URL 复用旧节点，保持展开状态与已加载的子树）；显示名去掉扩展名（同名不同扩展时保留）
    private func mergeChildren(_ node: SidebarNode, entries: [(URL, Bool, Date)]) {
        var existing: [String: SidebarNode] = [:]
        for c in node.children ?? [] { if let u = c.url { existing[u.standardizedFileURL.path] = c } }
        var stems: [String: Int] = [:]
        for (u, isDir, _) in entries where !isDir { stems[u.deletingPathExtension().lastPathComponent, default: 0] += 1 }
        node.children = entries.map { url, isDir, _ -> SidebarNode in
            let name = isDir ? url.lastPathComponent : Self.displayName(url, ambiguous: (stems[url.deletingPathExtension().lastPathComponent] ?? 0) > 1)
            if let old = existing[url.standardizedFileURL.path] { old.name = name; return old }
            return SidebarNode(kind: isDir ? .folder : .file, url: url, name: name, parent: node)
        }
    }

    nonisolated static func displayName(_ url: URL, ambiguous: Bool) -> String {
        let ext = url.pathExtension.lowercased()
        if !ambiguous, QuireDocumentController.markdownExtensions.contains(ext) { return url.deletingPathExtension().lastPathComponent }
        return url.lastPathComponent
    }

    /// 规则 / 排序变了：重列已加载的文件夹（保持展开状态）
    func reloadTree() {
        guard let root = rootNode else { return }
        func walk(_ n: SidebarNode) {
            if n.kind == .folder, n.children != nil { loadChildren(of: n) }
            for c in n.children ?? [] where c.kind == .folder { walk(c) }
        }
        walk(root)
    }

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
            loadChildren(of: node) { [weak self] in
                guard let self else { return }
                if let pending = self.pendingRename, let n = node.children?.first(where: { $0.url?.standardizedFileURL == pending.standardizedFileURL }) {
                    self.pendingRename = nil
                    self.beginRename(n)
                }
                self.updateCurrentHighlight()
            }
        }
    }

    private func findFolderNode(path: String, from node: SidebarNode) -> SidebarNode? {
        guard let np = node.url?.standardizedFileURL.path else { return nil }
        if np == path { return node }
        guard path.hasPrefix(np + "/"), let children = node.children else { return nil }
        for c in children where c.kind == .folder { if let f = findFolderNode(path: path, from: c) { return f } }
        return nil
    }

    func collapseAll() {
        guard mode == .tree, let rootNode else { return }
        for c in rootNode.children ?? [] where c.kind == .folder || c.kind == .file { outlineView.collapseItem(c, collapseChildren: true) }
        updateCurrentHighlight()
    }

    // MARK: - 筛选（按名字，来自 FileIndex，整棵树）

    func applyFilter(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { clearToTree(); return }
        guard let root else { return }
        activeSearch?.cancel(); activeSearch = nil; searchNotes = []
        mode = .filter(q)
        let index = FileIndex.index(for: root)
        let lower = q.lowercased()
        let matches = index.relativePaths.filter { ($0 as NSString).lastPathComponent.lowercased().contains(lower) }
        let tree = SidebarNode(kind: .folder, url: root, name: "", parent: nil)
        tree.children = []
        var folders: [String: SidebarNode] = ["": tree]
        func folder(_ rel: String) -> SidebarNode {
            if let f = folders[rel] { return f }
            let parentRel = (rel as NSString).deletingLastPathComponent
            let p = folder(parentRel)
            let n = SidebarNode(kind: .folder, url: root.appendingPathComponent(rel, isDirectory: true), name: (rel as NSString).lastPathComponent, parent: p)
            n.children = []
            p.children!.append(n)
            folders[rel] = n
            return n
        }
        for rel in matches.prefix(2000) {
            let p = folder((rel as NSString).deletingLastPathComponent)
            let url = index.url(for: rel)
            let n = SidebarNode(kind: .file, url: url, name: Self.displayName(url, ambiguous: false), parent: p)
            n.children = []   // 筛选态不挂大纲
            let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            if let r = n.name.range(of: q, options: opts) { n.matchRange = NSRange(r, in: n.name) }
            p.children!.append(n)
        }
        if matches.isEmpty { tree.children = [SidebarNode(kind: .note, url: nil, name: index.isScanning ? L("正在建立索引…") : L("没有匹配的文件"), parent: tree)] }
        resultCount = matches.count
        displayRoot = tree
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        onStateChange?()
    }

    /// 回到树（清筛选 / 搜索）
    func clearToTree() {
        activeSearch?.cancel(); activeSearch = nil
        searchNotes = []
        guard mode != .tree else { return }
        mode = .tree
        displayRoot = nil
        resultCount = 0
        outlineView.reloadData()
        revealCurrent()
        onStateChange?()
    }

    // MARK: - 全文搜索

    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let root else { clearToTree(); return }
        activeSearch?.cancel()
        mode = .search(q)
        searchNotes = []
        let index = FileIndex.index(for: root)
        let files = index.relativePaths.map { index.url(for: $0) }
        let results = SidebarNode(kind: .folder, url: root, name: "", parent: nil)
        results.children = []
        displayRoot = results
        resultCount = 0
        outlineView.reloadData()
        onStateChange?()
        let search = ContentSearch()
        activeSearch = search
        let opts = ContentSearch.Options()
        let maxFiles = 500
        let truncatedIndex = index.truncated
        searchQueue.async { [weak self] in
            var batch: [ContentSearch.FileResult] = []
            var lastFlush = ProcessInfo.processInfo.systemUptime
            var total = 0
            func flush() {
                guard !batch.isEmpty else { return }
                let b = batch; batch = []
                DispatchQueue.main.async { [weak self] in self?.appendSearchResults(b, for: search) }
            }
            let summary = search.run(query: q, files: files, options: opts) { r in
                batch.append(r); total += 1
                if total >= maxFiles { search.cancel() }
                let now = ProcessInfo.processInfo.systemUptime
                if batch.count >= 20 || now - lastFlush > 0.05 { flush(); lastFlush = now }
            }
            flush()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeSearch === search, let results = self.displayRoot else { return }
                var notes: [String] = []
                if results.children?.isEmpty ?? true { notes.append(L("没有找到")) }
                let skipped = summary.skippedTooLarge + summary.skippedUnreadable
                if skipped > 0 { notes.append(String(format: L("（%d 个文件过大或读不了，没有搜）"), skipped)) }
                if truncatedIndex { notes.append(String(format: L("（文件超过 %d 个，只搜了前面的）"), FileIndex.maxFiles)) }
                if total >= maxFiles { notes.append(String(format: L("（命中文件超过 %d 个，只显示前面的）"), maxFiles)) }
                if !notes.isEmpty {
                    results.children?.append(contentsOf: notes.map { SidebarNode(kind: .note, url: nil, name: $0, parent: results) })
                    self.outlineView.reloadData()
                    for f in results.children ?? [] where f.kind == .file { self.outlineView.expandItem(f) }
                }
                self.searchNotes = notes
                self.onStateChange?()
            }
        }
    }

    private func appendSearchResults(_ batch: [ContentSearch.FileResult], for search: ContentSearch) {
        guard activeSearch === search, let results = displayRoot, let root else { return }
        let prefix = root.standardizedFileURL.path + "/"
        for r in batch {
            let path = r.url.standardizedFileURL.path
            let file = SidebarNode(kind: .file, url: r.url, name: path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : r.url.lastPathComponent, parent: results)
            file.children = r.hits.prefix(50).map { h in
                // 片段：命中前最多 12 个字符，前面截断加 …（侧栏窄，命中要看得见）
                let ns = h.text as NSString
                let start = max(0, h.range.lowerBound - 12)
                var text = ns.substring(from: start)
                var shift = start
                if start > 0 { text = "…" + text; shift = start - 1 }
                text = text.trimmingCharacters(in: .newlines)
                let n = SidebarNode(kind: .hit, url: r.url, name: text, parent: file)
                n.line = h.line
                n.hitRange = NSRange(location: h.range.lowerBound - shift, length: h.range.count)
                return n
            }
            results.children?.append(file)
        }
        resultCount = (results.children ?? []).filter { $0.kind == .file }.count
        outlineView.reloadData()
        for f in results.children ?? [] { outlineView.expandItem(f) }
        onStateChange?()
    }

    /// 键盘从筛选框进入列表：选中第一个可打开的行
    func focusFirstResult() {
        guard outlineView.numberOfRows > 0 else { return }
        outlineView.window?.makeFirstResponder(outlineView)
        var row = 0
        while row < outlineView.numberOfRows, let n = outlineView.item(atRow: row) as? SidebarNode, n.kind == .folder || n.kind == .note { row += 1 }
        if row < outlineView.numberOfRows { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    // MARK: - 文件操作

    /// 选中的文件夹（没有就是选中文件所在文件夹，再没有就是根）
    private var targetFolder: URL? {
        if let n = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode {
            if n.kind == .folder, let u = n.url { return u }
            if n.kind == .file, let u = n.url { return u.deletingLastPathComponent() }
        }
        return root
    }

    func newFile() {
        guard mode == .tree, let dir = targetFolder else { NSSound.beep(); return }
        let url = Self.uniqueURL(in: dir, base: L("未命名"), ext: "md")
        do { try Data().write(to: url) } catch { NSApp.presentError(error); return }
        pendingRename = url   // 目录变化重列后进入重命名
        onOpenFile?(url, nil)
    }

    func newFolder() {
        guard mode == .tree, let dir = targetFolder else { NSSound.beep(); return }
        let url = Self.uniqueURL(in: dir, base: L("未命名文件夹"), ext: nil)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) } catch { NSApp.presentError(error); return }
        pendingRename = url
    }

    nonisolated static func uniqueURL(in dir: URL, base: String, ext: String?) -> URL {
        let fm = FileManager.default
        for i in 0..<1000 {
            let name = (i == 0 ? base : "\(base) \(i + 1)") + (ext.map { "." + $0 } ?? "")
            let u = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: u.path) { return u }
        }
        return dir.appendingPathComponent(base + "-" + UUID().uuidString + (ext.map { "." + $0 } ?? ""))
    }

    func beginRename(_ node: SidebarNode) {
        guard node.kind == .file || node.kind == .folder, mode == .tree else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        renamingNode = node
        outlineView.reloadItem(node)
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        outlineView.editColumn(0, row: row, with: nil, select: true)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool {
        (item as? SidebarNode) === renamingNode
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let node = renamingNode, let url = node.url, let field = obj.object as? NSTextField else { return }
        renamingNode = nil
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        defer { outlineView.reloadItem(node) }
        guard !typed.isEmpty, !typed.contains("/") else { return }
        // Markdown 文件显示时不带扩展名：用户没打扩展名就补回原来的
        var newName = typed
        if node.kind == .file, (typed as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { newName += "." + url.pathExtension }
        guard newName != url.lastPathComponent else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            let a = NSAlert(); a.messageText = String(format: L("已经有一个叫「%@」的项目"), newName); a.runModal(); return
        }
        do { try FileManager.default.moveItem(at: url, to: dest) } catch { NSApp.presentError(error); return }
        Self.documentsMoved(from: url, to: dest)
        Favorites.replace(url, with: dest)
    }

    /// 把文件 / 文件夹移到 dir（拖拽 / 菜单）。同名冲突跳过并提示；打开着的文档与收藏跟着走；树由目录监听重列
    @discardableResult
    func move(_ urls: [URL], to dir: URL) -> Bool {
        var moved = false
        for u in urls {
            let dest = dir.appendingPathComponent(u.lastPathComponent)
            guard dest.standardizedFileURL != u.standardizedFileURL else { continue }
            if FileManager.default.fileExists(atPath: dest.path) {
                let a = NSAlert(); a.messageText = String(format: L("已经有一个叫「%@」的项目"), u.lastPathComponent); a.runModal(); continue
            }
            do { try FileManager.default.moveItem(at: u, to: dest) } catch { NSApp.presentError(error); continue }
            Self.documentsMoved(from: u, to: dest)
            Favorites.replace(u, with: dest)
            moved = true
        }
        return moved
    }

    /// 打开着的文档跟着改名 / 移动（NSDocument 允许直接改 fileURL）
    nonisolated static func documentsMoved(from: URL, to: URL) {
        Task { @MainActor in
            let fromPath = from.standardizedFileURL.path
            for doc in NSDocumentController.shared.documents {
                guard let p = doc.fileURL?.standardizedFileURL.path else { continue }
                if p == fromPath { doc.fileURL = to }
                else if p.hasPrefix(fromPath + "/") { doc.fileURL = to.appendingPathComponent(String(p.dropFirst(fromPath.count + 1))) }
            }
        }
    }

    func trash(_ node: SidebarNode) {
        guard let url = node.url, mode == .tree else { return }
        if let doc = NSDocumentController.shared.document(for: url) {
            if doc.isDocumentEdited {
                let a = NSAlert(); a.messageText = String(format: L("「%@」有未存储的改动"), node.name); a.informativeText = L("先存储或关闭它，再移到废纸篓。"); a.runModal(); return
            }
            doc.close()
        }
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { NSApp.presentError(error); return }
        Favorites.remove(url)
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

    private func activate(_ node: SidebarNode) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastActivation, last.0 == ObjectIdentifier(node), now - last.1 < 0.1 { return }   // action 与 selectionDidChange 会连着来
        lastActivation = (ObjectIdentifier(node), now)
        switch node.kind {
        case .hit: if let url = node.parent?.url { onOpenFile?(url, node.line) }
        case .heading:
            if let file = fileNode(of: node), file === currentFileNode, let bi = node.blockIndex {
                onSelectHeading?(Outline.Entry(id: "", level: node.level, title: node.name, blockIndex: bi, line: node.line))
            } else if let url = node.url { onOpenFile?(url, node.line) }
        case .file:
            guard let url = node.url else { return }
            if !node.isMarkdown { NSWorkspace.shared.open(url); return }   // 非 Markdown：交给默认 App
            if url.standardizedFileURL != currentURL?.standardizedFileURL { onOpenFile?(url, nil) }
        case .folder, .note: break
        }
    }

    private func keyDown(_ event: NSEvent) -> Bool {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76:   // Return / Enter
            if node.kind == .folder { outlineView.isItemExpanded(node) ? outlineView.collapseItem(node) : outlineView.expandItem(node) } else { activate(node) }
            return true
        case 49:       // Space → Quick Look
            guard node.kind == .file || node.kind == .folder, let url = node.url else { return false }
            quickLookURL = url
            if let panel = QLPreviewPanel.shared() { if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) } }
            return true
        case 51 where mods == .command:   // ⌘⌫ → 废纸篓
            if node.kind == .file || node.kind == .folder { trash(node) }
            return true
        default: return false
        }
    }

    func menu(forRow row: Int) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, _ obj: Any? = nil, key: String = "") { let it = NSMenuItem(title: title, action: sel, keyEquivalent: key); it.target = self; it.representedObject = obj; menu.addItem(it) }
        let node = row >= 0 ? outlineView.item(atRow: row) as? SidebarNode : nil
        guard mode == .tree else {
            if let n = node, n.kind == .file || n.kind == .hit, let u = n.url ?? n.parent?.url { add(L("在 Finder 中显示"), #selector(revealItem(_:)), u) }
            return menu.items.isEmpty ? nil : menu
        }
        switch node?.kind {
        case .heading:
            if let u = node?.url { add(L("在 Finder 中显示"), #selector(revealItem(_:)), u) }
        case .file:
            let url = node!.url!
            add(L("打开"), #selector(openItem(_:)), node)
            add(L("在 Finder 中显示"), #selector(revealItem(_:)), url)
            add(L("复制路径"), #selector(copyPath(_:)), url)
            menu.addItem(.separator())
            add(Favorites.contains(url) ? L("从收藏移除") : L("加入收藏"), #selector(toggleFavorite(_:)), url)
            menu.addItem(.separator())
            add(L("重命名"), #selector(renameItem(_:)), node)
            add(L("移到废纸篓"), #selector(trashItem(_:)), node)
        case .folder:
            let url = node!.url!
            add(L("新建文件"), #selector(newFileHere(_:)), url)
            add(L("新建文件夹"), #selector(newFolderHere(_:)), url)
            menu.addItem(.separator())
            add(L("在 Finder 中显示"), #selector(revealItem(_:)), url)
            add(L("复制路径"), #selector(copyPath(_:)), url)
            menu.addItem(.separator())
            add(L("重命名"), #selector(renameItem(_:)), node)
            add(L("移到废纸篓"), #selector(trashItem(_:)), node)
        default:
            guard let root else { return nil }
            add(L("新建文件"), #selector(newFileHere(_:)), root)
            add(L("新建文件夹"), #selector(newFolderHere(_:)), root)
            menu.addItem(.separator())
            add(L("在 Finder 中显示"), #selector(revealItem(_:)), root)
        }
        return menu
    }
    @objc private func openItem(_ s: NSMenuItem) { if let n = s.representedObject as? SidebarNode { lastActivation = nil; activate(n) } }
    @objc private func revealItem(_ s: NSMenuItem) { if let u = s.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc private func copyPath(_ s: NSMenuItem) { if let u = s.representedObject as? URL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.path, forType: .string) } }
    @objc private func toggleFavorite(_ s: NSMenuItem) { if let u = s.representedObject as? URL { Favorites.toggle(u) } }
    @objc private func renameItem(_ s: NSMenuItem) { if let n = s.representedObject as? SidebarNode { beginRename(n) } }
    @objc private func trashItem(_ s: NSMenuItem) { if let n = s.representedObject as? SidebarNode { trash(n) } }
    @objc private func newFileHere(_ s: NSMenuItem) {
        guard let dir = s.representedObject as? URL else { return }
        if let n = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode, n.url != dir { outlineView.deselectAll(nil) }
        selectFolder(dir); newFile()
    }
    @objc private func newFolderHere(_ s: NSMenuItem) {
        guard let dir = s.representedObject as? URL else { return }
        selectFolder(dir); newFolder()
    }
    private func selectFolder(_ dir: URL) {
        guard let rootNode, dir.standardizedFileURL != root?.standardizedFileURL, let n = findFolderNode(path: dir.standardizedFileURL.path, from: rootNode) else { outlineView.deselectAll(nil); return }
        outlineView.expandItem(n)
        let row = outlineView.row(forItem: n)
        if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    // MARK: - 拖放（树内拖 = 移动；外来 Markdown 文件 = 打开 / 文件夹 = 设为根）

    var onDropFolder: ((URL) -> Void)?
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard mode == .tree, let n = item as? SidebarNode, n.kind == .file || n.kind == .folder, let u = n.url else { return nil }
        return u as NSURL
    }

    private func isInternalDrag(_ info: NSDraggingInfo) -> Bool { (info.draggingSource as? NSOutlineView) === outlineView }

    /// 树内拖动的目标文件夹：落在文件夹上 = 该文件夹；落在文件上 = 它所在文件夹；落在空白处 = 根
    private func dropFolder(for item: Any?) -> (node: SidebarNode?, url: URL)? {
        guard let root else { return nil }
        guard let n = item as? SidebarNode else { return (nil, root) }
        switch n.kind {
        case .folder: return n.url.map { (n, $0) }
        case .file: if let u = n.url { return (n.parent?.kind == .folder ? n.parent : nil, u.deletingLastPathComponent()) }; return nil
        default: return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let urls = DropSupport.fileURLs(from: info)
        if isInternalDrag(info) {
            guard let (node, dir) = dropFolder(for: item) else { return [] }
            let dirPath = dir.standardizedFileURL.path
            // 不能移到原地、移进自己或自己的子目录
            for u in urls {
                let p = u.standardizedFileURL.path
                if u.deletingLastPathComponent().standardizedFileURL.path == dirPath || dirPath == p || dirPath.hasPrefix(p + "/") { return [] }
            }
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        guard urls.contains(where: { DropSupport.isMarkdown($0) || DropSupport.isDirectory($0) }) else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let all = DropSupport.fileURLs(from: info)
        if isInternalDrag(info) {
            guard let (_, dir) = dropFolder(for: item) else { return false }
            return move(all, to: dir)
        }
        if let dir = all.first(where: DropSupport.isDirectory) { onDropFolder?(dir) }
        let urls = all.filter(DropSupport.isMarkdown)
        guard !urls.isEmpty else { return false }
        FileOpener.open(urls)
        return true
    }

    // MARK: - DataSource / Delegate

    private var shownRoot: SidebarNode? { displayRoot ?? rootNode }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? SidebarNode) ?? shownRoot else { return 0 }
        if node.children == nil { loadChildren(of: node); return 0 }
        return node.children!.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? SidebarNode) ?? shownRoot!).children![index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? SidebarNode else { return false }
        switch n.kind {
        case .folder: return true
        case .file: return n.children == nil ? (n.isMarkdown && mode == .tree) : !(n.children!.isEmpty)   // 树：大纲；搜索态：命中行
        case .heading: return !(n.children?.isEmpty ?? true)
        case .hit, .note: return false
        }
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { (item as? SidebarNode)?.kind == .heading ? SidebarRowStyle.outlineRowHeight : SidebarRowStyle.rowHeight }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = SidebarRowStyle.cell(in: outlineView)
        let tf = cell.textField!
        tf.delegate = self
        tf.isEditable = node === renamingNode
        tf.font = SidebarRowStyle.font
        tf.textColor = .labelColor
        tf.toolTip = node.url?.path
        cell.imageView?.isHidden = false
        cell.imageView?.contentTintColor = .secondaryLabelColor
        switch node.kind {
        case .folder:
            cell.imageView?.image = Self.folderIcon
            cell.imageView?.contentTintColor = .controlAccentColor
            tf.stringValue = node.name
        case .file:
            cell.imageView?.image = node.isMarkdown ? Self.fileIcon : Self.otherIcon
            if node === renamingNode, let u = node.url { tf.stringValue = QuireDocumentController.markdownExtensions.contains(u.pathExtension.lowercased()) ? u.deletingPathExtension().lastPathComponent : u.lastPathComponent }
            else if let r = node.matchRange {
                let s = NSMutableAttributedString(string: node.name, attributes: [.font: SidebarRowStyle.font, .foregroundColor: NSColor.labelColor])
                s.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold), range: r)
                tf.attributedStringValue = s
            } else { tf.stringValue = node.name }
        case .heading:
            // 标题行：小段落图标 + 稍小的字，和文件行分得开；H1 用 medium
            cell.imageView?.image = Self.headingIcon
            cell.imageView?.contentTintColor = .secondaryLabelColor
            tf.stringValue = node.name
            tf.font = node.level <= 1 ? .systemFont(ofSize: 12.5, weight: .medium) : .systemFont(ofSize: 12.5)
            tf.textColor = node.level >= 4 ? .secondaryLabelColor : .labelColor
            tf.toolTip = node.name
        case .note:
            cell.imageView?.isHidden = true
            tf.stringValue = node.name
            tf.textColor = .tertiaryLabelColor
            tf.font = .systemFont(ofSize: 12)
        case .hit:
            cell.imageView?.isHidden = true
            let prefix = "\(node.line ?? 0)  "
            let s = NSMutableAttributedString(string: prefix, attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)])
            s.append(NSAttributedString(string: node.name, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
            if let r = node.hitRange, r.location + r.length <= (node.name as NSString).length {
                s.addAttributes([.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.35)], range: NSRange(location: r.location + (prefix as NSString).length, length: r.length))
            }
            tf.attributedStringValue = s
            tf.toolTip = node.name
        }
        return cell
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        if node.children == nil { loadChildren(of: node) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode, node.kind == .hit || node.kind == .heading else { return }
        activate(node)   // 键盘走到标题 / 命中行也跳转
    }
}

extension FileTreeController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { quickLookURL as NSURL? }
}
