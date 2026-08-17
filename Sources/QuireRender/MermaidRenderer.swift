import AppKit
import CryptoKit
import WebKit
import QuireCore

/// Mermaid 附件：源码 + 渲染状态。占位图 → 渲染完成后换成 SVG 图片（或错误框）。
public final class MermaidAttachment: NSTextAttachment {
    public let source: String
    public let mermaidTheme: String
    public var isRendered = false
    public var failed = false
    public var errorText: String?

    public init(source: String, mermaidTheme: String) {
        self.source = source
        self.mermaidTheme = mermaidTheme
        super.init(data: nil, ofType: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> NSImage? { image }
}

/// Mermaid 渲染缓存：内存（NSCache）+ 磁盘（~/Library/Caches/com.korako.quire/mermaid/<sha256>.png，2× 位图）。
public final class MermaidCache: @unchecked Sendable {
    public static let shared = MermaidCache()
    private let memory = NSCache<NSString, NSImage>()
    private let dir: URL
    private let queue = DispatchQueue(label: "com.korako.quire.mermaidcache", qos: .utility)
    public static let diskLimitBytes = 200 * 1024 * 1024

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("com.korako.quire/mermaid", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.totalCostLimit = 32 * 1024 * 1024
        queue.asyncAfter(deadline: .now() + 5) { [self] in trim() }
    }

    public static func key(source: String, theme: String) -> String {
        let d = SHA256.hash(data: Data("\(theme)|\(MermaidRenderer.mermaidVersion)|\(source)".utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }

    public func image(forKey key: String) -> NSImage? {
        if let i = memory.object(forKey: key as NSString) { return i }
        let url = dir.appendingPathComponent(key + ".png")
        guard let data = try? Data(contentsOf: url), let img = MermaidRenderer.image(fromPNG: data) else { return nil }
        memory.setObject(img, forKey: key as NSString, cost: data.count)
        // 触碰 mtime（LRU）
        queue.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        return img
    }

    public func store(png: Data, image: NSImage, forKey key: String) {
        memory.setObject(image, forKey: key as NSString, cost: png.count)
        let url = dir.appendingPathComponent(key + ".png")
        queue.async { try? png.write(to: url, options: .atomic) }
    }

    /// LRU 裁剪到上限
    func trim() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var entries = files.compactMap { u -> (URL, Date, Int)? in
            guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (u, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > Self.diskLimitBytes else { return }
        entries.sort { $0.1 < $1.1 }
        for e in entries where total > Self.diskLimitBytes {
            try? FileManager.default.removeItem(at: e.0); total -= e.2
        }
    }
}

/// 离屏 WKWebView 渲染 Mermaid → SVG → NSImage。全局单例；惰性创建；空闲 30 s 后销毁 WebView。
/// 这是 Quire 里唯一使用 WebKit 的地方（ADR-4）。
@MainActor
public final class MermaidRenderer: NSObject, WKNavigationDelegate {
    public static let shared = MermaidRenderer()
    public nonisolated static let mermaidVersion = "11.16.1"
    public static let idleTimeout: TimeInterval = 30

    public enum Failure: Error, CustomStringConvertible {
        case unavailable(String)
        case render(String)
        case decode
        public var description: String {
            switch self {
            case .unavailable(let m): "Mermaid 不可用：\(m)"
            case .render(let m): m
            case .decode: "SVG 解码失败"
            }
        }
    }

    private var webView: WKWebView?
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var idleTask: Task<Void, Never>?
    private var inflight = 0

    /// 打包资源里是否有 mermaid.min.js（构建时由 scripts/fetch_mermaid.sh 放入）
    public nonisolated static var isAvailable: Bool { resourceURL(for: "mermaid.min.js") != nil }
    nonisolated static func resourceURL(for name: String) -> URL? {
        guard let dir = Bundle.module.url(forResource: "Mermaid", withExtension: nil) else { return nil }
        let u = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 渲染倍率（Retina）
    public nonisolated static let rasterScale: CGFloat = 2

    /// 渲染（先查缓存）。返回 NSImage（2× 位图，size 为 pt）。串行执行（WebView 一次只放一张图）。
    public func render(source: String, theme: String, background: String = "transparent") async throws -> NSImage {
        let key = MermaidCache.key(source: source, theme: theme + "|" + background)
        if let cached = MermaidCache.shared.image(forKey: key) { return cached }
        // 排队：同一时刻只有一个渲染在用 stage
        while busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        busy = true
        inflight += 1
        defer { busy = false; inflight -= 1; scheduleIdle() }
        if let cached = MermaidCache.shared.image(forKey: key) { return cached }
        try await ensureReady()
        guard let webView else { throw Failure.unavailable("WebView 未创建") }
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript("return await quireRender(code, theme, font);",
                                                            arguments: ["code": source, "theme": theme, "font": "-apple-system, PingFang SC, Helvetica Neue, sans-serif"],
                                                            contentWorld: .page)
        } catch {
            throw Failure.render(error.localizedDescription)
        }
        guard let dict = result as? [String: Any] else { throw Failure.render("无返回") }
        if dict["ok"] as? Bool != true { throw Failure.render((dict["error"] as? String) ?? "未知错误") }
        var w = ((dict["width"] as? Double) ?? 0).rounded(.up), h = ((dict["height"] as? Double) ?? 0).rounded(.up)
        if w < 1 || h < 1 { w = 400; h = 200 }
        w = min(w, 4000); h = min(h, 4000)
        let k = Self.rasterScale
        _ = try? await webView.callAsyncJavaScript("return quireScale(k, w, h, bg);", arguments: ["k": k, "w": w, "h": h, "bg": background], contentWorld: .page)
        webView.frame = CGRect(x: 0, y: 0, width: w * k, height: h * k)
        // 给布局一帧
        try? await Task.sleep(nanoseconds: 16_000_000)
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: w * k, height: h * k)
        cfg.afterScreenUpdates = true
        let shot: NSImage
        do { shot = try await webView.takeSnapshot(configuration: cfg) } catch { throw Failure.render("截图失败：\(error.localizedDescription)") }
        _ = try? await webView.callAsyncJavaScript("return quireClear();", arguments: [:], contentWorld: .page)
        guard let tiff = shot.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw Failure.decode }
        guard let img = Self.image(fromPNG: png, pointSize: CGSize(width: w, height: h)) else { throw Failure.decode }
        MermaidCache.shared.store(png: png, image: img, forKey: key)
        return img
    }
    private var busy = false

    /// PNG（2× 像素）→ NSImage（pt 尺寸 = 像素 / rasterScale）
    nonisolated static func image(fromPNG data: Data, pointSize: CGSize? = nil) -> NSImage? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let size = pointSize ?? CGSize(width: CGFloat(rep.pixelsWide) / rasterScale, height: CGFloat(rep.pixelsHigh) / rasterScale)
        rep.size = size
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: - WebView 生命周期

    private func ensureReady() async throws {
        if ready, webView != nil { return }
        if webView == nil {
            guard let html = Self.resourceURL(for: "mermaid.html"), Self.resourceURL(for: "mermaid.min.js") != nil else {
                throw Failure.unavailable("缺少 mermaid.min.js，请运行 scripts/fetch_mermaid.sh 后重新构建")
            }
            let cfg = WKWebViewConfiguration()
            cfg.suppressesIncrementalRendering = true
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), configuration: cfg)
            wv.navigationDelegate = self
            wv.setValue(false, forKey: "drawsBackground")
            webView = wv
            ready = false
            wv.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            readyWaiters.append(c)
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        let w = readyWaiters; readyWaiters = []
        w.forEach { $0.resume() }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let w = readyWaiters; readyWaiters = []
        w.forEach { $0.resume(throwing: Failure.unavailable(error.localizedDescription)) }
        self.webView = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.inflight == 0 else { return }
            self.webView?.navigationDelegate = nil
            self.webView = nil
            self.ready = false
        }
    }

    /// 是否有存活的 WebView（测试 / 诊断）
    public var isWebViewAlive: Bool { webView != nil }
}
