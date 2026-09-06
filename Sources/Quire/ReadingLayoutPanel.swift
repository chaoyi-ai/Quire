import AppKit
import QuireRender

/// 工具栏「Aa」弹出面板：就地调阅读版式，拖滑杆正文实时跟着变（Kindle 的 Aa 菜单）。
/// 数据只有一份——Preferences.readingLayout；设置窗口里的 Picker 指向同一份。
@MainActor
final class ReadingLayoutPanelController: NSViewController {
    private let prefs = Preferences.shared
    private var layout: ReadingLayout { prefs.readingLayout }

    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let codeFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeField = StepField(min: 10, max: 36, step: 1, decimals: 0, unit: "pt")
    private let weightControl = NSSegmentedControl(labels: [L("主题"), L("中"), L("半粗")], trackingMode: .selectOne, target: nil, action: nil)
    private let lineField = StepField(min: 1.0, max: 2.5, step: 0.05, decimals: 2, unit: "×")
    private let paraField = StepField(min: 0.25, max: 2.0, step: 0.05, decimals: 2, unit: "em")
    private let widthControl = NSSegmentedControl(labels: [L("主题"), L("窄"), L("中"), L("宽"), L("不限")], trackingMode: .selectOne, target: nil, action: nil)
    private let alignControl = NSSegmentedControl(labels: [L("主题"), L("左对齐"), L("两端对齐")], trackingMode: .selectOne, target: nil, action: nil)
    private var pending: DispatchWorkItem?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    override func loadView() {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10; grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.yPlacement = .center   // 标签与控件按行垂直居中（默认是顶对齐，滑杆 / 分段控件比标签高，标签会浮在上沿）
        grid.column(at: 1).width = 340

        func label(_ s: String) -> NSTextField { let t = NSTextField(labelWithString: s); t.textColor = .secondaryLabelColor; t.font = .systemFont(ofSize: 12); return t }
        func row(_ name: String, _ v: NSView) { grid.addRow(with: [label(name), v]) }

        presetPopup.target = self; presetPopup.action = #selector(presetChanged(_:))
        row(L("预设"), presetPopup)

        fontPopup.target = self; fontPopup.action = #selector(fontChanged(_:))
        row(L("正文字体"), fontPopup)
        codeFontPopup.target = self; codeFontPopup.action = #selector(codeFontChanged(_:))
        row(L("代码字体"), codeFontPopup)

        // 数值项用"输入框 + 步进器"（macOS 字体面板 / 系统设置的做法），不用滑杆：桌面上滑杆难精确到某个值，也没法直接打数字
        sizeField.onChange = { [weak self] v in self?.debounced { $0.fontSize = Int(v) } }
        sizeField.onReset = { [weak self] in self?.update { $0.fontSize = 0 } }
        row(L("字号"), sizeField)

        weightControl.target = self; weightControl.action = #selector(weightChanged(_:))
        weightControl.segmentDistribution = .fillEqually
        row(L("正文粗细"), weightControl)

        lineField.onChange = { [weak self] v in self?.debounced { $0.lineHeight = v } }
        lineField.onReset = { [weak self] in self?.update { $0.lineHeight = 0 } }
        row(L("行距"), lineField)
        paraField.onChange = { [weak self] v in self?.debounced { $0.paragraphSpacing = v } }
        paraField.onReset = { [weak self] in self?.update { $0.paragraphSpacing = 0 } }
        row(L("段距"), paraField)

        widthControl.target = self; widthControl.action = #selector(widthChanged(_:))
        widthControl.segmentDistribution = .fillEqually
        row(L("行宽"), widthControl)
        alignControl.target = self; alignControl.action = #selector(alignChanged(_:))
        alignControl.segmentDistribution = .fillEqually
        row(L("对齐"), alignControl)

        let reset = NSButton(title: L("全部跟随主题"), target: self, action: #selector(resetAll(_:)))
        reset.bezelStyle = .rounded; reset.controlSize = .small
        let save = NSButton(title: L("存为预设…"), target: self, action: #selector(savePreset(_:)))
        save.bezelStyle = .rounded; save.controlSize = .small
        let buttons = NSStackView(views: [reset, NSView(), save]); buttons.orientation = .horizontal
        grid.addRow(with: [NSView(), buttons])

        let root = NSView()
        root.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        view = root
        populateFonts()
        refresh()
        observer = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    // MARK: 显示

    private func populateFonts() {
        let fm = NSFontManager.shared
        fontPopup.removeAllItems(); codeFontPopup.removeAllItems()
        fontPopup.addItem(withTitle: L("跟随主题")); fontPopup.lastItem?.representedObject = ""
        codeFontPopup.addItem(withTitle: L("跟随主题")); codeFontPopup.lastItem?.representedObject = ""
        fontPopup.menu?.addItem(.separator()); codeFontPopup.menu?.addItem(.separator())
        for fam in fm.availableFontFamilies.filter({ !$0.hasPrefix(".") }).sorted() {
            fontPopup.addItem(withTitle: fam); fontPopup.lastItem?.representedObject = fam
            if fam.hasPrefix("iA Writer") || (fm.font(withFamily: fam, traits: [], weight: 5, size: 12)?.isFixedPitch ?? false) {
                codeFontPopup.addItem(withTitle: fam); codeFontPopup.lastItem?.representedObject = fam
            }
        }
    }

    private func select(_ popup: NSPopUpButton, family: String) {
        if let i = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == family }) { popup.selectItem(at: i) }
        else { popup.addItem(withTitle: family); popup.lastItem?.representedObject = family; popup.select(popup.lastItem) }
    }

    /// 从 Preferences 回填控件；滑杆在"跟随主题"时显示主题的实际值
    private func refresh() {
        let l = layout
        let t = ThemeManager.shared.currentTheme.typography
        refreshPresets()
        select(fontPopup, family: l.bodyFontFamily); select(codeFontPopup, family: l.codeFontFamily)
        sizeField.set(value: Double(l.fontSize > 0 ? l.fontSize : Int(t.baseSize)), followingTheme: l.fontSize == 0)
        weightControl.selectedSegment = l.weight.rawValue
        lineField.set(value: l.lineHeight > 0 ? l.lineHeight : Double(t.lineHeight), followingTheme: l.lineHeight == 0)
        paraField.set(value: l.paragraphSpacing > 0 ? l.paragraphSpacing : Double(t.paragraphSpacing), followingTheme: l.paragraphSpacing == 0)
        widthControl.selectedSegment = ReadingLayout.contentWidths.firstIndex(of: l.contentWidth) ?? 0
        alignControl.selectedSegment = l.alignment.rawValue
    }

    private func refreshPresets() {
        presetPopup.removeAllItems()
        let user = prefs.layoutPresets
        for p in ReadingLayoutPreset.builtIn { presetPopup.addItem(withTitle: Self.localizedName(of: p)); presetPopup.lastItem?.representedObject = p }
        if !user.isEmpty {
            presetPopup.menu?.addItem(.separator())
            for p in user { presetPopup.addItem(withTitle: p.name); presetPopup.lastItem?.representedObject = p }
        }
        presetPopup.menu?.addItem(.separator())
        presetPopup.addItem(withTitle: L("自定义")); presetPopup.lastItem?.representedObject = nil
        if !user.isEmpty {
            presetPopup.menu?.addItem(.separator())
            let del = NSMenuItem(title: L("删除预设"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for p in user { let it = NSMenuItem(title: p.name, action: #selector(deletePreset(_:)), keyEquivalent: ""); it.target = self; it.representedObject = p.id; sub.addItem(it) }
            del.submenu = sub
            presetPopup.menu?.addItem(del)
        }
        if let m = ReadingLayoutPreset.matching(layout, user: user), let i = presetPopup.itemArray.firstIndex(where: { ($0.representedObject as? ReadingLayoutPreset)?.id == m.id }) {
            presetPopup.selectItem(at: i)
        } else {
            presetPopup.selectItem(withTitle: L("自定义"))
        }
    }

    /// 内置预设名走字面量 L()（本地化测试按字面量扫键）
    static func localizedName(of p: ReadingLayoutPreset) -> String {
        switch p.id {
        case "compact": return L("紧凑")
        case "standard": return L("标准")
        case "comfortable": return L("舒适")
        case "large": return L("大字")
        default: return p.name
        }
    }

    // MARK: 修改

    private func update(_ change: (inout ReadingLayout) -> Void) {
        var l = layout; change(&l)
        guard l != layout else { return }
        prefs.readingLayout = l
    }
    /// 步进器连点 / 键盘连按：70 ms 内只提交一次（1 MB 文档一次全量重建 ≈ 120 ms，不能每下都来）
    private func debounced(_ change: @escaping (inout ReadingLayout) -> Void) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.update(change) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: w)
    }

    @objc private func presetChanged(_ s: NSPopUpButton) {
        guard let p = s.selectedItem?.representedObject as? ReadingLayoutPreset else { refreshPresets(); return }
        update { $0 = p.layout }
    }
    @objc private func fontChanged(_ s: NSPopUpButton) { let f = (s.selectedItem?.representedObject as? String) ?? ""; update { $0.bodyFontFamily = f } }
    @objc private func codeFontChanged(_ s: NSPopUpButton) { let f = (s.selectedItem?.representedObject as? String) ?? ""; update { $0.codeFontFamily = f } }
    @objc private func weightChanged(_ s: NSSegmentedControl) { let w = ReadingLayout.Weight(rawValue: s.selectedSegment) ?? .theme; update { $0.weight = w } }
    @objc private func widthChanged(_ s: NSSegmentedControl) { let w = ReadingLayout.contentWidths[s.selectedSegment]; update { $0.contentWidth = w } }
    @objc private func alignChanged(_ s: NSSegmentedControl) { let a = ReadingLayout.Alignment(rawValue: s.selectedSegment) ?? .theme; update { $0.alignment = a } }
    @objc private func resetAll(_ s: Any?) { update { $0 = .followTheme } }

    @objc private func savePreset(_ s: Any?) {
        let a = NSAlert()
        a.messageText = L("存为预设")
        a.informativeText = L("预设只记版式（字体、字号、行距、行宽…），不含配色主题。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L("预设名称")
        a.accessoryView = field
        a.addButton(withTitle: L("存储")); a.addButton(withTitle: L("取消"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var list = prefs.layoutPresets.filter { $0.name != name }
        list.append(ReadingLayoutPreset(id: UUID().uuidString, name: name, layout: layout))
        prefs.layoutPresets = list
        refreshPresets()
    }
    @objc private func deletePreset(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        prefs.layoutPresets.removeAll { $0.id == id }
        refreshPresets()
    }
}

/// 数值项：可输入的文本框 + 步进器 + 单位；右侧一个小「↺」把该项恢复为跟随主题。
/// 跟随主题时显示主题的实际值（灰字），一旦输入 / 步进就变成显式值（黑字）。
@MainActor
final class StepField: NSStackView, NSTextFieldDelegate {
    var onChange: ((Double) -> Void)?
    var onReset: (() -> Void)?
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let unitLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton()
    private let decimals: Int
    private let range: ClosedRange<Double>

    init(min: Double, max: Double, step: Double, decimals: Int, unit: String) {
        self.decimals = decimals; range = min...max
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 4; alignment = .centerY
        let f = NumberFormatter(); f.minimumFractionDigits = decimals; f.maximumFractionDigits = decimals; f.minimum = NSNumber(value: min); f.maximum = NSNumber(value: max)
        field.formatter = f
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.controlSize = .small
        field.delegate = self
        field.target = self; field.action = #selector(fieldCommitted(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        stepper.minValue = min; stepper.maxValue = max; stepper.increment = step
        stepper.valueWraps = false; stepper.controlSize = .small
        stepper.target = self; stepper.action = #selector(stepped(_:))
        unitLabel.stringValue = unit; unitLabel.font = .systemFont(ofSize: 11); unitLabel.textColor = .secondaryLabelColor
        unitLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: L("恢复为跟随主题"))?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        resetButton.isBordered = false; resetButton.bezelStyle = .texturedRounded; resetButton.imagePosition = .imageOnly
        resetButton.toolTip = L("恢复为跟随主题")
        resetButton.target = self; resetButton.action = #selector(reset(_:))
        addView(field, in: .leading); addView(stepper, in: .leading); addView(unitLabel, in: .leading); addView(resetButton, in: .leading)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(value: Double, followingTheme: Bool) {
        field.doubleValue = value
        stepper.doubleValue = value
        field.textColor = followingTheme ? .secondaryLabelColor : .labelColor
        field.toolTip = followingTheme ? L("跟随主题") : nil
        resetButton.isHidden = followingTheme
    }

    private func commit(_ v: Double) {
        let clamped = Swift.min(range.upperBound, Swift.max(range.lowerBound, v))
        set(value: clamped, followingTheme: false)
        onChange?(clamped)
    }
    @objc private func stepped(_ s: NSStepper) { commit(s.doubleValue) }
    @objc private func fieldCommitted(_ f: NSTextField) { commit(f.doubleValue) }
    func controlTextDidEndEditing(_ obj: Notification) { commit(field.doubleValue) }
    @objc private func reset(_ s: Any?) { onReset?() }
}
