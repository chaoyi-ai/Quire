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
        return super.runModalOpenPanel(openPanel, forTypes: types)
    }
}

/// Markdown 文档：读 / 写 / 自动保存；源码变化通过 DocumentSession 驱动渲染。
final class MarkdownDocument: NSDocument {
    /// 原始源码（编辑器与磁盘的唯一真相）。NSDocument.read(from:) 在 SDK 里是 nonisolated（实际主线程调用），故 unsafe 标注
    nonisolated(unsafe) private(set) var source: String = ""
    nonisolated(unsafe) private(set) var encoding: String.Encoding = .utf8
    /// 新建文档默认进入分栏
    nonisolated(unsafe) var isNewDocument = false
    /// 渲染会话（解析 / 渲染 / 监控），窗口控制器持有 UI
    private(set) lazy var session = DocumentSession(document: self)

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
            else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownStringEncodingError, userInfo: [NSLocalizedDescriptionKey: "无法识别文件编码"]) }
        }
        isNewDocument = false
        let src = source
        LaunchClock.mark("file read (\(data.count) bytes)")
        MainActor.assumeIsolated {
            session.sourceDidChange(src, reason: .opened)
            (windowControllers.first as? DocumentWindowController)?.documentDidReload(src)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let d = source.data(using: encoding) ?? source.data(using: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError)
        }
        return d
    }

    /// 编辑器每次击键调用（撤销由 NSTextView 走文档 undoManager，自动标脏）
    func setSourceFromEditor(_ text: String) {
        source = text
    }

    /// 外部修改后重新读取（保留编码）；自己刚保存的写入会被忽略（内容相同）。
    /// 有未保存改动时不静默覆盖：弹 sheet 让用户选择"重新载入（丢弃改动）/ 保留我的改动"；同一份磁盘内容只问一次。
    func reloadFromDisk() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        guard let s = String(data: data, encoding: encoding), s != source else { return }
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
        conflictPromptedContent = nil
        MainActor.assumeIsolated {
            session.sourceDidChange(s, reason: .externalChange)
            (windowControllers.first as? DocumentWindowController)?.documentDidReload(s)
        }
    }

    @MainActor
    private func promptReloadConflict(diskSource: String) {
        let alert = NSAlert()
        alert.messageText = "文件在磁盘上被修改"
        alert.informativeText = "\(fileURL?.lastPathComponent ?? displayName ?? "文档") 已被其他程序修改，而当前有未保存的改动。要重新载入磁盘上的版本吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保留我的改动")
        alert.addButton(withTitle: "重新载入（丢弃改动）")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .alertSecondButtonReturn else { return }
            self.applyReloaded(diskSource)
            self.updateChangeCount(.changeCleared)
            self.undoManager?.removeAllActions()
        }
        if let window = windowForSheet { alert.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(alert.runModal()) }
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let wc = windowControllers.first as? DocumentWindowController else { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
        let info = NSPrintInfo(dictionary: printSettings)
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        let op = NSPrintOperation(view: wc.readerViewController.printableView(width: info.paperSize.width - info.leftMargin - info.rightMargin), printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        return op
    }
}
