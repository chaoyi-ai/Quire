import Foundation
import QuireCore

/// 根目录下 Markdown 文件的文件名索引（快速打开 ⌘P；M7 的 wikilink / 内容块补全也用它）。
/// 后台整树扫描（10k 文件 ~100 ms，上限 50k），目录变化时合并 0.8 s 后重扫；按根目录共享。
@MainActor
final class FileIndex {
    nonisolated static let maxFiles = 50_000
    private static var shared: [String: FileIndex] = [:]

    static func index(for root: URL) -> FileIndex {
        let key = root.standardizedFileURL.path
        if let i = shared[key] { return i }
        let i = FileIndex(root: root.standardizedFileURL)
        shared[key] = i
        return i
    }

    let root: URL
    /// 相对路径（POSIX 分隔），已排序
    private(set) var relativePaths: [String] = []
    private(set) var isScanning = false
    private(set) var truncated = false
    var onChange: (() -> Void)?
    private var generation = 0
    private var rescanWork: DispatchWorkItem?

    private init(root: URL) {
        self.root = root
        rescan()
    }

    /// FSEvents 回调（由侧栏的 watcher 转发）：合并后整树重扫——目录树一般不大，比维护增量简单且不会漏
    func directoriesChanged() {
        rescanWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    func rescan() {
        generation += 1
        let gen = generation
        let root = self.root
        isScanning = true
        Task.detached(priority: .utility) {
            let (paths, truncated) = Self.scan(root: root)
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.relativePaths = paths
                self.truncated = truncated
                self.isScanning = false
                self.onChange?()
            }
        }
    }

    nonisolated static func scan(root: URL) -> ([String], Bool) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], false) }
        var out: [String] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var truncated = false
        for case let u as URL in e {
            let name = u.lastPathComponent
            if name == "node_modules" || name == ".build" || name == "Pods" { e.skipDescendants(); continue }
            guard QuireDocumentController.markdownExtensions.contains(u.pathExtension.lowercased()),
                  (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let p = u.path
            out.append(p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p)
            if out.count >= maxFiles { truncated = true; break }
        }
        out.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return (out, truncated)
    }

    /// 模糊匹配；空查询返回前 limit 个（按路径序）
    func search(_ query: String, limit: Int = 50) -> [(path: String, match: FuzzyMatcher.Match)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return relativePaths.prefix(limit).map { ($0, FuzzyMatcher.Match(score: 0, positions: [])) } }
        return FuzzyMatcher.rank(query: q, candidates: relativePaths, limit: limit).map { ($0.0, $0.1) }
    }

    func url(for relativePath: String) -> URL { root.appendingPathComponent(relativePath) }
}
