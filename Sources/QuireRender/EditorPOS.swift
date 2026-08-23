import AppKit
import NaturalLanguage

/// 词性高亮（iA Writer 式 Syntax Highlight）：名 / 动 / 形 / 副 / 连 各一色，或只看一类。
/// 全部本地（NaturalLanguage.NLTagger）、只处理可见段落 ± 一屏、后台分词、主线程只改颜色、不改文本。
/// 评估：NLTagger 对 zh-Hans 的 lexicalClass 全部返回 OtherWord（只能分词不能分词性），所以中文段落不着色；英 / 德 / 法 / 意 / 西 可用。
public enum POSMode: Int, CaseIterable, Sendable {
    case off = 0, all, nouns, verbs, adjectives, adverbs, conjunctions
}

extension EditorTextView {
    /// 词性 → 颜色（系统色，深浅色都清楚）
    nonisolated static func posColor(_ tag: NLTag, mode: POSMode) -> NSColor? {
        switch tag {
        case .noun, .personalName, .placeName, .organizationName: return mode == .all || mode == .nouns ? .systemBlue : nil
        case .verb: return mode == .all || mode == .verbs ? .systemRed : nil
        case .adjective: return mode == .all || mode == .adjectives ? .systemGreen : nil
        case .adverb: return mode == .all || mode == .adverbs ? .systemOrange : nil
        case .conjunction, .preposition: return mode == .all || mode == .conjunctions ? .systemPurple : nil
        case .pronoun, .determiner: return mode == .all ? .systemTeal : nil
        default: return nil
        }
    }

    /// 可见段落（± 一屏）重新着色；编辑 / 滚动后由调用方防抖触发
    func recolorPOSVisible() {
        guard posMode != .off, let ts = textStorage, let sv = enclosingScrollView else { return }
        let visible = sv.contentView.bounds
        let band = visible.insetBy(dx: 0, dy: -visible.height)
        guard let tlm = textLayoutManager, let cs = textContentStorage,
              let startFrag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, band.minY - textContainerInset.height))) else { return }
        var paragraphs: [NSRange] = []
        tlm.enumerateTextLayoutFragments(from: startFrag.rangeInElement.location, options: [.ensuresLayout]) { frag in
            if frag.layoutFragmentFrame.minY + self.textContainerInset.height > band.maxY { return false }
            let start = cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location)
            let len = cs.offset(from: frag.rangeInElement.location, to: frag.rangeInElement.endLocation)
            paragraphs.append(NSRange(location: start, length: len))
            return true
        }
        let ns = ts.string as NSString
        let mode = posMode
        let codeColor = style.theme.colors.editor.markdownCode.nsColor
        var jobs: [(NSRange, String)] = []
        for p in paragraphs where p.length > 1 {
            // 跳过代码块 / front matter（首字符已是代码色）与纯标记行
            if let c = ts.attribute(.foregroundColor, at: p.location, effectiveRange: nil) as? NSColor, c == codeColor { continue }
            jobs.append((p, ns.substring(with: p)))
        }
        guard !jobs.isEmpty else { return }
        let generation = posGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [(NSRange, [(NSRange, NSColor)])] = []
            for (range, text) in jobs {
                guard let lang = NLLanguageRecognizer.dominantLanguage(for: text), Self.posSupported.contains(lang) else { continue }
                let tagger = NLTagger(tagSchemes: [.lexicalClass])
                tagger.string = text
                var words: [(NSRange, NSColor)] = []
                tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, r in
                    if let tag, let color = Self.posColor(tag, mode: mode) {
                        let nr = NSRange(r, in: text)
                        words.append((NSRange(location: range.location + nr.location, length: nr.length), color))
                    }
                    return true
                }
                results.append((range, words))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.posGeneration, self.posMode == mode, let ts = self.textStorage else { return }
                let plain = self.style.foreground
                ts.beginEditing()
                for (_, words) in results {
                    for (r, color) in words where r.location + r.length <= ts.length {
                        // 只给正文色的字着色：标记 / 代码 / 链接 保持原色
                        if let cur = ts.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor, cur == plain || Self.isPOSColor(cur) {
                            ts.addAttribute(.foregroundColor, value: color, range: r)
                        }
                    }
                }
                ts.endEditing()
            }
        }
    }

    nonisolated static let posSupported: Set<NLLanguage> = [.english, .german, .french, .italian, .spanish, .portuguese, .russian, .dutch]
    nonisolated static func isPOSColor(_ c: NSColor) -> Bool { [NSColor.systemBlue, .systemRed, .systemGreen, .systemOrange, .systemPurple, .systemTeal].contains(c) }

    /// 关闭 / 切换时把可见区恢复成普通高亮
    func clearPOSColors() {
        guard let ts = textStorage else { return }
        let full = NSRange(location: 0, length: ts.length)
        var dirty: [NSRange] = []
        ts.enumerateAttribute(.foregroundColor, in: full, options: [.longestEffectiveRangeNotRequired]) { v, r, _ in
            if let c = v as? NSColor, Self.isPOSColor(c) { dirty.append(r) }
        }
        guard !dirty.isEmpty else { return }
        ts.beginEditing()
        for r in dirty { ts.addAttribute(.foregroundColor, value: style.foreground, range: r) }
        ts.endEditing()
    }

    public func schedulePOSRecolor(delay: TimeInterval = 0.25) {
        guard posMode != .off else { return }
        posWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.recolorPOSVisible() }
        posWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}
