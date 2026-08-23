import AppKit
import QuireCore

/// 快速打开（⌘P）：悬浮面板 = 搜索框 + 结果表；↑↓ 选择、⏎ 打开、Esc 关闭。
@MainActor
final class QuickOpenPanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var indexToken: ChangeObservers.Token?
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private var index: FileIndex
    private var results: [(path: String, match: FuzzyMatcher.Match)] = []
    private var onOpen: (URL) -> Void

    static func present(for root: URL, over window: NSWindow?, onOpen: @escaping (URL) -> Void) {
        let p = QuickOpenPanel(index: FileIndex.index(for: root), onOpen: onOpen)
        if let window {
            let f = window.frame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - 120 - p.frame.height))
        } else { p.center() }
        p.makeKeyAndOrderFront(nil)
        p.refresh()
    }

    private init(index: FileIndex, onOpen: @escaping (URL) -> Void) {
        self.index = index
        self.onOpen = onOpen
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        level = .floating
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        contentView = effect

        field.placeholderString = L("输入文件名模糊匹配…")
        field.font = .systemFont(ofSize: 18)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: .init("path"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 40
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(field); effect.addSubview(sep); effect.addSubview(scroll); effect.addSubview(hint)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            sep.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -4),
            hint.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
        ])
        indexToken = index.observers.add { [weak self] in self?.refresh() }
        initialFirstResponder = field
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }

    func refresh() {
        results = index.search(field.stringValue)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        let n = index.relativePaths.count
        hint.stringValue = index.isScanning ? L("正在扫描…") : String(format: L("%d 个文件 · ↑↓ 选择 ⏎ 打开 Esc 关闭"), n) + (index.truncated ? L("（已截断）") : "")
    }

    // MARK: 输入

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        let r = max(0, min(results.count - 1, table.selectedRow + d))
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc private func openSelected() {
        let r = table.selectedRow
        guard r >= 0, r < results.count else { return }
        let url = index.url(for: results[r].path)
        close()
        onOpen(url)
    }

    // MARK: 表

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: ""); t.identifier = id; t.lineBreakMode = .byTruncatingMiddle; t.maximumNumberOfLines = 2; return t
        }()
        let (path, match) = results[row]
        let nsPath = path as NSString
        let name = nsPath.lastPathComponent
        let dir = nsPath.deletingLastPathComponent
        let s = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor])
        if !dir.isEmpty {
            s.append(NSAttributedString(string: "\n" + dir, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        // 命中字符加粗着色（positions 是整条相对路径的 scalar 下标；这里只高亮落在文件名里的）
        let scalars = Array(path.unicodeScalars)
        let nameStart = scalars.count - name.unicodeScalars.count
        for p in match.positions where p >= nameStart {
            let utf16Offset = String(String.UnicodeScalarView(scalars[nameStart..<p])).utf16.count
            let len = String(scalars[p]).utf16.count
            if utf16Offset + len <= (name as NSString).length {
                s.addAttributes([.foregroundColor: NSColor.controlAccentColor], range: NSRange(location: utf16Offset, length: len))
            }
        }
        cell.attributedStringValue = s
        return cell
    }
}
