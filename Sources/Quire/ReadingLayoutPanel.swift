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
    private let sizeSlider = NSSlider(value: 16, minValue: 0, maxValue: Double(ReadingLayout.fontSizes.count - 1), target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let weightControl = NSSegmentedControl(labels: [L("主题"), L("中"), L("半粗")], trackingMode: .selectOne, target: nil, action: nil)
    private let lineSlider = NSSlider(value: 1.6, minValue: ReadingLayout.lineHeightRange.lowerBound, maxValue: ReadingLayout.lineHeightRange.upperBound, target: nil, action: nil)
    private let lineLabel = NSTextField(labelWithString: "")
    private let paraSlider = NSSlider(value: 1, minValue: ReadingLayout.paragraphSpacingRange.lowerBound, maxValue: ReadingLayout.paragraphSpacingRange.upperBound, target: nil, action: nil)
    private let paraLabel = NSTextField(labelWithString: "")
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
        func sliderRow(_ slider: NSSlider, _ value: NSTextField) -> NSView {
            slider.isContinuous = true
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 270).isActive = true   // NSSlider 没有固有宽度，不定就缩成一个点
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); value.textColor = .secondaryLabelColor
            value.alignment = .right; value.widthAnchor.constraint(equalToConstant: 48).isActive = true
            let st = NSStackView(views: [slider, value]); st.orientation = .horizontal; st.spacing = 8
            return st
        }

        presetPopup.target = self; presetPopup.action = #selector(presetChanged(_:))
        row(L("预设"), presetPopup)

        fontPopup.target = self; fontPopup.action = #selector(fontChanged(_:))
        row(L("正文字体"), fontPopup)
        codeFontPopup.target = self; codeFontPopup.action = #selector(codeFontChanged(_:))
        row(L("代码字体"), codeFontPopup)

        sizeSlider.numberOfTickMarks = ReadingLayout.fontSizes.count; sizeSlider.allowsTickMarkValuesOnly = true
        sizeSlider.target = self; sizeSlider.action = #selector(sizeChanged(_:))
        row(L("字号"), sliderRow(sizeSlider, sizeLabel))

        weightControl.target = self; weightControl.action = #selector(weightChanged(_:))
        weightControl.segmentDistribution = .fillEqually
        row(L("正文粗细"), weightControl)

        lineSlider.target = self; lineSlider.action = #selector(lineChanged(_:))
        row(L("行距"), sliderRow(lineSlider, lineLabel))
        paraSlider.target = self; paraSlider.action = #selector(paraChanged(_:))
        row(L("段距"), sliderRow(paraSlider, paraLabel))

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
        let size = l.fontSize > 0 ? l.fontSize : Int(t.baseSize)
        sizeSlider.doubleValue = Double(ReadingLayout.fontSizes.firstIndex(of: size) ?? ReadingLayout.fontSizes.firstIndex { $0 >= size } ?? 3)
        sizeLabel.stringValue = l.fontSize > 0 ? "\(size) pt" : "\(size)*"
        weightControl.selectedSegment = l.weight.rawValue
        let lh = l.lineHeight > 0 ? l.lineHeight : Double(t.lineHeight)
        lineSlider.doubleValue = lh; lineLabel.stringValue = String(format: l.lineHeight > 0 ? "%.2f" : "%.2f*", lh)
        let ps = l.paragraphSpacing > 0 ? l.paragraphSpacing : Double(t.paragraphSpacing)
        paraSlider.doubleValue = ps; paraLabel.stringValue = String(format: l.paragraphSpacing > 0 ? "%.2f" : "%.2f*", ps)
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
    /// 滑杆连续拖动：70 ms 内只提交一次（1 MB 文档一次全量重建 ≈ 120 ms，不能每帧都来）
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
    @objc private func sizeChanged(_ s: NSSlider) {
        let size = ReadingLayout.fontSizes[min(max(0, Int(s.doubleValue.rounded())), ReadingLayout.fontSizes.count - 1)]
        sizeLabel.stringValue = "\(size) pt"
        debounced { $0.fontSize = size }
    }
    @objc private func weightChanged(_ s: NSSegmentedControl) { let w = ReadingLayout.Weight(rawValue: s.selectedSegment) ?? .theme; update { $0.weight = w } }
    @objc private func lineChanged(_ s: NSSlider) {
        let v = (s.doubleValue * 20).rounded() / 20
        lineLabel.stringValue = String(format: "%.2f", v)
        debounced { $0.lineHeight = v }
    }
    @objc private func paraChanged(_ s: NSSlider) {
        let v = (s.doubleValue * 20).rounded() / 20
        paraLabel.stringValue = String(format: "%.2f", v)
        debounced { $0.paragraphSpacing = v }
    }
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
