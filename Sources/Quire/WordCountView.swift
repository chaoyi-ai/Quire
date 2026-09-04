import AppKit
import QuireCore

/// 右下角字数胶囊：显示「N 字 · M 分钟」；有选区时显示选区统计；点击弹出明细。
@MainActor
final class WordCountView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var stats = TextStats()
    private var selectionStats: TextStats?
    private var popover: NSPopover?

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
    func update(selection: TextStats?) { selectionStats = selection; render() }
    /// 开着的编辑器模式（专注 / 词性 / 文风）：显示在胶囊里，免得"怎么整页都是灰的"却不知道是专注模式在起作用
    func update(modes: [String]) { activeModes = modes; render() }
    private var activeModes: [String] = []

    private func render() {
        let s = selectionStats ?? stats
        let n = Self.number(s.words)
        var text = selectionStats != nil
            ? String(format: L("已选 %@ 字"), n)
            : String(format: L("%@ 字 · %d 分钟"), n, s.readingMinutes)
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
        let rows: [(String, String)] = [
            (selectionStats != nil ? L("选区字词") : L("字词"), Self.number(s.words)),
            (L("其中中文字"), Self.number(s.cjkCharacters)),
            (L("字符（不含空格）"), Self.number(s.characters)),
            (L("行"), Self.number(s.lines)),
            (L("阅读时间"), String(format: L("约 %d 分钟"), s.readingMinutes)),
        ]
        let grid = NSGridView(views: rows.map { r in
            let k = NSTextField(labelWithString: r.0); k.textColor = .secondaryLabelColor; k.font = .systemFont(ofSize: 12)
            let v = NSTextField(labelWithString: r.1); v.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium); v.alignment = .right
            return [k, v]
        })
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
}
