import AppKit
import PDFKit
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
        guard op.run() else { return false }
        if let tv = view as? ReaderTextView { addBookmarks(to: url, from: tv, printInfo: info) }
        return true
    }

    /// PDF 书签：大纲 → PDFOutline（按标题级别嵌套），目标页与页内位置按打印分页算
    static func addBookmarks(to url: URL, from tv: ReaderTextView, printInfo info: NSPrintInfo) {
        let headings = tv.headingPositions()
        guard !headings.isEmpty, let pdf = PDFDocument(url: url) else { return }
        let pageHeight = (info.paperSize.height - info.topMargin - info.bottomMargin).rounded(.down)
        let root = PDFOutline()
        var stack: [(level: Int, node: PDFOutline)] = [(0, root)]
        for h in headings {
            let (pageIndex, offset) = tv.pagePlacement(forY: h.y, pageHeight: pageHeight)
            guard let page = pdf.page(at: pageIndex) else { continue }
            let item = PDFOutline()
            item.label = h.title
            // PDF 坐标原点在左下：页顶 = 纸高；内容区从 topMargin 起
            item.destination = PDFDestination(page: page, at: CGPoint(x: info.leftMargin, y: info.paperSize.height - info.topMargin - offset))
            while let top = stack.last, top.level >= h.level { stack.removeLast() }
            let parent = stack.last!.node
            parent.insertChild(item, at: parent.numberOfChildren)
            stack.append((h.level, item))
        }
        pdf.outlineRoot = root
        pdf.write(to: url)
    }

    /// 导出为图片：整页 PNG（2×），超长时按高度上限截断并提示
    static func exportImage(document: MarkdownDocument, from window: NSWindow) {
        guard let wc = document.windowControllers.first as? DocumentWindowController else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (document.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".png"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            writeImage(document: document, windowController: wc, to: url)
        }
    }

    @discardableResult
    static func writeImage(document: MarkdownDocument, windowController wc: DocumentWindowController, to url: URL) -> Bool {
        do {
            let width: CGFloat = 800
            let view = wc.readerViewController.printableView(width: width - 48)
            let maxH: CGFloat = 16_000
            let contentH = min(view.frame.height, maxH)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentH + 48))
            container.wantsLayer = true
            container.layer?.backgroundColor = wc.session.style.background.cgColor
            view.frame = NSRect(x: 24, y: 24, width: width - 48, height: contentH)
            container.addSubview(view)
            // 2×
            guard let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int((contentH + 48) * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
            scaled.size = container.bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
            container.displayIgnoringOpacity(container.bounds, in: NSGraphicsContext.current!)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = scaled.representation(using: .png, properties: [:]) else { return false }
            try png.write(to: url)
            if view.frame.height > maxH {
                let a = NSAlert(); a.messageText = L("图片已截断"); a.informativeText = String(format: L("文档太长，只导出了前 %d 像素高度。"), Int(maxH)); a.runModal()
            }
            return true
        } catch { NSApp.presentError(error); return false }
    }
}
