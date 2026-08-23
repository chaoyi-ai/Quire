import AppKit
import UniformTypeIdentifiers
import QuireCore
import QuireRender

/// 文档控制器：无 Info.plist（`swift run` 开发态）时也能识别 .md 并映射到 MarkdownDocument。
@MainActor
final class QuireDocumentController: NSDocumentController {
    static let markdownType = "net.daringfireball.markdown"
    nonisolated static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "txt", "text"]

    override func typeForContents(of url: URL) throws -> String {
        LaunchClock.mark("typeForContents")
        if Self.markdownExtensions.contains(url.pathExtension.lowercased()) { return Self.markdownType }
        if let t = try? super.typeForContents(of: url) { return t }
        return Self.markdownType
    }

    override func documentClass(forType typeName: String) -> AnyClass? {
        MarkdownDocument.self
    }

    override var defaultType: String? { Self.markdownType }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        openPanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText, UTType("net.daringfireball.markdown") ?? .plainText]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = true   // 选文件夹 = 以它为侧栏根打开
        openPanel.message = L("选择 Markdown 文件，或选一个文件夹作为工作目录")
        return super.runModalOpenPanel(openPanel, forTypes: types)
    }

    /// 文件夹走 `openFolder`，其余照常（打开面板、Dock 拖放、`open -a`、服务菜单都经这里）
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            openFolder(url, completionHandler: completionHandler)
            return
        }
        super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
    }

    /// 打开文件夹：优先 README.md / index.md，否则第一个 Markdown；都没有就新建一篇并把侧栏根设为该文件夹
    func openFolder(_ folder: URL, completionHandler: ((NSDocument?, Bool, (any Error)?) -> Void)? = nil) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        let mds = items.filter { Self.markdownExtensions.contains($0.pathExtension.lowercased()) && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let preferred = mds.first { ["readme.md", "index.md", "readme.markdown"].contains($0.lastPathComponent.lowercased()) } ?? mds.first
        let setRoot: (NSDocument?) -> Void = { doc in
            (doc?.windowControllers.first as? DocumentWindowController)?.sidebarViewController.setRoot(folder)
        }
        if let preferred {
            super.openDocument(withContentsOf: preferred, display: true) { doc, already, error in
                setRoot(doc)
                completionHandler?(doc, already, error)
            }
        } else {
            do {
                let doc = try openUntitledDocumentAndDisplay(true)
                setRoot(doc)
                completionHandler?(doc, false, nil)
            } catch { completionHandler?(nil, false, error) }
        }
    }
}

/// Markdown 文档：读 / 写 / 自动保存；源码变化通过 DocumentSession 驱动渲染。
struct UncheckedSendableBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

final class MarkdownDocument: NSDocument {
    /// 原始源码（编辑器与磁盘的唯一真相）。NSDocument.read(from:) 在 SDK 里是 nonisolated（实际主线程调用），故 unsafe 标注
    nonisolated(unsafe) private(set) var source: String = ""
    nonisolated(unsafe) private(set) var encoding: String.Encoding = .utf8
    /// 新建文档默认进入分栏
    nonisolated(unsafe) var isNewDocument = false
    /// 渲染会话（解析 / 渲染 / 监控），窗口控制器持有 UI
    private(set) lazy var session = DocumentSession(document: self)
    /// 著作归属（文件尾注释块）；nil = 这份文件没有。`source` 永远是去掉注释块的正文
    nonisolated(unsafe) var authorship: Authorship?
    /// 读入时注释块的哈希对不上（正文被外部改过）→ 打开后提示一次
    nonisolated(unsafe) var authorshipMismatch = false
    /// 下一次粘贴用的作者（"以作者粘贴"一次性覆盖）
    var nextPasteAuthor: String?

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { [QuireDocumentController.markdownType, "public.plain-text", "public.text"] }
    override class var writableTypes: [String] { [QuireDocumentController.markdownType, "public.plain-text"] }
    override class func isNativeType(_ type: String) -> Bool { type == QuireDocumentController.markdownType }

    override init() {
        super.init()
        isNewDocument = true
        LaunchClock.mark("document init")
    }

    override func makeWindowControllers() {
        LaunchClock.mark("makeWindowControllers begin")
        addWindowController(DocumentWindowController(document: self))
        LaunchClock.mark("makeWindowControllers end")
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? { "md" }

    override func read(from data: Data, ofType typeName: String) throws {
        // UTF-8 优先；失败退回 UTF-16 / GB18030 / Latin-1（不静默丢字）
        if let s = String(data: data, encoding: .utf8) { source = s; encoding = .utf8 }
        else if let s = String(data: data, encoding: .utf16) { source = s; encoding = .utf16 }
        else {
            let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { source = s; encoding = String.Encoding(rawValue: gb) }
            else if let s = String(data: data, encoding: .isoLatin1) { source = s; encoding = .isoLatin1 }
            else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownStringEncodingError, userInfo: [NSLocalizedDescriptionKey: L("无法识别文件编码")]) }
        }
        splitAuthorship()
        isNewDocument = false
        let src = source
        LaunchClock.mark("file read (\(data.count) bytes)")
        MainActor.assumeIsolated {
            session.sourceDidChange(src, reason: .opened)
            (windowControllers.first as? DocumentWindowController)?.documentDidReload(src)
        }
    }

    /// 把文件尾的著作归属注释块从 `source` 里拆出来
    nonisolated private func splitAuthorship() {
        // 磁盘上的内容是唯一真相：没有注释块就是没有归属（外部工具可能把它删了；留着旧区间只会错位）
        guard source.utf8.count < 64 * 1024 * 1024, source.contains(Authorship.marker) else { authorship = nil; authorshipMismatch = false; return }
        let (body, a, mismatch) = Authorship.split(source)
        source = body
        authorship = a
        authorshipMismatch = mismatch
    }

    /// 写盘内容：正文 + 著作归属注释块（有区间才写）
    nonisolated var sourceForDisk: String { authorship?.embed(into: source) ?? source }

    override func data(ofType typeName: String) throws -> Data {
        let source = sourceForDisk
        // 原编码装不下新内容（Latin-1 文件里打了个中文）：改用 UTF-8，并记住——否则下次重载会用旧编码去解 UTF-8 字节，得到乱码再写回
        if source.data(using: encoding) == nil { encoding = .utf8 }
        guard let d = source.data(using: encoding) ?? source.data(using: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError)
        }
        lastWrittenData = d
        return d
    }
    nonisolated(unsafe) private var lastWrittenData: Data?

    /// 编辑器每次击键调用（撤销由 NSTextView 走文档 undoManager，自动标脏）。
    /// `tracked`：改动已经通过 `recordEdit` 逐次记录（源码编辑器）；false = 混合模式 / pandoc 等整体替换，按差异对齐归属区间
    func setSourceFromEditor(_ text: String, tracked: Bool = true) {
        if !tracked, let a = authorship, !a.spans.isEmpty || Preferences.shared.authorship {
            var a = a
            a.realign(from: source, to: text, author: Preferences.shared.authorship ? Preferences.shared.authorshipAuthor : nil)
            authorship = a
        } else if !tracked, authorship == nil, Preferences.shared.authorship {
            var a = Authorship(); a.realign(from: source, to: text, author: Preferences.shared.authorshipAuthor); authorship = a
        }
        source = text
    }

    // MARK: - 著作归属

    /// 编辑器字符级改动：维护区间。开着著作归属时新内容归当前作者（粘贴归粘贴作者）；关着但文件已有区间时只做平移 / 裁切，不新增
    @MainActor
    func recordEdit(range: NSRange, delta: Int, isPaste: Bool) {
        let prefs = Preferences.shared
        let tracking = prefs.authorship
        if authorship == nil { guard tracking else { return }; authorship = Authorship() }
        let oldLength = range.length - delta
        var author: String? = nil
        if tracking {
            if isPaste { author = nextPasteAuthor ?? prefs.authorshipPasteAuthor; nextPasteAuthor = nil }
            else { author = prefs.authorshipAuthor }
            if let a = author, authorship?.author(a) == nil { author = Authorship.me.id }
        }
        authorship?.apply(replacing: range.location, length: max(0, oldLength), withLength: range.length, author: author)
    }

    /// 程序化整体替换内容（URL scheme / Shortcuts）：同步编辑器与渲染，标脏
    @MainActor
    func replaceContents(_ text: String) {
        if var a = authorship, !a.spans.isEmpty { a.realign(from: source, to: text, author: nil); authorship = a }   // 程序化改动：无归属
        source = text
        session.sourceDidChange(text, reason: .externalChange)
        (windowControllers.first as? DocumentWindowController)?.documentDidReload(text)
        updateChangeCount(.changeDone)
    }

    /// 外部修改后重新读取（保留编码）；自己刚保存的写入会被忽略（内容相同）。
    /// 有未保存改动时不静默覆盖：弹 sheet 让用户选择"重新载入（丢弃改动）/ 保留我的改动"；同一份磁盘内容只问一次。
    func reloadFromDisk() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        // 先按字节比：自己刚写的内容不算外部修改（也避免用记录的编码去解别的编码时"看起来不同"）
        if data == lastWrittenData { return }
        guard let s = String(data: data, encoding: encoding), s != sourceForDisk, s != source else { return }
        // 自己刚写盘的（正文相同、只是多了归属块 / 尾换行）也不算外部修改
        if authorship != nil || s.contains(Authorship.marker) {
            let diskBody = Authorship.split(s).body
            if diskBody == source || diskBody == source + "\n" { return }
        }
        if isDocumentEdited {
            guard s != conflictPromptedContent else { return }
            conflictPromptedContent = s
            MainActor.assumeIsolated { promptReloadConflict(diskSource: s) }
            return
        }
        applyReloaded(s)
    }
    private var conflictPromptedContent: String?

    private func applyReloaded(_ s: String) {
        source = s
        splitAuthorship()
        let s = source
        conflictPromptedContent = nil
        MainActor.assumeIsolated {
            session.sourceDidChange(s, reason: .externalChange)
            (windowControllers.first as? DocumentWindowController)?.documentDidReload(s)
            (windowControllers.first as? DocumentWindowController)?.noteAuthorshipMismatchIfNeeded()
        }
    }

    @MainActor
    private func promptReloadConflict(diskSource: String) {
        let alert = NSAlert()
        alert.messageText = L("文件在磁盘上被修改")
        alert.informativeText = String(format: L("%@ 已被其他程序修改，而当前有未保存的改动。要重新载入磁盘上的版本吗？"), fileURL?.lastPathComponent ?? displayName ?? L("文档"))
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("保留我的改动"))
        alert.addButton(withTitle: L("重新载入（丢弃改动）"))
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .alertSecondButtonReturn else { return }
            self.applyReloaded(diskSource)
            self.updateChangeCount(.changeCleared)
            self.undoManager?.removeAllActions()
        }
        if let window = windowForSheet { alert.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(alert.runModal()) }
    }

    /// 打印（⌘P / 脚本都经这里）：先把打印视图（含图片 / Mermaid）异步准备好，再走 NSDocument 的打印流程——
    /// `printOperation(withSettings:)` 是同步 API，等不了加载
    private var preparedPrintView: ReaderTextView?
    override func print(withSettings printSettings: [NSPrintInfo.AttributeKey: Any], showPrintPanel: Bool, delegate: Any?, didPrint didPrintSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        let ctx = UncheckedSendableBox(contextInfo)
        let del = UncheckedSendableBox(delegate)
        Task { @MainActor in
            let info = NSPrintInfo(dictionary: printSettings)
            let layout = PDFLayout.load()
            layout.configure(info, forPrintPanel: true)
            preparedPrintView = await wc.readerViewController.printableView(width: info.paperSize.width - info.leftMargin - info.rightMargin, layout: layout, document: self)
            super.print(withSettings: printSettings, showPrintPanel: showPrintPanel, delegate: del.value, didPrint: didPrintSelector, contextInfo: ctx.value)
        }
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let view = preparedPrintView else { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }   // 只能经 printDocument(withSettings:…) 进来
        preparedPrintView = nil
        let info = NSPrintInfo(dictionary: printSettings)
        PDFLayout.load().configure(info, forPrintPanel: true)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        return op
    }
}
