import Foundation
import QuireCore
import QuireRender

/// `![[file]]` 的文件解析：Markdown 走 FileIndex 快照 + `WikiLink.resolve`（同目录 > 子目录 > 父目录），
/// 其他类型（csv / 图片）按「当前文件目录 → 根目录」找；结果必须落在根目录内；超过 2 MB 不读。
enum TransclusionLoader {
    static let csvExtensions: Set<String> = ["csv", "tsv"]

    @MainActor static func make(root: URL, document: URL?) -> Transclusion.Loader {
        let rootPath = root.standardizedFileURL.path
        let rootResolved = root.resolvingSymlinksInPath().path
        let candidates = FileIndex.index(for: root).relativePaths
        return { target, fromPath in
            let fromDirAbs = (fromPath ?? document?.path).map { ($0 as NSString).deletingLastPathComponent } ?? rootPath
            var fromDir = fromDirAbs.hasPrefix(rootPath) ? String(fromDirAbs.dropFirst(rootPath.count)) : ""
            fromDir = fromDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let ext = (target as NSString).pathExtension.lowercased()
            var abs: String?
            if ext.isEmpty || QuireDocumentController.markdownExtensions.contains(ext) {
                if let rel = WikiLink.resolve(target, candidates: candidates, fromDir: fromDir) { abs = (rootPath as NSString).appendingPathComponent(rel) }
            }
            if abs == nil {
                let t = target.replacingOccurrences(of: "\\", with: "/")
                for base in [fromDirAbs, rootPath] {
                    let p = ((base as NSString).appendingPathComponent(t) as NSString).standardizingPath
                    if FileManager.default.fileExists(atPath: p) { abs = p; break }
                }
            }
            guard let abs else { return nil }
            let real = URL(fileURLWithPath: abs).resolvingSymlinksInPath().path
            guard real.hasPrefix(rootResolved + "/") || abs.hasPrefix(rootPath + "/") else { return (abs, .unavailable("超出根目录")) }
            let e = (abs as NSString).pathExtension.lowercased()
            if DropSupport.imageExtensions.contains(e) { return (abs, .image(path: abs, alt: (abs as NSString).lastPathComponent)) }
            let size = (try? FileManager.default.attributesOfItem(atPath: abs)[.size] as? Int) ?? 0
            guard size <= Transclusion.maxBytes else { return (abs, .unavailable("文件太大")) }
            guard let data = FileManager.default.contents(atPath: abs), let text = String(data: data, encoding: .utf8) else { return (abs, .unavailable("无法读取")) }
            if csvExtensions.contains(e) { return (abs, .csv(text)) }
            if QuireDocumentController.markdownExtensions.contains(e) { return (abs, .markdown(text)) }
            return (abs, .unavailable("不支持的类型"))
        }
    }
}
