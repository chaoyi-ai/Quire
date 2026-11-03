import AppKit
import UniformTypeIdentifiers
import QuireCore
import QuireRender

/// 文档控制器：无 Info.plist（`swift run` 开发态）时也能识别 .md 并映射到 MarkdownDocument。
@MainActor
final class QuireDocumentController: NSDocumentController {
    static let markdownType = "net.daringfireball.markdown"
    nonisolated static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "txt", "text"]

    /// 内置扩展名 + 设置里"额外按 Markdown 处理"的扩展名（侧栏、打开面板、类型判定共用）
    @MainActor static var allMarkdownExtensions: Set<String> { markdownExtensions.union(Preferences.shared.extraExtensionSet) }

    override func typeForContents(of url: URL) throws -> String {
        LaunchClock.mark("typeForContents")
        if Self.markdownExtensions.contains(url.pathExtension.lowercased()) { return Self.markdownType }
        if Self.allMarkdownExtensions.contains(url.pathExtension.lowercased()) { return Self.markdownType }
        if let t = try? super.typeForContents(of: url) { return t }
        return Self.markdownType
    }

    override func documentClass(forType typeName: String) -> AnyClass? {
        MarkdownDocument.self
    }

    override var defaultType: String? { Self.markdownType }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        // 设置里加的扩展名（.mdx / .qmd…）也要能在打开面板里选
        let extras = Preferences.shared.extraExtensionSet.compactMap { UTType(filenameExtension: $0) }
        openPanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText, UTType("net.daringfireball.markdown") ?? .plainText] + extras
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = true   // 选文件夹 = 以它为侧栏根打开
        openPanel.message = L("选择 Markdown 文件，或选一个文件夹作为工作目录")
        return super.runModalOpenPanel(openPanel, forTypes: types)
    }

    // MARK: - 打开到哪个工作区（docs/research/window-chrome.md §3）

    /// 一次打开的去向：指定的工作区（nil = 新窗口，根目录 `newWindowRoot`）；`ephemeral` = 侧栏单击的临时标签；`link` = 是经这个符号链接打开的
    struct OpenTarget {
        weak var workspace: WorkspaceWindowController?
        var newWindowRoot: URL?
        var ephemeral = false
        var link: URL?
    }
    /// 按文件路径登记的去向：NSDocumentController 读文件是异步的，makeWindowControllers 时按 fileURL 取
    private var pendingTargets: [String: OpenTarget] = [:]
    /// 未命名文档的去向（新建 / 空文件夹）
    private var pendingUntitled: OpenTarget?

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// 路径最后一段是符号链接：文档落在它指向的文件上（DESIGN §9）。NSDocument 的安全写入走 FileManager.replaceItem，macOS 27 上它对符号链接报 ENOENT，裸 NSDocument 子类也存不了；
    /// 修改时间（attributesOfItem、URL 资源值）也都是链接自己的，防覆盖的检查形同虚设。目录部分的符号链接不碰：不影响存储，路径也还要留在工作区根下。
    /// 不能只在 writeSafely 里换成真实路径：NSDocument 看 fileURL 对不上，会删掉真实文件再报错
    nonisolated static func followingSymlink(_ url: URL) -> URL {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return url }
        return url.resolvingSymlinksInPath()
    }

    /// makeWindowControllers 取走登记的去向；没登记（Apple 事件、恢复……）就按 key 工作区推断
    func takeTarget(for doc: MarkdownDocument) -> OpenTarget {
        if let url = doc.fileURL {
            if let t = pendingTargets.removeValue(forKey: Self.key(url)) { return t }
            return OpenTarget(workspace: Self.workspace(for: url))
        }
        if let t = pendingUntitled { pendingUntitled = nil; return t }
        return OpenTarget(workspace: WorkspaceWindowController.key)
    }

    /// 文件该进哪个工作区：key 工作区在根内（或它还没有根）→ 它；别的工作区在根内 → 那个；都不是 → nil（新窗口）
    static func workspace(for url: URL) -> WorkspaceWindowController? {
        let all = WorkspaceWindowController.all
        let key = WorkspaceWindowController.key
        if let key, key.contains(url) { return key }
        if let ws = all.first(where: { $0.contains(url) }) { return ws }
        return key?.rootURL == nil ? key : nil
    }

    /// 在指定工作区里打开（侧栏 / 链接 / 恢复）；`workspace` nil = 按 `workspace(for:)` 推断
    func open(_ url: URL, in workspace: WorkspaceWindowController?, ephemeral: Bool, newWindowRoot: URL? = nil, completion: @escaping @MainActor (MarkdownDocument?) -> Void) {
        pendingTargets[Self.key(url)] = OpenTarget(workspace: workspace ?? Self.workspace(for: url), newWindowRoot: newWindowRoot, ephemeral: ephemeral)
        openDocument(withContentsOf: url, display: true) { doc, _, error in
            if let error { NSApp.presentError(error) }
            completion(doc as? MarkdownDocument)
        }
    }

    /// 文件夹走 `openFolder`；已经开着的文档切到它的标签；其余照常（打开面板、Dock 拖放、`open -a`、服务菜单都经这里）
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            openFolder(url, completionHandler: completionHandler)
            return
        }
        let file = Self.followingSymlink(url)   // 链接和它指向的文件是同一份文档
        if let doc = document(for: file) as? MarkdownDocument, let ws = doc.workspace, let tab = ws.tab(for: doc) {
            pendingTargets[Self.key(url)] = nil
            if displayDocument { ws.select(tab); ws.showWindow(nil) }
            completionHandler(doc, true, nil)
            return
        }
        if file != url {
            // 去向按链接的位置判断（链接在根内就留在这个工作区，不管它指向哪），按真实文件登记：makeWindowControllers 取的时候 fileURL 是它
            var target = pendingTargets.removeValue(forKey: Self.key(url)) ?? OpenTarget(workspace: Self.workspace(for: url))
            target.link = url
            pendingTargets[Self.key(file)] = target
        }
        let k = Self.key(file)
        super.openDocument(withContentsOf: file, display: displayDocument) { [weak self] doc, already, error in
            self?.pendingTargets[k] = nil
            completionHandler(doc, already, error)
        }
    }

    /// ⌘N / 标签条 +：新文档进 key 工作区（没有窗口就新开一个）
    override func newDocument(_ sender: Any?) {
        pendingUntitled = OpenTarget(workspace: WorkspaceWindowController.key)
        super.newDocument(sender)
    }

    /// 打开文件夹 = 新开一个工作区窗口：优先 README.md / index.md，否则第一个 Markdown；都没有就新建一篇
    func openFolder(_ folder: URL, completionHandler: ((NSDocument?, Bool, (any Error)?) -> Void)? = nil) {
        let fm = FileManager.default
        let items: [URL]
        do { items = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) }
        catch { completionHandler?(nil, false, error); if completionHandler == nil { NSApp.presentError(error) }; return }   // 读不了目录：说出来，别悄悄开个空文档
        let mds = items.filter { Self.markdownExtensions.contains($0.pathExtension.lowercased()) && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let preferred = mds.first { ["readme.md", "index.md", "readme.markdown"].contains($0.lastPathComponent.lowercased()) } ?? mds.first
        // 同一个根已经开着一个工作区：不再开一个，切过去
        if let ws = WorkspaceWindowController.all.first(where: { $0.rootURL?.standardizedFileURL == folder.standardizedFileURL }) {
            ws.showWindow(nil)
            completionHandler?(ws.markdownDocument, true, nil)
            return
        }
        if let preferred {
            if let doc = document(for: preferred) as? MarkdownDocument, let ws = doc.workspace, let tab = ws.tab(for: doc) {
                // 文件已在别的工作区里开着：拆到新窗口
                if ws.tabs.count > 1, ws.window?.attachedSheet != nil { ws.showWindow(nil) }   // 正在问：不把文档从询问底下搬走（见 moveTabToNewWindow）
                else if ws.tabs.count > 1 { ws.detach(tab); WorkspaceWindowController(document: doc, root: folder).showWindow(nil) }
                else { ws.sidebarViewController.setRoot(folder); ws.showWindow(nil) }
                completionHandler?(doc, true, nil); return
            }
            pendingTargets[Self.key(preferred)] = OpenTarget(workspace: nil, newWindowRoot: folder)
            super.openDocument(withContentsOf: preferred, display: true) { [weak self] doc, already, error in
                self?.pendingTargets[Self.key(preferred)] = nil
                completionHandler?(doc, already, error)
            }
        } else {
            do {
                pendingUntitled = OpenTarget(workspace: nil, newWindowRoot: folder)
                let doc = try openUntitledDocumentAndDisplay(true)
                completionHandler?(doc, false, nil)
            } catch { pendingUntitled = nil; completionHandler?(nil, false, error) }
        }
    }
}

/// Markdown 文档：读 / 写 / 自动保存；源码变化通过 DocumentSession 驱动渲染。
struct UncheckedSendableBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

class MarkdownDocument: NSDocument {
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
    /// 所在的工作区窗口（文档是它的一个标签）。窗口控制器只挂在当前标签的文档上，所以不能靠 windowControllers 找窗口
    @MainActor weak var workspace: WorkspaceWindowController?
    /// 这份文档那个标签的阅读视图（导出 / 打印用）
    @MainActor var readerViewController: ReaderViewController? { workspace?.tab(for: self)?.reader }
    /// 经符号链接打开时，用户点的那个路径（`fileURL` 是它指向的文件）
    @MainActor private var linkURL: URL?
    /// 界面上用的路径（标签名、侧栏的当前项、跳转历史、下次恢复）：经符号链接打开的文档还叫那个名字、留在侧栏原来的位置，不然链接指向根外时侧栏会跳走。
    /// 链接被删、改指向，或者文档存储为别的文件之后，回到真实路径
    @MainActor var presentedURL: URL? {
        guard let linkURL, QuireDocumentController.followingSymlink(linkURL).standardizedFileURL.path == fileURL?.standardizedFileURL.path else { return fileURL }
        return linkURL
    }
    /// 脏标记变化（标签条上的圆点、临时标签固定）
    static let editedStateDidChange = Notification.Name("com.korako.quire.documentEditedStateDidChange")

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { [QuireDocumentController.markdownType, "public.plain-text", "public.text"] }
    override class var writableTypes: [String] { [QuireDocumentController.markdownType, "public.plain-text"] }
    override class func isNativeType(_ type: String) -> Bool { type == QuireDocumentController.markdownType }

    override init() {
        super.init()
        isNewDocument = true
        LaunchClock.mark("document init")
    }

    /// 不再一份文档一个窗口：按登记的去向进某个工作区当标签，或新开一个工作区窗口
    override func makeWindowControllers() {
        LaunchClock.mark("makeWindowControllers begin")
        let target = (NSDocumentController.shared as! QuireDocumentController).takeTarget(for: self)
        linkURL = target.link
        // 读文件期间目标窗口关了（恢复途中、侧栏单击后马上关）：这份文档也不另开窗口，它要去的地方用户刚关掉
        if let ws = target.workspace, ws.isClosed { perform(#selector(NSDocument.close), with: nil, afterDelay: 0) }
        else if let ws = target.workspace, ws.window != nil { ws.addTab(self, ephemeral: target.ephemeral) }
        else { _ = WorkspaceWindowController(document: self, root: target.newWindowRoot ?? presentedURL?.deletingLastPathComponent()) }
        LaunchClock.mark("makeWindowControllers end")
    }

    /// 关闭：先把标签从工作区摘掉（不是最后一个标签时窗口不关）
    override func close() {
        MainActor.assumeIsolated { workspace?.documentWillClose(self) }
        super.close()
    }

    /// 文档的窗口就是工作区的窗口，标签在不在前台都一样。窗口控制器只挂在当前标签的文档上，默认实现对后台标签返回 nil：
    /// 系统的询问就退回 app 级模态（答完文档又被标成未保存）；询问开着时等活动队列，AppKit 找不到 sheet，主线程真的死等，再也答不了
    override var windowForSheet: NSWindow? { super.windowForSheet ?? MainActor.assumeIsolated { workspace?.window } }

    /// 一个窗口一次只能挂一个询问。窗口上已经有 sheet 时（别的标签正在问、开着导出面板）系统挂不上去：既不显示也不结束，这份文档的活动队列就卡住了，之后存储、关闭都死等。
    /// 所以这时不问：按"没有解决"回话，活动正常结束，改动还在，排到这个 sheet 结束之后再问
    override func presentError(_ error: any Error, modalFor window: NSWindow, delegate: Any?, didPresent didPresentSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let nsError = error as NSError
        let cancelled = nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError   // 这个系统不显示，直接回话
        guard MainActor.assumeIsolated({ window.attachedSheet != nil }), !cancelled else {
            super.presentError(error, modalFor: window, delegate: delegate, didPresent: didPresentSelector, contextInfo: contextInfo)
            return
        }
        if let target = delegate as? NSObject, let selector = didPresentSelector {
            typealias Reply = @convention(c) (NSObject, Selector, Bool, UnsafeMutableRawPointer?) -> Void
            unsafeBitCast(target.method(for: selector), to: Reply.self)(target, selector, false, contextInfo)
        }
        MainActor.assumeIsolated { workspace?.askAfterCurrentSheet(self) }
    }

    /// 关闭前的询问：切到这份文档的标签，问的是它，sheet 要盖在它上面
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        MainActor.assumeIsolated { if let ws = workspace, let t = ws.tab(for: self), ws.current !== t { ws.select(t) } }
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    /// 窗口要关：直接放行，询问归 WorkspaceWindowController.windowShouldClose（窗口是多文档的，它逐个标签问）。
    /// 默认实现会先问挂着的这份文档，而且 windowShouldClose 是在这个询问的回调里被调到的——那时文档的序列化活动还没结束，
    /// 再对同一份文档 canClose 就要等这个活动结束，自己等自己，主线程永远卡死
    override func shouldCloseWindowController(_ windowController: NSWindowController, delegate: Any?, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard let target = delegate as? NSObject, let selector = shouldCloseSelector else { return }
        typealias Reply = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(target.method(for: selector), to: Reply.self)(target, selector, self, true, contextInfo)
    }

    /// 每次存储开始时断开打字的撤销合并（TextEdit 也这样做）。脏标记靠撤销组关闭驱动，连续打字却一直合并在同一个撤销组里：
    /// 不断开的话，存储把文档标干净之后接着打的字不再标脏、不再自动保存，关闭时也不问，这段文字就丢了
    override func changeCountToken(for saveOperation: NSDocument.SaveOperationType) -> Any {
        MainActor.assumeIsolated {
            if let tab = workspace?.tab(for: self), tab.hasEditorPane { tab.editor?.textView.breakUndoCoalescing() }
        }
        return super.changeCountToken(for: saveOperation)
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        let was = isDocumentEdited
        super.updateChangeCount(change)
        if was != isDocumentEdited { NotificationCenter.default.post(name: Self.editedStateDidChange, object: self) }
        // 改动撤销完了：有改动时没跟的外部修改现在可以跟了。这时没有存储，系统不会再来问，不跟就一直停在旧内容（关了"自动重新载入"就不替用户载入，⌘R 才跟）
        if was, !isDocumentEdited, Preferences.shared.autoReload { Task { @MainActor [weak self] in self?.reloadFromDisk() } }
    }
    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        let was = isDocumentEdited
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        if was != isDocumentEdited { NotificationCenter.default.post(name: Self.editedStateDidChange, object: self) }
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        // 就地存储时扩展名不属于这个类型的（.txt、.mdown、设置里加的 .qmd……系统的 Markdown 类型只认 md 和 markdown），NSDocument 会把文件改名成这里给的扩展名
        if saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation, let ownExtension = fileURL?.pathExtension { return ownExtension }
        return "md"
    }

    /// 字节 → 文字 + 编码，只看字节：打开、外部修改、"重新载入"、往没打开的文件追加都走这里，同样的字节从哪条路进来都解成同样的文字。
    /// UTF-8 优先；失败退回带 BOM 的 UTF-16 / GB18030 / Latin-1（不静默丢字）。
    /// UTF-16 只认 BOM：几乎任何字节都能当成无 BOM 的大端 UTF-16 解开（奇数长度还丢掉最后一个字节），GBK 短文和 Latin-1 全被截走，存一次文件就毁了。
    /// 代价：真正无 BOM 的 UTF-16 显示成乱码（其中大端的以前能读对），但存储时字节原样写回，不再加 BOM、反转字节序
    nonisolated static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        let bigEndian = data.starts(with: [0xFE, 0xFF])
        if bigEndian || data.starts(with: [0xFF, 0xFE]) {
            let order: String.Encoding = bigEndian ? .utf16BigEndian : .utf16LittleEndian
            let payload = data.dropFirst(2)
            // 写回去要和原来一样：奇数长度（解码器会丢最后一个字节）、孤立代理项都不算 UTF-16，往下走
            if let s = String(data: payload, encoding: order), s.data(using: order) == payload { return (s, .utf16) }
        }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if looksLikeGB18030(data), let s = String(data: data, encoding: gb) { return (s, gb) }
        if let s = String(data: data, encoding: .isoLatin1) { return (s, .isoLatin1) }
        return nil
    }

    /// 字节里有没有西文 Latin-1 几乎不会出现的序列：GB2312 的符号区和一级汉字（首字节 A1–A9 / B0–D7，尾字节 ≥ A1），或者四字节序列。
    /// 只看"解得开"分不出来：重音字母后面跟字母也是合法的 GB18030（Señor → Se駉r，德语几乎都这样）。
    /// 代价：完全没有常用字的 GBK 短文（這個）会被当成 Latin-1，显示成乱码
    nonisolated private static func looksLikeGB18030(_ data: Data) -> Bool {
        var bytes = data.makeIterator()
        while let lead = bytes.next() {
            guard lead > 0x80, let trail = bytes.next() else { continue }
            switch (lead, trail) {
            case (_, 0x30...0x39), (0xA1...0xA9, 0xA1...), (0xB0...0xD7, 0xA1...): return true
            default: break
            }
        }
        return false
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let decoded = Self.decode(data) else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownStringEncodingError, userInfo: [NSLocalizedDescriptionKey: L("无法识别文件编码")]) }
        source = decoded.text
        encoding = decoded.encoding
        // 要自己的一份：NSDocument 给的可能是文件映射，留着它卷就卸不掉，强行卸掉后再比较还会崩
        let own = Data(data)
        diskDataLock.withLock { knownDiskData = own }
        normalizeLineEndings()
        splitAuthorship()
        isNewDocument = false
        let src = source
        LaunchClock.mark("file read (\(data.count) bytes)")
        MainActor.assumeIsolated {
            session.sourceDidChange(src, reason: .opened)
            workspace?.documentDidReload(self, src)
        }
    }

    /// 内存里一律 LF（编辑器 / 混合模式 / 统计都按 "\n" 切行，Swift 把 "\r\n" 当一个字符）；写盘时按原样还原 CRLF
    nonisolated(unsafe) private(set) var usesCRLF = false
    nonisolated private func normalizeLineEndings() {
        guard source.utf8.contains(0x0D) else { usesCRLF = false; return }
        usesCRLF = source.contains("\r\n")
        source = source.replacingOccurrences(of: "\r\n", with: "\n")
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

    /// 写盘内容：正文 + 著作归属注释块（有东西才写）；CRLF 文件还原 CRLF
    nonisolated var sourceForDisk: String {
        let s = authorship?.embed(into: source) ?? source
        return usesCRLF ? s.replacingOccurrences(of: "\n", with: "\r\n") : s
    }

    /// 只序列化：这时还没写，不能算磁盘上的内容（只把字节交给进行中的那次写盘，writeSafely 成功才转正）。`nonisolated`：写盘可能不在主线程
    nonisolated override func data(ofType typeName: String) throws -> Data {
        let source = sourceForDisk
        // 原编码装不下新内容（Latin-1 文件里打了个中文）：改用 UTF-8，并记住——磁盘上已经是 UTF-8 了，之后都按它写
        if source.data(using: encoding) == nil { encoding = .utf8 }
        guard let d = source.data(using: encoding) ?? source.data(using: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError)
        }
        diskDataLock.withLock { if isWritingDisk { writingDiskData = d } }
        return d
    }

    /// 写进文档自己的文件并且成功，磁盘上才是这份字节。写失败（只读、没权限、卷满）磁盘上还是旧字节，提前记下的话下一个监视器事件就误报"已被其他程序修改"，选重新载入就丢了改动。
    /// 导出副本（.saveTo）、写到自动保存目录（.autosaveElsewhere）没动文档的文件，不记；存储为（.saveAs / .autosaveAs）写的是新文件，存完它就是 fileURL，要记（所以不能按"目标 == fileURL"判断：这时 fileURL 还是旧的）
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        guard saveOperation != .saveToOperation, saveOperation != .autosaveElsewhereOperation else {
            try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
            return
        }
        diskDataLock.withLock { isWritingDisk = true }
        defer { diskDataLock.withLock { isWritingDisk = false; writingDiskData = nil } }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        diskDataLock.withLock { knownDiskData = writingDiskData }
    }

    /// 最近一次读到、写下或采用的磁盘字节：磁盘上还是这份，就没有外部修改
    nonisolated(unsafe) private var knownDiskData: Data?
    /// 写盘进行中时 data(ofType:) 给出去的字节。写盘之外调 data(ofType:) 不留痕迹
    nonisolated(unsafe) private var writingDiskData: Data?
    nonisolated(unsafe) private var isWritingDisk = false
    /// 管上面三个：`canAsynchronouslyWrite` 打开时写盘不在主线程，监视器的比较在主线程
    private let diskDataLock = NSLock()

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
        workspace?.documentDidReload(self, text)
        updateChangeCount(.changeDone)
    }

    /// 和磁盘比较的结论。监视器不看（事件可能什么都不代表），⌘R 按它回应
    enum ReloadResult { case current, reloaded, unsavedEdits, conflict, unreadable }

    /// 外部修改后重新读取（和打开一样解码，编码跟着磁盘走）；字节没变就不算外部修改：监视器对自己刚写的内容、对只动属性的 touch / Finder 标签 / 备份工具都会响。
    /// 有未保存改动时不覆盖、不写盘，也不打断：修改时间留在旧值，下一次存储被 NSDocument 拦下，由系统问一次（DESIGN §9）
    @discardableResult
    func reloadFromDisk() -> ReloadResult {
        guard let disk = readDisk() else { return .unreadable }
        let (known, writing) = diskDataLock.withLock { (knownDiskData, writingDiskData) }
        // 先按字节比
        if disk.data == known {
            fileModificationDate = disk.date
            return isDocumentEdited ? .unsavedEdits : .current
        }
        // 正在写的那份已经落盘、写盘线程还没走到记账（监视器防抖只有 0.15 s）：是自己写的。修改时间 NSDocument 写完会更新
        if disk.data == writing { return isDocumentEdited ? .unsavedEdits : .current }
        // 解不开也不能悄悄留着旧文字（Latin-1 什么字节都解得开，实际到不了这里）
        guard let decoded = Self.decode(disk.data) else { return .unreadable }
        // 被别的工具换了编码：文字没变也要跟上，否则下次存储又按旧编码写回去。有未保存改动就往下走，由系统问
        if decoded.encoding != encoding, !isDocumentEdited { applyReloaded(decoded, disk); return .reloaded }
        let raw = decoded.text
        guard raw != sourceForDisk else { return .current }
        let s = raw.contains("\r\n") ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        guard s != source else { return .current }
        // 自己刚写盘的（正文相同、只是多了归属块 / 尾换行）也不算外部修改
        if authorship != nil || s.contains(Authorship.marker) {
            let diskBody = Authorship.split(s).body
            if diskBody == source || diskBody == source + "\n" { return .current }
        }
        if isDocumentEdited { return .conflict }
        applyReloaded(decoded, disk)
        return .reloaded
    }

    /// ⌘R：用户自己要的，和监视器不一样。和未保存改动冲突就立刻问（走存储，系统问的就是那一问），之前问过也问；做不到要有回应。返回 false = 做不到，响过一声
    @MainActor
    @discardableResult
    func reloadCommand() -> Bool {
        guard windowForSheet?.attachedSheet == nil else { NSSound.beep(); return false }   // 已经在问了
        switch reloadFromDisk() {
        case .current, .reloaded: return true
        case .conflict: save(nil); return true
        case .unsavedEdits, .unreadable: NSSound.beep(); return false
        }
    }

    /// 文件被别的程序改过时系统问的那一问，标题换成发生了什么："未能自动保存"读着像出错了，其实是在等用户决定。
    /// 说明文字和按钮不动，它们和恢复动作是一套的。67000 头文件里没有；哪天系统换了码，这里只是退回系统自己的标题
    override func willPresentError(_ error: any Error) -> any Error {
        let e = super.willPresentError(error) as NSError
        guard e.domain == NSCocoaErrorDomain, e.code == 67000 else { return e }
        var info = e.userInfo
        info[NSLocalizedDescriptionKey] = String(format: L("“%@”已被其他程序修改"), fileURL?.lastPathComponent ?? displayName ?? L("文档"))
        return NSError(domain: e.domain, code: e.code, userInfo: info)
    }

    /// 磁盘上现在的字节和修改时间。先取时间再读：中间又被改的话，记下的时间比字节旧，NSDocument 下次存储时会拦住；
    /// 反过来就可能记下没读到的那次写入的时间，下次存储把它静默盖掉
    private func readDisk() -> (data: Data, date: Date)? {
        guard let url = fileURL,
              let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url) else { return nil }
        return (data, date)
    }

    /// `decoded.text` 是解码后还没统一换行的文本：CRLF 文件要靠它记住写盘时还原。
    /// 修改时间同时跟上：否则 NSDocument 按自己记的时间，下次存储时还会问"文件已被修改"
    private func applyReloaded(_ decoded: (text: String, encoding: String.Encoding), _ disk: (data: Data, date: Date)) {
        diskDataLock.withLock { knownDiskData = disk.data }
        fileModificationDate = disk.date
        source = decoded.text
        encoding = decoded.encoding
        normalizeLineEndings()
        splitAuthorship()
        let s = source
        MainActor.assumeIsolated {
            session.sourceDidChange(s, reason: .externalChange)
            workspace?.documentDidReload(self, s)
            if workspace?.current?.document === self { workspace?.noteAuthorshipMismatchIfNeeded() }
        }
    }

    /// 打印（⌘P / 脚本都经这里）：先把打印视图（含图片 / Mermaid）异步准备好，再走 NSDocument 的打印流程——
    /// `printOperation(withSettings:)` 是同步 API，等不了加载
    private var preparedPrintView: ReaderTextView?
    override func print(withSettings printSettings: [NSPrintInfo.AttributeKey: Any], showPrintPanel: Bool, delegate: Any?, didPrint didPrintSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard let reader = readerViewController else { return }
        let ctx = UncheckedSendableBox(contextInfo)
        let del = UncheckedSendableBox(delegate)
        Task { @MainActor in
            let info = NSPrintInfo(dictionary: printSettings)
            let layout = PDFLayout.load()
            layout.configure(info, forPrintPanel: true)
            preparedPrintView = await reader.printableView(width: info.paperSize.width - info.leftMargin - info.rightMargin, layout: layout, document: self)
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
