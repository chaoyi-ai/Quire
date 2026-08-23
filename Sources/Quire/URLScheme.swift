import AppKit
import QuireCore
import QuireRender

/// `quire://` URL scheme（#82）：给 Shortcuts / 其他 App / 命令行用。
///
/// - `quire://open?path=/abs/file.md&line=12`   打开（也可以是文件夹）
/// - `quire://new?text=…&path=/abs/new.md`        新建（path 可省 = 未命名）
/// - `quire://append?path=/abs/file.md&text=…`   追加文本到文件末尾（已打开的文档直接改内容并保存）
/// - `quire://export?path=/abs/file.md&to=/abs/out.pdf&format=pdf|html`
///
/// 安全：路径必须是绝对路径（可 `~`）；来自外部的请求，除非目标落在已打开的侧栏根目录 / 已打开文档所在目录里，否则先弹确认。
@MainActor
enum URLScheme {
    static let scheme = "quire"

    static func isSchemeURL(_ url: URL) -> Bool { url.scheme?.lowercased() == scheme }

    static func handle(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let action = (comps.host ?? "").lowercased()
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name.lowercased()] = item.value ?? "" }
        switch action {
        case "open": open(q)
        case "new": new(q)
        case "append": append(q)
        case "export": export(q)
        default: fail(String(format: L("不认识的 quire:// 动作：%@"), action.isEmpty ? "(空)" : action))
        }
    }

    // MARK: - 动作

    private static func open(_ q: [String: String]) {
        guard let url = path(q["path"]) else { return fail(L("缺少 path 参数（必须是绝对路径）")) }
        openFile(url, line: Int(q["line"] ?? ""), external: true)
    }

    /// 打开文件 / 文件夹，可跳行；`external` = 来自外部（不在已打开目录内时先确认）
    static func openFile(_ url: URL, line: Int?, external: Bool, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !external || trusted(url) || confirm(String(format: L("外部应用请求打开：%@"), url.path), button: L("打开")) else { completion?(false); return }
        QuireDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            if let error { NSApp.presentError(error); completion?(false); return }
            if let line, let wc = doc?.windowControllers.first as? DocumentWindowController {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { wc.jump(toLine: line) }
            }
            completion?(true)
        }
    }

    private static func new(_ q: [String: String]) {
        newDocument(text: q["text"] ?? "", at: path(q["path"]), external: true)
    }

    static func newDocument(text: String, at url: URL?, external: Bool) {
        if let url {
            guard !external || trusted(url) || confirm(String(format: L("外部应用请求新建文件：%@"), url.path), button: L("新建")) else { return }
            guard !FileManager.default.fileExists(atPath: url.path) else { return fail(String(format: L("文件已存在：%@"), url.path)) }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch { NSApp.presentError(error); return }
            QuireDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in if let error { NSApp.presentError(error) } }
            return
        }
        do {
            let doc = try QuireDocumentController.shared.openUntitledDocumentAndDisplay(true)
            if !text.isEmpty, let md = doc as? MarkdownDocument { md.replaceContents(text) }
        } catch { NSApp.presentError(error) }
    }

    private static func append(_ q: [String: String]) {
        guard let url = path(q["path"]) else { return fail(L("缺少 path 参数（必须是绝对路径）")) }
        let text = q["text"] ?? ""
        guard !text.isEmpty else { return fail(L("缺少 text 参数")) }
        appendText(text, to: url, external: true)
    }

    /// 追加到文件末尾；已打开的文档直接改内容并保存
    @discardableResult
    static func appendText(_ text: String, to url: URL, external: Bool) -> Bool {
        guard !external || trusted(url) || confirm(String(format: L("外部应用请求在文件末尾追加 %d 个字符：%@"), text.count, url.path), button: L("追加")) else { return false }
        if let doc = QuireDocumentController.shared.document(for: url) as? MarkdownDocument {
            var s = doc.source
            if !s.isEmpty, !s.hasSuffix("\n") { s += "\n" }
            doc.replaceContents(s + text)
            doc.save(nil)
            return true
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forUpdating: url)
                let size = try h.seekToEnd()
                var prefix = ""
                if size > 0 {
                    try h.seek(toOffset: size - 1)
                    if let last = try h.read(upToCount: 1), last != Data([0x0A]) { prefix = "\n" }
                    _ = try h.seekToEnd()
                }
                try h.write(contentsOf: (prefix + text).data(using: .utf8)!)
                try h.close()
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            return true
        } catch { NSApp.presentError(error); return false }
    }

    private static func export(_ q: [String: String]) {
        guard let url = path(q["path"]) else { return fail(L("缺少 path 参数（必须是绝对路径）")) }
        let format = (q["format"] ?? (q["to"].map { ($0 as NSString).pathExtension.lowercased() } ?? "pdf")).lowercased()
        guard format == "pdf" || format == "html" else { return fail(String(format: L("不支持的导出格式：%@"), format)) }
        let to = path(q["to"]) ?? url.deletingPathExtension().appendingPathExtension(format)
        exportDocument(url, to: to, format: format, external: true, completion: nil)
    }

    /// 打开（或复用已打开的）文档，等渲染完成后导出 PDF / HTML
    static func exportDocument(_ url: URL, to: URL, format: String, external: Bool, completion: (@MainActor (Bool) -> Void)?) {
        guard !external || trusted(url) && trusted(to) || confirm(String(format: L("外部应用请求导出：%@ → %@"), url.path, to.path), button: L("导出")) else { completion?(false); return }
        QuireDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            if let error { NSApp.presentError(error); completion?(false); return }
            guard let md = doc as? MarkdownDocument, let wc = md.windowControllers.first as? DocumentWindowController else { completion?(false); return }
            waitForRender(md, attempts: 40) {
                var ok = true
                if format == "html" {
                    var opts = HTMLRenderer.Options(); opts.title = md.displayName
                    let html = HTMLRenderer(theme: ThemeManager.shared.currentTheme, options: opts).render(md.session.parsed)
                    do { try html.write(to: to, atomically: true, encoding: .utf8) } catch { NSApp.presentError(error); ok = false }
                } else {
                    ok = Exporter.writePDF(document: md, windowController: wc, to: to)
                    if !ok { fail(String(format: L("导出失败：%@"), to.path)) }
                }
                completion?(ok)
            }
        }
    }

    private static func waitForRender(_ doc: MarkdownDocument, attempts: Int, then: @escaping @MainActor () -> Void) {
        if doc.session.rendered != nil || attempts <= 0 { then(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitForRender(doc, attempts: attempts - 1, then: then) }
    }

    // MARK: - 工具

    /// 绝对路径或 `~` 开头；其他一律拒绝
    static func path(_ s: String?) -> URL? {
        guard var p = s?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        guard p.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: (p as NSString).standardizingPath)
    }

    /// 落在已打开的侧栏根目录或已打开文档所在目录内（含文档本身）→ 不用确认
    static func trusted(_ url: URL) -> Bool {
        let p = canonical(url)
        var dirs: [String] = []
        for doc in NSDocumentController.shared.documents {
            if let wc = doc.windowControllers.first as? DocumentWindowController, let root = wc.sidebarViewController.rootURL { dirs.append(canonical(root)) }
            if let f = doc.fileURL { dirs.append(canonical(f.deletingLastPathComponent())) }
        }
        return dirs.contains { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// 规范路径：目录部分解析符号链接（`/private/tmp` 与 `/tmp` 归一；Foundation 对不存在的文件不剥 `/private`，所以只解析父目录）
    private static func canonical(_ url: URL) -> String {
        if FileManager.default.fileExists(atPath: url.path) { return url.resolvingSymlinksInPath().standardizedFileURL.path }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        return (parent as NSString).appendingPathComponent(url.lastPathComponent)
    }

    private static func confirm(_ message: String, button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("来自外部的 quire:// 请求")
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: button)
        a.addButton(withTitle: L("取消"))
        return a.runModal() == .alertFirstButtonReturn
    }

    private static func fail(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = L("quire:// 请求无法处理"); a.informativeText = message; a.runModal()
    }
}
