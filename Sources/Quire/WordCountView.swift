import AppKit
import QuireCore

/// 右下角字数胶囊：显示「N 字 · M 分钟」；有选区时显示选区统计；点击弹出明细。
@MainActor
final class WordCountView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var stats = TextStats()
    private var selectionStats: TextStats?
    private var popover: NSPopover?
    /// 章节进度（Kindle 的"本章剩余"）；nil = 没有阅读视图位置（编辑模式）或文档空
    private var chapter: ChapterProgress?
    /// 阅读速度（校准后算全文分钟；明细里显示校准状态）
    weak var tracker: ReadingTracker?
    /// 胶囊显示：0 全文 / 1 本章剩余（`reader.progressMode`）
    private static let modeKey = "reader.progressMode"
    private var progressMode: Int {
        get { UserDefaults.standard.integer(forKey: Self.modeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.modeKey); render() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        updateBackground()
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        toolTip = L("字数统计（点击查看明细）")
        setAccessibilityRole(.button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); updateBackground()
        if themeObserver == nil {
            themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBackground() }
            }
        }
    }
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }
    /// 动态颜色转 CGColor 必须在本视图的 effectiveAppearance 下算：App 用「浅色」而系统是深色时，直接取 cgColor 会拿到深色版（浅色界面里一块黑胶囊）
    private func updateBackground() {
        // 底色跟主题走（和侧栏一样"抬高一级"），不然 Solarized 之类的主题里它是唯一一块系统灰
        let bg = ThemeManager.shared.currentStyle.background.usingColorSpace(.sRGB) ?? .windowBackgroundColor
        let lum = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent
        let tint = (lum < 0.5 ? bg.blended(withFraction: 0.08, of: .white) : bg.blended(withFraction: 0.04, of: .black)) ?? bg
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(0.9).cgColor
        }
    }

    func update(stats: TextStats) { self.stats = stats; render() }
    func update(chapter: ChapterProgress?) { guard chapter != self.chapter else { return }; self.chapter = chapter; render() }
    func update(selection: TextStats?) { selectionStats = selection; render() }
    /// 开着的编辑器模式（专注 / 词性 / 文风）：显示在胶囊里，免得"怎么整页都是灰的"却不知道是专注模式在起作用
    func update(modes: [String]) { activeModes = modes; render() }
    private var activeModes: [String] = []

    private func render() {
        let s = selectionStats ?? stats
        let n = Self.number(s.words)
        let minutes = tracker?.minutes(for: s) ?? s.readingMinutes
        var text: String
        if selectionStats != nil { text = String(format: L("已选 %@ 字"), n) }
        else if progressMode == 1, let ch = chapter { text = String(format: L("本章剩余 %d 分钟"), ch.remainingMinutes) }
        else { text = String(format: L("%@ 字 · %d 分钟"), n, minutes) }
        if !activeModes.isEmpty { text += " · " + activeModes.joined(separator: " · ") }
        label.stringValue = text
        setAccessibilityLabel(label.stringValue)
    }

    static func number(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    override func mouseDown(with event: NSEvent) {
        if let popover, popover.isShown { popover.close(); return }
        let s = selectionStats ?? stats
        var rows: [(String, String)] = [
            (selectionStats != nil ? L("选区字词") : L("字词"), Self.number(s.words)),
            (L("其中中文字"), Self.number(s.cjkCharacters)),
            (L("字符（不含空格）"), Self.number(s.characters)),
            (L("行"), Self.number(s.lines)),
            (L("阅读时间"), String(format: L("约 %d 分钟"), tracker?.minutes(for: s) ?? s.readingMinutes)),
        ]
        if selectionStats == nil, let ch = chapter {
            rows.append((L("本章"), ch.title.isEmpty ? L("（正文开头）") : ch.title))
            rows.append((L("本章剩余"), String(format: L("%@ 字 · 约 %d 分钟"), Self.number(ch.remainingWords), ch.remainingMinutes)))
        }
        if let sp = tracker?.speed {
            rows.append((L("阅读速度"), sp.isCalibrated ? String(format: L("实测约标称的 %.1f 倍（%d 个样本）"), sp.factor, sp.samples) : L("尚未校准（按 400 字 / 200 词每分钟估算）")))
        }
        let grid = NSGridView(views: rows.map { r in
            let k = NSTextField(labelWithString: r.0); k.textColor = .secondaryLabelColor; k.font = .systemFont(ofSize: 12)
            let v = NSTextField(labelWithString: r.1); v.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium); v.alignment = .right
            v.lineBreakMode = .byTruncatingTail; v.maximumNumberOfLines = 1; v.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            return [k, v]
        })
        // 胶囊显示什么：全文 / 本章剩余；速度校准可重置
        let mode = NSSegmentedControl(labels: [L("全文"), L("本章剩余")], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        mode.selectedSegment = progressMode; mode.controlSize = .small
        let reset = NSButton(title: L("重置速度校准"), target: self, action: #selector(resetSpeed(_:)))
        reset.bezelStyle = .rounded; reset.controlSize = .small; reset.isEnabled = (tracker?.speed.samples ?? 0) > 0
        let k = NSTextField(labelWithString: L("胶囊显示")); k.textColor = .secondaryLabelColor; k.font = .systemFont(ofSize: 12)
        grid.addRow(with: [k, mode])
        grid.addRow(with: [NSView(), reset])
        grid.columnSpacing = 16; grid.rowSpacing = 4
        grid.column(at: 1).xPlacement = .trailing
        let vc = NSViewController()
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        vc.view = container
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        popover = p
    }

    @objc private func modeChanged(_ s: NSSegmentedControl) { progressMode = s.selectedSegment }
    @objc private func resetSpeed(_ s: Any?) { tracker?.resetSpeed(); popover?.close(); render() }
}
