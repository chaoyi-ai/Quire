import AppKit
import UniformTypeIdentifiers

/// 拖放辅助：从拖动会话里取文件 URL，按类型分类
public enum DropSupport {
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "txt", "text"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "bmp", "avif"]

    @MainActor
    public static func fileURLs(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    public static func isMarkdown(_ url: URL) -> Bool { markdownExtensions.contains(url.pathExtension.lowercased()) }
    public static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }
    public static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    /// 相对于文档目录的路径（不同卷或无文档时给绝对路径）；空格等做百分号编码
    public static func relativePath(of url: URL, to documentURL: URL?) -> String {
        let target = url.standardizedFileURL.pathComponents
        guard let base = documentURL?.deletingLastPathComponent().standardizedFileURL.pathComponents, base.first == target.first else {
            return url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        }
        var i = 0
        while i < base.count, i < target.count, base[i] == target[i] { i += 1 }
        let ups = Array(repeating: "..", count: base.count - i)
        let rel = (ups + target[i...]).joined(separator: "/")
        return rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
    }
}
