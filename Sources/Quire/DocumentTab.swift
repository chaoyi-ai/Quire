import AppKit
import QuireCore
import QuireRender

/// 工作区窗口里的一个标签：一份文档 + 它自己的阅读 / 编辑窗格 + 视图模式（docs/research/window-chrome.md §3）。
/// 窗格在标签切换时换进正文列；未选中的标签的窗格不在视图树里，但对象都活着（滚动位置、光标、撤销都保留）。
@MainActor
final class DocumentTab {
    let document: MarkdownDocument
    var session: DocumentSession { document.session }
    let reader: ReaderViewController
    /// 编辑器按需创建（阅读模式不构建）
    var editor: EditorViewController?
    /// 编辑器已插进正文分栏
    var editorAdded = false
    var mode: WorkspaceWindowController.Mode
    /// 临时标签（侧栏单击打开）：标题斜体；再单击别的文件会替换它；编辑过或双击后固定
    var isEphemeral: Bool
    var hybridWired = false
    let hybridSplicer = SourceLineSplicer()
    let readingTracker = ReadingTracker()
    var lastCaretBlock: Int?
    var fileURLObserver: NSKeyValueObservation?

    init(document: MarkdownDocument, mode: WorkspaceWindowController.Mode, ephemeral: Bool) {
        self.document = document
        self.reader = ReaderViewController(session: document.session)
        self.mode = mode
        self.isEphemeral = ephemeral
    }

    /// 标签上的名字：和侧栏同一条规则（`FileTreeController.displayName`：Markdown 文件不带扩展名）；未命名文档用系统给的名字
    var title: String {
        if let url = document.fileURL { return FileTreeController.displayName(url, ambiguous: false) }
        return document.displayName ?? "Untitled"
    }
    var hasEditorPane: Bool { editorAdded && (editor?.isViewLoaded ?? false) }
}
