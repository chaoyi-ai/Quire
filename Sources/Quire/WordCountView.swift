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
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
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
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
    }

    func update(stats: TextStats) { self.stats = stats; render() }
    func update(selection: TextStats?) { selectionStats = selection; render() }

    private func render() {
        let s = selectionStats ?? stats
        let n = Self.number(s.words)
        label.stringValue = selectionStats != nil
            ? String(format: L("已选 %@ 字"), n)
            : String(format: L("%@ 字 · %d 分钟"), n, s.readingMinutes)
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
