import AppKit
import UniformTypeIdentifiers

/// pandoc 可选集成：机器上装了 pandoc 才在菜单里出现 docx / epub / LaTeX 导出与 docx / HTML 导入；不内置、不下载。
@MainActor
enum PandocBridge {
    static var executable: URL? {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        // PATH 里找
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/which"); p.arguments = ["pandoc"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : URL(fileURLWithPath: out)
    }
    static var isAvailable: Bool { executable != nil }

    struct Format { let title: String; let ext: String; let to: String; let type: UTType }
    static let exportFormats: [Format] = [
        Format(title: "Word (.docx)…", ext: "docx", to: "docx", type: UTType("org.openxmlformats.wordprocessingml.document") ?? .data),
        Format(title: "EPUB…", ext: "epub", to: "epub3", type: UTType("org.idpf.epub-container") ?? .data),
        Format(title: "LaTeX…", ext: "tex", to: "latex", type: UTType("org.tug.tex") ?? .plainText),
    ]

    /// 把文档源码喂给 pandoc（stdin），输出到用户选的文件；相对图片路径以文档目录为 resource-path
    static func export(document: MarkdownDocument, format: Format, from window: NSWindow) {
        guard let exe = executable else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = (document.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + "." + format.ext
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let source = document.source
            var args = ["-f", "gfm+footnotes+tex_math_dollars", "-t", format.to, "-o", url.path, "--standalone"]
            if let dir = document.fileURL?.deletingLastPathComponent() { args += ["--resource-path", dir.path] }
            run(exe, args: args, stdin: source) { error in
                if let error { presentError(error) }
            }
        }
    }

    /// 导入 docx / html / rst 等 → 新建 Markdown 文档
    static func importDocument() {
        guard let exe = executable else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("org.openxmlformats.wordprocessingml.document") ?? .data, .html, .rtf, UTType("org.idpf.epub-container") ?? .data]
        panel.message = L("选择 Word / HTML / RTF / EPUB 文件，pandoc 会把它转成 Markdown 新文档")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let args = ["-t", "gfm", "--wrap=none", "--extract-media", FileManager.default.temporaryDirectory.appendingPathComponent("quire-import-media").path, url.path]
        run(exe, args: args, stdin: nil) { error in
            if let error { presentError(error); return }
        } output: { md in
            guard let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) as? MarkdownDocument else { return }
            doc.setSourceFromEditor(md, tracked: false)
            doc.session.sourceDidChange(md, reason: .externalChange)
            (doc.windowControllers.first as? DocumentWindowController)?.documentDidReload(md)
            doc.updateChangeCount(.changeDone)
        }
    }

    private static func run(_ exe: URL, args: [String], stdin: String?, completion: @escaping @MainActor (String?) -> Void, output: (@MainActor (String) -> Void)? = nil) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let errPipe = Pipe(), outPipe = Pipe()
        p.standardError = errPipe; p.standardOutput = outPipe
        if let stdin {
            let inPipe = Pipe(); p.standardInput = inPipe
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
                try? inPipe.fileHandleForWriting.close()
            }
        }
        do { try p.run() } catch { completion(error.localizedDescription); return }
        DispatchQueue.global().async {
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let status = p.terminationStatus
            DispatchQueue.main.async {
                if status != 0 { completion(String(decoding: err, as: UTF8.self)); return }
                completion(nil)
                output?(String(decoding: out, as: UTF8.self))
            }
        }
    }

    private static func presentError(_ message: String) {
        let a = NSAlert(); a.messageText = L("pandoc 失败"); a.informativeText = message; a.runModal()
    }
}
