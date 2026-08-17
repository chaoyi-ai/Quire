import AppKit
import UniformTypeIdentifiers
import QuireCore
import QuireRender

/// 文档控制器：无 Info.plist（`swift run` 开发态）时也能识别 .md 并映射到 MarkdownDocument。
@MainActor
final class QuireDocumentController: NSDocumentController {
    static let markdownType = "net.daringfireball.markdown"
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "txt", "text"]

    override func typeForContents(of url: URL) throws -> String {
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

/// Markdown 文档（M1：只读；M3 加入编辑与保存）
final class MarkdownDocument: NSDocument {
    /// 原始源码
    private(set) var source: String = ""
    private(set) var encoding: String.Encoding = .utf8
    /// 渲染会话（解析 / 渲染 / 监控），窗口控制器持有 UI
    private(set) lazy var session = DocumentSession(document: self)

    override class var autosavesInPlace: Bool { false }
    override class var readableTypes: [String] { [QuireDocumentController.markdownType, "public.plain-text", "public.text"] }
    override class func isNativeType(_ type: String) -> Bool { type == QuireDocumentController.markdownType }
    override var isDocumentEdited: Bool { false }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        // UTF-8 优先；失败退回 GB18030 / Latin-1（不静默丢字）
        if let s = String(data: data, encoding: .utf8) { source = s; encoding = .utf8 }
        else if let s = String(data: data, encoding: .utf16) { source = s; encoding = .utf16 }
        else {
            let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { source = s; encoding = String.Encoding(rawValue: gb) }
            else if let s = String(data: data, encoding: .isoLatin1) { source = s; encoding = .isoLatin1 }
            else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownStringEncodingError, userInfo: [NSLocalizedDescriptionKey: "无法识别文件编码"]) }
        }
        // NSDocument 读文件在主线程（未开启并发读取）
        let src = source
        MainActor.assumeIsolated { session.sourceDidChange(src, reason: .opened) }
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let d = source.data(using: encoding) else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError) }
        return d
    }

    /// 外部修改后重新读取（保留编码）
    func reloadFromDisk() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        if let s = String(data: data, encoding: encoding), s != source {
            source = s
            session.sourceDidChange(source, reason: .externalChange)
        }
    }

    // 只读文档：不提示保存
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let wc = windowControllers.first as? DocumentWindowController else { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
        let info = NSPrintInfo(dictionary: printSettings)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        let op = NSPrintOperation(view: wc.readerViewController.printableView(), printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        return op
    }
}
