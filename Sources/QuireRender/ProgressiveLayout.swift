import AppKit

/// 渐进式全文排版。TextKit 2 只排视口附近，其余高度是估算的（1 MB 文档估 307k pt、实际 844k），快速滚动时估算不断被
/// 真实高度替换，文档总高一直变，滚动条就跳来跳去。首帧之后在主线程空闲时分批 `ensureLayout`（每批自适应到 ~12 ms），
/// 每批后把 frame 高度推到 `usageBoundsForTextContainer`——NSTextView 只在视口排版时自己长高，视口外的排版它不管。
/// 阅读视图与编辑器共用（两个都是 TextKit 2 的 NSTextView）。
@MainActor
final class ProgressiveLayout {
    private weak var textView: NSTextView?
    private var generation = 0
    private(set) var isComplete = false

    init(textView: NSTextView) { self.textView = textView }

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
            let t0 = DispatchTime.now().uptimeNanoseconds
            if let r = NSTextRange(location: start, end: end) { tlm.ensureLayout(for: r) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            if ms > 20 { chunk = max(2_000, chunk / 2) } else if ms < 6 { chunk = min(128_000, chunk * 2) }
            next = endOffset
            self.syncFrameHeight()
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

    /// 把 frame 高度对齐到排版用量（NSTextView 自己的算法：用量高 + 上下 inset）
    func syncFrameHeight() {
        guard let tv = textView, let tlm = tv.textLayoutManager else { return }
        let h = (tlm.usageBoundsForTextContainer.height + tv.textContainerInset.height * 2).rounded(.up)
        if abs(h - tv.frame.height) > 1 { tv.setFrameSize(NSSize(width: tv.frame.width, height: h)) }
    }
}
