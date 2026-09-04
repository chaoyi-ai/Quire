import AppKit
import Quartz
import QuireCore
import QuireRender

/// 侧栏容器：位置栏 + 筛选框 + 上下堆叠的分段（文件 / 大纲 可拖分隔；收藏 / 标签 在底部默认折叠）。
/// 设计见 docs/research/sidebar.md：树是树、大纲是大纲；默认安静；以当前文档为中心；动作就在手边。
@MainActor
final class SidebarViewController: NSViewController, NSSearchFieldDelegate, NSMenuDelegate {
    // 输入
    var currentURL: URL? { didSet { if currentURL != oldValue { currentURLDidChange() } } }
    var outline: Outline = Outline(entries: []) { didSet { if outline != oldValue { outlineDidChange() } } }
    // 输出
    var onSelectHeading: ((Outline.Entry) -> Void)?
    var onOpenFile: ((URL, Int?) -> Void)?
    private(set) var rootURL: URL? { didSet { if rootURL?.standardizedFileURL != oldValue?.standardizedFileURL { rootDidChange() } } }

    let files = FileTreeController()
    let favorites = FavoritesController()
    let tags = TagsController()

    private var locationButton: NSPopUpButton!
    private var filterField: NSSearchField!
    private var filesSection: SidebarSectionView!
    private var favoritesSection: SidebarSectionView!
    private var tagsSection: SidebarSectionView!
    private var favoritesHeight: NSLayoutConstraint!
    private var tagsHeight: NSLayoutConstraint!
    private var emptyLabel: NSTextField!
    private var filterWork: DispatchWorkItem?
    nonisolated(unsafe) private var prefsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?
    private var lastRules: Preferences.SidebarRules?

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        // 位置栏：根目录名 + 下拉菜单
        locationButton = NSPopUpButton(frame: .zero, pullsDown: true)
        locationButton.isBordered = false
        locationButton.font = .systemFont(ofSize: 13, weight: .semibold)
        locationButton.translatesAutoresizingMaskIntoConstraints = false
        locationButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationButton.menu?.delegate = self
        (locationButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        locationButton.setAccessibilityLabel(L("根目录"))
        rebuildLocationMenu()

        // 筛选 / 搜索
        filterField = NSSearchField()
        filterField.placeholderString = L("筛选或搜索…")
        filterField.controlSize = .small
        filterField.font = .systemFont(ofSize: 12)
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.sendsSearchStringImmediately = true
        filterField.sendsWholeSearchString = false
        filterField.delegate = self
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.toolTip = L("打字按名字筛选文件，回车搜索全文（⌥⌘F）")

        // 分段
        filesSection = SidebarSectionView(title: L("文件"))
        filesSection.setContentView(files.scrollView)
        filesSection.setActions([
            .init(symbol: "plus", tooltip: L("新建文件")) { [weak self] in self?.files.newFile() },
            .init(symbol: "arrow.down.right.and.arrow.up.left", tooltip: L("折叠全部")) { [weak self] in self?.files.collapseAll() },
            .init(symbol: "scope", tooltip: L("定位当前文件 ⌘⇧J")) { [weak self] in self?.revealCurrent() },
        ])
        favoritesSection = SidebarSectionView(title: L("收藏"))
        favoritesSection.setContentView(favorites.scrollView)
        tagsSection = SidebarSectionView(title: L("标签"))
        tagsSection.setContentView(tags.scrollView)

        let bottom = NSStackView(views: [favoritesSection, tagsSection])
        bottom.orientation = .vertical
        bottom.spacing = 0
        bottom.alignment = .leading
        bottom.translatesAutoresizingMaskIntoConstraints = false
        favoritesHeight = favoritesSection.heightAnchor.constraint(equalToConstant: SidebarSectionView.headerHeight)
        tagsHeight = tagsSection.heightAnchor.constraint(equalToConstant: SidebarSectionView.headerHeight)

        let separator = NSBox(); separator.boxType = .separator; separator.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(wrappingLabelWithString: L("打开一个文件夹，或存储文档后在这里看到它所在的文件夹"))
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(locationButton); container.addSubview(filterField); container.addSubview(filesSection)
        container.addSubview(separator); container.addSubview(bottom); container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            locationButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            locationButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            locationButton.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            locationButton.heightAnchor.constraint(equalToConstant: 24),
            filterField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            filterField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            filterField.topAnchor.constraint(equalTo: locationButton.bottomAnchor, constant: 4),
            filesSection.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 6),
            filesSection.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filesSection.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: filesSection.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: separator.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            favoritesSection.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            tagsSection.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            favoritesHeight, tagsHeight,
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        view = container
        wire()
    }

    private func wire() {
        files.onOpenFile = { [weak self] url, line in self?.onOpenFile?(url, line) }
        files.onDropFolder = { [weak self] dir in self?.setRoot(dir) }
        files.onStateChange = { [weak self] in self?.updateFilesHeader() }
        files.onSelectHeading = { [weak self] e in self?.onSelectHeading?(e) }
        favorites.onOpenFile = { [weak self] url in self?.onOpenFile?(url, nil) }
        favorites.onChange = { [weak self] in self?.updateBottomSections() }
        tags.onSearchTag = { [weak self] tag in
            guard let self else { return }
            self.filterField.stringValue = tag
            self.files.search(tag)
            self.view.window?.makeFirstResponder(self.files.outlineView)
        }
        tags.onChange = { [weak self] in self?.updateBottomSections() }
        // 折叠状态记住
        for (sec, key) in [(favoritesSection!, "favorites"), (tagsSection!, "tags")] {
            let def = key == "favorites" || key == "tags"   // 收藏 / 标签默认折叠
            sec.setCollapsed(SidebarSettings.isCollapsed(key) ?? def)
            sec.onToggle = { [weak self] c in SidebarSettings.setCollapsed(key, c); self?.sectionsDidChange() }
        }
        sectionsDidChange()
        prefsObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let rules = Preferences.shared.sidebarRules
                if rules != self.lastRules { self.lastRules = rules; self.files.reloadTree() }
                self.updateBottomSections()
            }
        }
        settingsObserver = NotificationCenter.default.addObserver(forName: SidebarSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.files.reloadTree(); self?.updateBottomSections(); self?.rebuildLocationMenu() }
        }
        lastRules = Preferences.shared.sidebarRules
    }
    deinit {
        if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        currentURLDidChange()
        updateEmptyState()
    }


    // MARK: - 根目录 / 当前文档（对外 API 与旧版一致）

    func setRoot(_ url: URL) { rootURL = url }

    /// 显示当前文件：若不在根目录下则把根切到其所在目录
    func revealCurrent() {
        guard let url = currentURL else { return }
        if let root = rootURL, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") {
            if files.mode != .tree { clearFilter() }
            files.revealCurrent()
        } else { rootURL = url.deletingLastPathComponent() }
    }

    private func currentURLDidChange() {
        guard isViewLoaded else { return }
        guard let url = currentURL else { files.currentURL = nil; updateEmptyState(); return }
        if rootURL == nil || !url.standardizedFileURL.path.hasPrefix(rootURL!.standardizedFileURL.path + "/") {
            rootURL = url.deletingLastPathComponent()
        }
        files.currentURL = url
    }

    private func rootDidChange() {
        guard isViewLoaded else { return }
        files.root = rootURL
        files.currentURL = currentURL
        tags.root = rootURL
        if let rootURL { SidebarSettings.noteRoot(rootURL) }
        files.outline = outline
        rebuildLocationMenu()
        updateEmptyState()
        updateFilesHeader()
    }

    private func outlineDidChange() {
        guard isViewLoaded else { return }
        files.outline = outline
    }

    func highlight(blockIndex: Int) { files.highlight(blockIndex: blockIndex) }

    private func updateEmptyState() {
        let hasRoot = rootURL != nil
        emptyLabel.isHidden = hasRoot
        filesSection.isHidden = !hasRoot
        filterField.isHidden = !hasRoot
        favoritesSection.isHidden = !hasRoot || !SidebarSettings.showFavorites || favorites.count == 0
        tagsSection.isHidden = !hasRoot || !SidebarSettings.showTags || tags.count == 0
        locationButton.title = rootURL?.lastPathComponent ?? L("选择文件夹…")
    }

    // MARK: - 段头

    private func updateFilesHeader() {
        switch files.mode {
        case .tree: filesSection.title = L("文件"); filesSection.count = ""
        case .filter: filesSection.title = L("文件"); filesSection.count = "\(files.resultCount)"
        case .search: filesSection.title = L("搜索结果"); filesSection.count = "\(files.resultCount)"
        }
    }
    private func updateBottomSections() {
        favoritesSection.count = "\(favorites.count)"
        tagsSection.count = "\(tags.count)"
        favoritesHeight.constant = favoritesSection.isCollapsed ? SidebarSectionView.headerHeight : SidebarSectionView.headerHeight + favorites.preferredHeight
        tagsHeight.constant = tagsSection.isCollapsed ? SidebarSectionView.headerHeight : SidebarSectionView.headerHeight + tags.preferredHeight
        updateEmptyState()
    }
    private func sectionsDidChange() { updateBottomSections() }

    // MARK: - 位置菜单

    private func rebuildLocationMenu() {
        guard let menu = locationButton.menu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: rootURL?.lastPathComponent ?? L("选择文件夹…"), action: nil, keyEquivalent: "")   // pull-down 的第一项 = 按钮标题
        let recents = SidebarSettings.recentRoots.filter { $0.standardizedFileURL != rootURL?.standardizedFileURL && FileManager.default.fileExists(atPath: $0.path) }
        if !recents.isEmpty {
            let hd = NSMenuItem(title: L("最近打开的文件夹"), action: nil, keyEquivalent: ""); hd.isEnabled = false; menu.addItem(hd)
            for r in recents.prefix(8) {
                let it = NSMenuItem(title: r.lastPathComponent, action: #selector(pickRecentRoot(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = r; it.toolTip = r.path; it.indentationLevel = 1
                it.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                menu.addItem(it)
            }
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: L("打开文件夹…"), action: #selector(chooseFolder(_:)), keyEquivalent: ""); open.target = self; menu.addItem(open)
        if rootURL != nil {
            let reveal = NSMenuItem(title: L("在 Finder 中显示"), action: #selector(revealRoot(_:)), keyEquivalent: ""); reveal.target = self; menu.addItem(reveal)
        }
        menu.addItem(.separator())
        let sortHd = NSMenuItem(title: L("排序"), action: nil, keyEquivalent: ""); sortHd.isEnabled = false; menu.addItem(sortHd)
        for (title, s) in [(L("自然顺序"), SidebarSettings.Sort.natural), (L("名称"), .name), (L("修改时间"), .modified)] {
            let it = NSMenuItem(title: title, action: #selector(pickSort(_:)), keyEquivalent: ""); it.target = self; it.tag = s.rawValue; it.indentationLevel = 1
            it.state = SidebarSettings.sort == s ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let hidden = NSMenuItem(title: L("显示隐藏文件"), action: #selector(toggleHidden(_:)), keyEquivalent: ""); hidden.target = self; hidden.state = Preferences.shared.sidebarShowHidden ? .on : .off; menu.addItem(hidden)
        let fav = NSMenuItem(title: L("显示「收藏」"), action: #selector(toggleFavoritesSection(_:)), keyEquivalent: ""); fav.target = self; fav.state = SidebarSettings.showFavorites ? .on : .off; menu.addItem(fav)
        let tg = NSMenuItem(title: L("显示「标签」"), action: #selector(toggleTagsSection(_:)), keyEquivalent: ""); tg.target = self; tg.state = SidebarSettings.showTags ? .on : .off; menu.addItem(tg)
        let rv = NSMenuItem(title: L("切换文档时定位到它"), action: #selector(toggleRevealCurrent(_:)), keyEquivalent: ""); rv.target = self; rv.state = SidebarSettings.revealCurrent ? .on : .off; menu.addItem(rv)
    }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildLocationMenu() }

    @objc private func pickRecentRoot(_ s: NSMenuItem) { if let u = s.representedObject as? URL { setRoot(u) } }
    @objc private func chooseFolder(_ s: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("打开")
        panel.directoryURL = rootURL
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.setRoot(url)
        }
    }
    @objc private func revealRoot(_ s: Any?) { if let r = rootURL { NSWorkspace.shared.activateFileViewerSelecting([r]) } }
    @objc private func pickSort(_ s: NSMenuItem) { SidebarSettings.sort = SidebarSettings.Sort(rawValue: s.tag) ?? .natural; NotificationCenter.default.post(name: SidebarSettings.didChange, object: nil) }
    @objc private func toggleHidden(_ s: Any?) { Preferences.shared.sidebarShowHidden.toggle() }
    @objc private func toggleFavoritesSection(_ s: Any?) { SidebarSettings.showFavorites.toggle(); NotificationCenter.default.post(name: SidebarSettings.didChange, object: nil) }
    @objc private func toggleTagsSection(_ s: Any?) { SidebarSettings.showTags.toggle(); NotificationCenter.default.post(name: SidebarSettings.didChange, object: nil) }
    @objc private func toggleRevealCurrent(_ s: Any?) { SidebarSettings.revealCurrent.toggle(); NotificationCenter.default.post(name: SidebarSettings.didChange, object: nil) }

    // MARK: - 筛选 / 搜索

    /// ⌘⇧F：聚焦筛选框并进入搜索（有文字就直接搜）
    func showSearch() {
        guard rootURL != nil else { NSSound.beep(); return }
        view.window?.makeFirstResponder(filterField)
        if !filterField.stringValue.isEmpty { filterField.selectText(nil); files.search(filterField.stringValue) }
    }
    /// 程序设置筛选文字（调试 / 标签点击）
    func setFilterText(_ text: String, search: Bool) {
        filterField.stringValue = text
        if search { files.search(text) } else { files.applyFilter(text) }
    }

    /// ⌥⌘F：聚焦筛选框
    func focusFilter() {
        guard rootURL != nil else { NSSound.beep(); return }
        view.window?.makeFirstResponder(filterField)
        if !filterField.stringValue.isEmpty { filterField.selectText(nil) }
    }

    @objc private func filterChanged(_ sender: Any?) {
        filterWork?.cancel()
        let q = filterField.stringValue
        if q.isEmpty { clearFilter(); return }
        if case .search = files.mode { return }   // 搜索态里改文字：等回车再搜
        let w = DispatchWorkItem { [weak self] in self?.files.applyFilter(q) }
        filterWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    private func clearFilter() {
        filterWork?.cancel()
        filterField.stringValue = ""
        files.clearToTree()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            clearFilter()
            view.window?.makeFirstResponder(files.outlineView)
            return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let q = filterField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return true }
            filterWork?.cancel()
            files.search(q)
            return true
        }
        if sel == #selector(NSResponder.moveDown(_:)) { files.focusFirstResult(); return true }
        return false
    }
}

extension SidebarViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = files; panel.delegate = files }   // CI 的 Swift 6.1 把这两个方法当 nonisolated
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil; panel.delegate = nil }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { files.numberOfPreviewItems(in: panel) }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { files.previewPanel(panel, previewItemAt: index) }
}
