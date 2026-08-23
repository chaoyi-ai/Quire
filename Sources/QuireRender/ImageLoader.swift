import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 图片附件：记录来源，图片异步加载后由 ImageLoader 填充。
public final class ImageAttachment: NSTextAttachment {
    public var source: String?
    public var altText: String = ""
    public var isInline = false
    public var isLoaded = false
    public var loadFailed = false

    static func placeholder(size: CGSize, alt: String, style: RenderStyle) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            style.codeBackground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            if rect.height > 30 {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: style.muted]
                let s = NSAttributedString(string: alt.isEmpty ? RL("图片") : alt, attributes: attrs)
                let sz = s.size()
                s.draw(at: CGPoint(x: (rect.width - sz.width) / 2, y: (rect.height - sz.height) / 2))
            }
            return true
        }
    }
}

/// 图片加载：磁盘 / 网络 → ImageIO 按目标像素宽度 downsample → NSCache。
/// 绝不把原图完整解码进内存。
public final class ImageLoader: @unchecked Sendable {
    public static let shared = ImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.korako.quire.imageloader", qos: .userInitiated, attributes: .concurrent)
    private let session: URLSession
    private var inflight: [String: [@Sendable (NSImage?) -> Void]] = [:]
    private let lock = NSLock()

    public init(memoryLimit: Int = 64 * 1024 * 1024) {
        cache.totalCostLimit = memoryLimit
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024, diskPath: "com.korako.quire.images")
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    /// 解析图片来源为 URL：绝对 URL / 相对当前文档目录的路径
    public static func resolve(_ source: String, relativeTo base: URL?) -> URL? {
        if let u = URL(string: source), let scheme = u.scheme, ["http", "https", "file", "data"].contains(scheme.lowercased()) { return u }
        let path = source.removingPercentEncoding ?? source
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        guard let base else { return nil }
        return URL(fileURLWithPath: path, relativeTo: base.deletingLastPathComponent()).standardizedFileURL
    }

    /// 异步加载并 downsample 到 `maxPixelWidth`（含 Retina 倍率）。回调在主线程。
    public func load(_ url: URL, maxPixelWidth: CGFloat, completion: @escaping @MainActor (NSImage?) -> Void) {
        let key = "\(url.absoluteString)@\(Int(maxPixelWidth))"
        // NSImage 本身线程安全（Apple 文档），但不是 Sendable：用盒子跨过 Swift 6.1 的严格检查
        let deliver: @Sendable (NSImage?) -> Void = { img in
            let boxed = UncheckedSendable(img)
            Task { @MainActor in completion(boxed.value) }
        }
        if let img = cache.object(forKey: key as NSString) { deliver(img); return }

        lock.lock()
        if inflight[key] != nil {
            inflight[key]!.append(deliver)
            lock.unlock(); return
        }
        inflight[key] = [deliver]
        lock.unlock()

        let finish: @Sendable (NSImage?) -> Void = { [weak self] img in
            guard let self else { return }
            if let img { self.cache.setObject(img, forKey: key as NSString, cost: Int(img.size.width * img.size.height * 4)) }
            self.lock.lock(); let cbs = self.inflight.removeValue(forKey: key) ?? []; self.lock.unlock()
            cbs.forEach { $0(img) }
        }

        if url.isFileURL {
            queue.async { finish(Self.decode(url: url, maxPixelWidth: maxPixelWidth)) }
        } else if url.scheme == "data" {
            queue.async {
                guard let data = try? Data(contentsOf: url) else { return finish(nil) }
                finish(Self.decode(data: data, maxPixelWidth: maxPixelWidth))
            }
        } else {
            session.dataTask(with: url) { data, _, _ in
                guard let data else { return finish(nil) }
                finish(Self.decode(data: data, maxPixelWidth: maxPixelWidth))
            }.resume()
        }
    }

    static func decode(url: URL, maxPixelWidth: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source: src, maxPixelWidth: maxPixelWidth) ?? NSImage(contentsOf: url) // SVG 等 ImageIO 不支持的走 NSImage
    }
    static func decode(data: Data, maxPixelWidth: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return NSImage(data: data) }
        return decode(source: src, maxPixelWidth: maxPixelWidth) ?? NSImage(data: data)
    }
    static func decode(source: CGImageSource, maxPixelWidth: CGFloat) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelWidth),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        // 原始像素尺寸（用于按 pt 展示）
        var pointSize = CGSize(width: cg.width, height: cg.height)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0 {
            let dpi = (props[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
            let scale = max(1, dpi / 72)
            let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
            let swapped = orientation >= 5
            pointSize = CGSize(width: (swapped ? h : w) / scale, height: (swapped ? w : h) / scale)
        }
        let img = NSImage(cgImage: cg, size: pointSize)
        return img
    }
}

/// 跨隔离域传递已知线程安全但未标记 Sendable 的对象
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}
