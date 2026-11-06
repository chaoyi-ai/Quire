import AppKit

/// 渐进式全文排版。TextKit 2 只排视口附近，其余高度是估算的（1 MB 文档估 307k pt、实际 844k），快速滚动时估算不断被
/// 真实高度替换，文档总高一直变，滚动条就跳来跳去。首帧之后在主线程空闲时分批 `ensureLayout`（每批自适应到 ~12 ms），
/// 每批后把 frame 高度推到 `usageBoundsForTextContainer`——NSTextView 只在视口排版时自己长高，视口外的排版它不管。
/// `anchorsTop`（只有阅读视图开）：每批前后按可见区顶部片段的字符位置把滚动位置对回去：上面的估算高度换成真实高度时，滚动 y 不动的话内容就从眼前错开
///（重载后滚到第 120 节，排完停在第 89 节）。放回去之前先排一次视口，frame 才是真实高度（见 `restoreTop`）。编辑器不开，行为同 0.10.3。
/// 阅读视图与编辑器共用（两个都是 TextKit 2 的 NSTextView）。
@MainActor
final class ProgressiveLayout {
    private weak var textView: NSTextView?
    private let anchorsTop: Bool
    private var generation = 0
    private(set) var isComplete = false

    init(textView: NSTextView, anchorsTop: Bool = false) { self.textView = textView; self.anchorsTop = anchorsTop }

    func cancel() { generation += 1; isComplete = false }

    func start(delay: TimeInterval = 0.3) {
        generation += 1
        isComplete = false
        let gen = generation
        var chunk = 16_000
        var next = 0
        func step() {
            guard gen == self.generation, let tv = self.textView, let tlm = tv.textLayoutManager, let cs = tv.textContentStorage else { return }
            let totalLen = cs.offset(from: cs.documentRange.location, to: cs.documentRange.endLocation)
            guard next < totalLen, let start = cs.location(cs.documentRange.location, offsetBy: next) else { self.finish(); return }
            let endOffset = min(totalLen, next + chunk)
            let end = cs.location(cs.documentRange.location, offsetBy: endOffset) ?? cs.documentRange.endLocation
            let anchor = self.anchorsTop ? self.captureTop() : nil
            let t0 = DispatchTime.now().uptimeNanoseconds
            if let r = NSTextRange(location: start, end: end) { tlm.ensureLayout(for: r) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            if ms > 20 { chunk = max(2_000, chunk / 2) } else if ms < 6 { chunk = min(128_000, chunk * 2) }
            next = endOffset
            self.syncFrameHeight()
            if let anchor { self.restoreTop(anchor) }
            if next < totalLen { DispatchQueue.main.async(execute: step) } else { self.finish() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
    }

    /// 排完之后 TextKit 仍可能因为容器宽度 / 属性变化整体失效（高度又变回估算）。滚动时调一下：看文末片段是不是真排好了，不是就重来
    func revalidate() {
        guard isComplete, let tv = textView, let tlm = tv.textLayoutManager, let cs = tv.textContentStorage else { return }
        let total = cs.offset(from: cs.documentRange.location, to: cs.documentRange.endLocation)
        guard total > 0, let last = cs.location(cs.documentRange.location, offsetBy: max(0, total - 1)) else { return }
        if tlm.textLayoutFragment(for: last)?.state != .layoutAvailable { start(delay: 0.2) }
    }

    private func finish() {
        isComplete = true
        syncFrameHeight()
    }

    /// 可见区顶部片段的字符偏移，和片段顶到可见区顶的距离（片段顶在可见区顶上面为负）
    private struct TopAnchor { var offset: Int; var dy: CGFloat }
    /// 可见区顶部的片段。从视口开始找：视口里的片段是排好的，估算区的片段位置不可信（ADR-13）
    private func captureTop() -> TopAnchor? {
        guard let tv = textView, let tlm = tv.textLayoutManager, let cs = tv.textContentStorage, let sv = tv.enclosingScrollView,
              let vr = tlm.textViewportLayoutController.viewportRange else { return nil }
        let top = sv.contentView.bounds.minY + sv.contentInsets.top - tv.textContainerInset.height
        var hit: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: vr.location, options: []) { f in
            if f.layoutFragmentFrame.maxY > top { hit = f }
            return hit == nil
        }
        guard let hit else { return nil }
        return TopAnchor(offset: cs.offset(from: cs.documentRange.location, to: hit.rangeInElement.location), dy: hit.layoutFragmentFrame.minY - top)
    }

    /// 把锚点片段放回原来离可见区顶的距离
    private func restoreTop(_ anchor: TopAnchor) {
        guard let tv = textView, let tlm = tv.textLayoutManager, let cs = tv.textContentStorage, let sv = tv.enclosingScrollView,
              let loc = cs.location(cs.documentRange.location, offsetBy: anchor.offset), let frag = tlm.textLayoutFragment(for: loc) else { return }
        // 排好的高度要等视口排一次才进用量（frame 也是这时才长高）。不排的话 frame 还是估算的高度：文档后部的目标 y 超过估算的文档底被夹住，
        // 下一批从夹住的位置取锚点，就再也回不去了（只放回、不排视口时，文档后四分之一重载：第 170 节 → 第 129 节）
        tlm.textViewportLayoutController.layoutViewport()
        let clip = sv.contentView
        clip.setBoundsOrigin(CGPoint(x: clip.bounds.minX, y: frag.layoutFragmentFrame.minY - anchor.dy + tv.textContainerInset.height - sv.contentInsets.top))
    }

    /// 把 frame 高度对齐到排版用量（NSTextView 自己的算法：用量高 + 上下 inset）
    func syncFrameHeight() {
        guard let tv = textView, let tlm = tv.textLayoutManager else { return }
        let h = (tlm.usageBoundsForTextContainer.height + tv.textContainerInset.height * 2).rounded(.up)
        if abs(h - tv.frame.height) > 1 { tv.setFrameSize(NSSize(width: tv.frame.width, height: h)) }
    }
}
