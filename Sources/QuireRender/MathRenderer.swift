import AppKit
import SwiftMath

/// LaTeX 数学 → NSImage（SwiftMath：iosMath 的 Swift 移植，CoreText + Latin Modern Math，不用 WebView）。
/// 同步、线程安全（渲染线程上直接调用，0.3 ms / 式）；按 (latex, 字号, 颜色, 行内/独立) 缓存。
public enum MathRenderer {
    public struct Result: Sendable {
        public let image: UncheckedSendable<NSImage>
        public let ascent: CGFloat
        public let descent: CGFloat
    }
    public struct UncheckedSendable<T>: @unchecked Sendable { public let value: T; init(_ v: T) { value = v } }

    // NSCache 本身线程安全
    nonisolated(unsafe) private static let cache: NSCache<NSString, CacheBox> = { let c = NSCache<NSString, CacheBox>(); c.countLimit = 2000; return c }()
    private final class CacheBox { let result: Result; init(_ r: Result) { result = r } }

    /// 失败返回 nil（调用方显示源码 + 错误）；`error` 给出 SwiftMath 的错误描述
    public static func render(_ latex: String, fontSize: CGFloat, color: NSColor, display: Bool, error: inout String?) -> Result? {
        let c = color.usingColorSpace(.sRGB) ?? color
        let key = "\(display ? "D" : "I")|\(fontSize)|\(Int(c.redComponent * 255)),\(Int(c.greenComponent * 255)),\(Int(c.blueComponent * 255))|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.result }
        var img = MathImage(latex: latex, fontSize: fontSize, textColor: color, labelMode: display ? .display : .text, textAlignment: .center)
        let (err, image, info) = img.asImage()
        guard err == nil, let image, let info else { error = err?.localizedDescription ?? "render failed"; return nil }
        let r = Result(image: UncheckedSendable(image), ascent: info.ascent, descent: info.descent)
        cache.setObject(CacheBox(r), forKey: key)
        return r
    }
}

/// 数学附件：块级居中一行；行内按基线对齐（bounds.y = -descent）
public final class MathAttachment: NSTextAttachment {
    public let latex: String
    public let isDisplay: Bool
    public init(latex: String, isDisplay: Bool) {
        self.latex = latex; self.isDisplay = isDisplay
        super.init(data: nil, ofType: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
