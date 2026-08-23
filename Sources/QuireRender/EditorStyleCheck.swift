import AppKit
import QuireCore

/// 文风检查在编辑器里的呈现：命中的短语画橙色虚线删除线 + 悬停提示类别；只做可见段落 ± 一屏，后台匹配，主线程只改属性。
extension EditorTextView {
    static let styleCheckColor = NSColor.systemOrange
    static let styleCheckStyle = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue

    public func scheduleStyleCheck(delay: TimeInterval = 0.3) {
        guard styleChecker != nil else { return }
        styleCheckWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.runStyleCheckVisible() }
        styleCheckWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func runStyleCheckVisible() {
        guard let checker = styleChecker, let ts = textStorage, let sv = enclosingScrollView,
              let tlm = textLayoutManager, let cs = textContentStorage else { return }
        let band = sv.contentView.bounds.insetBy(dx: 0, dy: -sv.contentView.bounds.height)
        guard let startFrag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, band.minY - textContainerInset.height))) else { return }
        var paragraphs: [NSRange] = []
        tlm.enumerateTextLayoutFragments(from: startFrag.rangeInElement.location, options: [.ensuresLayout]) { frag in
            if frag.layoutFragmentFrame.minY + self.textContainerInset.height > band.maxY { return false }
            let start = cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location)
            paragraphs.append(NSRange(location: start, length: cs.offset(from: frag.rangeInElement.location, to: frag.rangeInElement.endLocation)))
            return true
        }
        let ns = ts.string as NSString
        let codeColor = style.theme.colors.editor.markdownCode.nsColor
        let jobs: [(NSRange, String)] = paragraphs.compactMap { p in
            guard p.length > 1 else { return nil }
            if let c = ts.attribute(.foregroundColor, at: p.location, effectiveRange: nil) as? NSColor, c == codeColor { return nil }
            return (p, ns.substring(with: p))
        }
        let generation = styleCheckGeneration
        let paras = paragraphs   // 值拷贝（Sendable），闭包里不再碰外层的 var
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var hits: [(NSRange, StyleChecker.Match)] = []
            for (range, text) in jobs {
                for m in checker.matches(in: text) { hits.append((NSRange(location: range.location + m.range.location, length: m.range.length), m)) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.styleCheckGeneration, let ts = self.textStorage else { return }
                ts.beginEditing()
                // 先清掉可见带内旧的标记
                for p in paras where p.location + p.length <= ts.length { self.clearStyleMarks(in: p) }
                for (r, m) in hits where r.location + r.length <= ts.length {
                    ts.addAttributes([.strikethroughStyle: Self.styleCheckStyle, .strikethroughColor: Self.styleCheckColor,
                                      .toolTip: Self.label(for: m.category)], range: r)
                }
                ts.endEditing()
            }
        }
    }

    static func label(for c: StyleChecker.Category) -> String {
        switch c {
        case .filler: return RL("文风：填充词，可删")
        case .redundancy: return RL("文风：冗余，留一个就够")
        case .cliche: return RL("文风：陈词滥调，换个说法")
        case .custom: return RL("文风：自定义规则")
        }
    }

    private func clearStyleMarks(in range: NSRange) {
        guard let ts = textStorage else { return }
        ts.enumerateAttribute(.strikethroughColor, in: range, options: []) { v, r, _ in
            if let c = v as? NSColor, c == Self.styleCheckColor {
                ts.removeAttribute(.strikethroughStyle, range: r); ts.removeAttribute(.strikethroughColor, range: r); ts.removeAttribute(.toolTip, range: r)
            }
        }
    }

    func clearAllStyleMarks() {
        guard let ts = textStorage else { return }
        ts.beginEditing(); clearStyleMarks(in: NSRange(location: 0, length: ts.length)); ts.endEditing()
    }
}
