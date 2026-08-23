import AppIntents
import AppKit

/// Apple Shortcuts 动作（App Intents）。元数据由 build_app.sh 用 appintentsmetadataprocessor 生成到
/// Contents/Resources/Metadata.appintents——纯 SwiftPM 没有 Xcode 的这一步，所以脚本里手动跑。
/// 来自 Shortcuts 的动作是用户自己编排的，不走 quire:// 的外部确认。

struct OpenInQuireIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in Quire"
    static let description = IntentDescription("Open a Markdown file in Quire, optionally jumping to a line.")
    static let openAppWhenRun = true

    @Parameter(title: "File") var file: IntentFile
    @Parameter(title: "Line") var line: Int?

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$file) in Quire") { \.$line } }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = file.fileURL else { throw IntentError.noFile }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            URLScheme.openFile(url, line: line, external: false) { c.resume(returning: $0) }
        }
        guard ok else { throw IntentError.failed }
        return .result()
    }
}

struct NewQuireDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "New Document in Quire"
    static let description = IntentDescription("Create a new Markdown document with the given text.")
    static let openAppWhenRun = true

    @Parameter(title: "Text") var text: String?
    @Parameter(title: "Save to path", description: "Absolute path of the new file. Leave empty for an untitled document.") var path: String?

    static var parameterSummary: some ParameterSummary { Summary("New document with \(\.$text)") { \.$path } }

    @MainActor
    func perform() async throws -> some IntentResult {
        URLScheme.newDocument(text: text ?? "", at: URLScheme.path(path), external: false)
        return .result()
    }
}

struct AppendToQuireDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Append Text to Markdown File"
    static let description = IntentDescription("Append text to the end of a Markdown file. If the file is open in Quire it is updated and saved.")
    static let openAppWhenRun = true   // 与其他动作一致：在 App 进程里做，已打开的文档直接改

    @Parameter(title: "File") var file: IntentFile
    @Parameter(title: "Text") var text: String

    static var parameterSummary: some ParameterSummary { Summary("Append \(\.$text) to \(\.$file)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = file.fileURL else { throw IntentError.noFile }
        guard URLScheme.appendText(text, to: url, external: false) else { throw IntentError.failed }
        return .result()
    }
}

struct ExportQuirePDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Markdown as PDF"
    static let description = IntentDescription("Render a Markdown file with Quire and export it as PDF (uses the saved PDF layout settings).")
    static let openAppWhenRun = true

    @Parameter(title: "File") var file: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Export \(\.$file) as PDF") }

    @MainActor
    func perform() async throws -> some ReturnsValue<IntentFile> {
        guard let url = file.fileURL else { throw IntentError.noFile }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            URLScheme.exportDocument(url, to: out, format: "pdf", external: false) { c.resume(returning: $0) }
        }
        guard ok, let data = try? Data(contentsOf: out) else { throw IntentError.failed }
        return .result(value: IntentFile(data: data, filename: out.lastPathComponent, type: .pdf))
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case noFile, failed
    var localizedStringResource: LocalizedStringResource {
        switch self { case .noFile: return "No file was provided."; case .failed: return "Quire could not complete the action." }
    }
}

struct QuireShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewQuireDocumentIntent(), phrases: ["New document in \(.applicationName)"], shortTitle: "New Document", systemImageName: "doc.badge.plus")
    }
}
