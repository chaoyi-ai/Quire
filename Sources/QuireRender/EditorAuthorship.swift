import AppKit

/// 著作归属的着色：按作者给区间铺一层半透明底色。只处理可见段落 ± 一屏（大文档里区间可能上千）；
/// 语法高亮会重置段落属性，所以编辑后对该段重新铺一次（见 willProcessEditing）。
extension EditorTextView {
    /// `range` 为 nil = 可见带
    func applyAuthorshipColors(in range: NSRange? = nil) {
        guard let ts = textStorage, ts.length > 0 else { return }
        let target = range ?? visibleBand()
        guard target.length > 0 else { return }
        let spans = authorshipSpans
        // 二分到第一个可能相交的区间
        var lo = 0, hi = spans.count
        while lo < hi { let mid = (lo + hi) / 2; if spans[mid].range.location + spans[mid].range.length <= target.location { lo = mid + 1 } else { hi = mid } }
        ts.beginEditing()
        ts.removeAttribute(.backgroundColor, range: target)
        var i = lo
        while i < spans.count, spans[i].range.location < target.location + target.length {
            let r = NSIntersectionRange(spans[i].range, target)
            if r.length > 0, r.location + r.length <= ts.length { ts.addAttribute(.backgroundColor, value: spans[i].color, range: r) }
            i += 1
        }
        ts.endEditing()
    }

    /// 滚动后补铺新进入视口的区间（底色只铺可见带 ± 一屏）
    public func scheduleAuthorshipRepaint(delay: TimeInterval = 0.1) {
        guard showsAuthorship, !authorshipSpans.isEmpty else { return }
        authorshipRepaintWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.applyAuthorshipColors() }
        authorshipRepaintWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func clearAuthorshipColors() {
        guard let ts = textStorage, ts.length > 0 else { return }
        ts.beginEditing(); ts.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: ts.length)); ts.endEditing()
    }

    /// 可见区域 ± 一屏对应的字符范围（按段落对齐）
    func visibleBand() -> NSRange {
        guard let ts = textStorage, let sv = enclosingScrollView, let tlm = textLayoutManager, let cs = textContentStorage else { return NSRange(location: 0, length: textStorage?.length ?? 0) }
        let visible = sv.contentView.bounds
        let band = visible.insetBy(dx: 0, dy: -visible.height)
        guard let startFrag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, band.minY - textContainerInset.height))) else { return NSRange(location: 0, length: ts.length) }
        let start = cs.offset(from: cs.documentRange.location, to: startFrag.rangeInElement.location)
        var end = start
        tlm.enumerateTextLayoutFragments(from: startFrag.rangeInElement.location, options: [.ensuresLayout]) { frag in
            end = cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.endLocation)
            return frag.layoutFragmentFrame.minY + self.textContainerInset.height <= band.maxY
        }
        return NSRange(location: start, length: max(0, min(end, ts.length) - start))
    }
}
