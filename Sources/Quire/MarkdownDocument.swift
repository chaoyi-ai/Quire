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

/// Markdown 文档：读 / 写 / 自动保存；源码变化通过 DocumentSession 驱动渲染。
final class MarkdownDocument: NSDocument {
    /// 原始源码（编辑器与磁盘的唯一真相）
    private(set) var source: String = ""
    private(set) var encoding: String.Encoding = .utf8
    /// 新建文档默认进入分栏
    var isNewDocument = false
    /// 渲染会话（解析 / 渲染 / 监控），窗口控制器持有 UI
    private(set) lazy var session = DocumentSession(document: self)

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { [QuireDocumentController.markdownType, "public.plain-text", "public.text"] }
    override class var writableTypes: [String] { [QuireDocumentController.markdownType, "public.plain-text"] }
    override class func isNativeType(_ type: String) -> Bool { type == QuireDocumentController.markdownType }

    override init() {
        super.init()
        isNewDocument = true
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
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

    /// 外部修改后重新读取（保留编码）；自己刚保存的写入会被忽略（内容相同）
    func reloadFromDisk() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        guard let s = String(data: data, encoding: encoding), s != source else { return }
        if isDocumentEdited {
            // 有未保存改动：不覆盖，只提示（M4：冲突处理 UI）
            NSLog("Quire: 文件在磁盘上被修改，但当前有未保存改动，跳过重载")
            return
        }
        source = s
        MainActor.assumeIsolated {
            session.sourceDidChange(s, reason: .externalChange)
            (windowControllers.first as? DocumentWindowController)?.documentDidReload(s)
        }
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
