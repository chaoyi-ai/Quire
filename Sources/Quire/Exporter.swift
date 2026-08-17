import AppKit
import UniformTypeIdentifiers
import QuireCore
import QuireRender

/// 导出：HTML（内联主题 CSS）/ PDF（原生打印管线，分页）
@MainActor
enum Exporter {
    static func exportHTML(document: MarkdownDocument, from window: NSWindow) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (document.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".html"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let theme = ThemeManager.shared.currentTheme
            var opts = HTMLRenderer.Options()
            opts.title = document.displayName
            let html = HTMLRenderer(theme: theme, options: opts).render(document.session.parsed)
            do { try html.write(to: url, atomically: true, encoding: .utf8) }
            catch { NSApp.presentError(error) }
        }
    }

    static func exportPDF(document: MarkdownDocument, from window: NSWindow) {
        guard let wc = document.windowControllers.first as? DocumentWindowController else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (document.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".pdf"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            _ = writePDF(document: document, windowController: wc, to: url)
        }
    }

    /// 直接写 PDF（分页，A4/Letter 由系统打印设置决定）
    @discardableResult
    static func writePDF(document: MarkdownDocument, windowController wc: DocumentWindowController, to url: URL) -> Bool {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 40; info.rightMargin = 40
        let view = wc.readerViewController.printableView(width: info.paperSize.width - info.leftMargin - info.rightMargin)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        return op.run()
    }
}
