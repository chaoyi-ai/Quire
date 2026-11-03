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
            if let line, let md = doc as? MarkdownDocument {
                md.session.whenRendered { ok in if ok { md.workspace?.jump(md, toLine: line) } }
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
        if let doc = QuireDocumentController.shared.document(for: QuireDocumentController.followingSymlink(url)) as? MarkdownDocument {
            // 文档开着 sheet 时存不了：save 要等 sheet 答完，主线程一等 sheet 就再也答不了
            guard doc.windowForSheet?.attachedSheet == nil else { NSSound.beep(); return false }
            var s = doc.source
            if !s.isEmpty, !s.hasSuffix("\n") { s += "\n" }
            doc.replaceContents(s + text)
            doc.save(nil)
            return true
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try appendToClosedFile(text, at: url)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            return true
        } catch { NSApp.presentError(error); return false }
    }

    /// 往没打开的文件追加：用打开文件时的解码器判断编码，按原编码只写新文字，旧字节一个不动。
    /// 原编码装不下，或者追加之后读回来不是这些字（会被认成别的编码）：和已打开的文档存储时一样，整个文件改存 UTF-8，不留混合编码
    static func appendToClosedFile(_ text: String, at url: URL) throws {
        // 先拿写权限：只读、锁定的文件在这里就报错，不靠下面的替换来拦（macOS 27 的 replaceItemAt 也会拒绝，旧系统没验证；.atomic 写不拒绝，rename 只看目录）
        let h = try FileHandle(forUpdating: url)
        let data = try h.readToEnd() ?? Data()
        guard let old = MarkdownDocument.decode(data) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownStringEncodingError, userInfo: [NSLocalizedDescriptionKey: L("无法识别文件编码")])
        }
        // 按字节比：Swift 把 "\r\n" 当一个字符，hasSuffix("\n") 不成立
        let endsLine = old.text.isEmpty || old.text.utf8.last == 0x0A
        let tail = endsLine ? text : "\n" + text
        let whole = old.text + tail
        // decode 说的 .utf16 不分字节序，直接编码还会再写一个 BOM：字节序看文件开头
        var encoding = old.encoding
        if encoding == .utf16 { encoding = data.starts(with: [0xFE, 0xFF]) ? .utf16BigEndian : .utf16LittleEndian }
        if let bytes = tail.data(using: encoding), MarkdownDocument.decode(data + bytes)?.text == whole {
            _ = try h.seekToEnd()
            try h.write(contentsOf: bytes)
            try h.close()
            return
        }
        try h.close()
        // 真文件的路径：replaceItemAt 对符号链接报 ENOENT，.atomic 写会把链接换成普通文件、真文件不动。权限、扩展属性由 replaceItemAt 带过去
        let target = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: dir) }
        let replacement = dir.appendingPathComponent(target.lastPathComponent)
        try Data(whole.utf8).write(to: replacement)
        _ = try fm.replaceItemAt(target, withItemAt: replacement)
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
            guard let md = doc as? MarkdownDocument, md.workspace != nil else { completion?(false); return }
            md.session.whenRendered { rendered in
                guard rendered else { fail(String(format: L("导出失败：%@"), to.path)); completion?(false); return }
                Task { @MainActor in
                    var ok = true
                    if format == "html" {
                        do { try Exporter.html(for: md).write(to: to, atomically: true, encoding: .utf8) } catch { NSApp.presentError(error); ok = false }
                    } else {
                        ok = await Exporter.writePDF(document: md, to: to)
                        if !ok { fail(String(format: L("导出失败：%@"), to.path)) }
                    }
                    completion?(ok)
                }
            }
        }
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
            if let root = (doc as? MarkdownDocument)?.workspace?.rootURL { dirs.append(canonical(root)) }
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
