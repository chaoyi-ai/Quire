import Foundation
import QuireCore

/// 根目录标签索引：对 FileIndex 里的文件后台扫 `#标签`（按 mtime 缓存），目录变化时重扫。
@MainActor
final class TagIndexStore {
    private static var shared: [String: TagIndexStore] = [:]
    static func store(for root: URL) -> TagIndexStore {
        let key = root.standardizedFileURL.path
        if let s = shared[key] { return s }
        let s = TagIndexStore(root: root); shared[key] = s; return s
    }

    let root: URL
    /// 标签 → 相对路径列表（按标签名排序）
    private(set) var tags: [(tag: String, files: [String])] = []
    let observers = ChangeObservers()
    private var cache: [String: (mtime: Date, tags: [String])] = [:]
    private var generation = 0
    private var indexToken: ChangeObservers.Token?

    private init(root: URL) {
        self.root = root
        let index = FileIndex.index(for: root)
        indexToken = index.observers.add { [weak self] in self?.rescan() }
        if !index.relativePaths.isEmpty { rescan() }
    }

    func rescan() {
        generation += 1
        let gen = generation
        let index = FileIndex.index(for: root)
        let paths = index.relativePaths
        let root = self.root
        let cacheSnapshot = cache
        Task.detached(priority: .utility) {
            var newCache: [String: (mtime: Date, tags: [String])] = [:]
            var map: [String: [String]] = [:]
            let fm = FileManager.default
            for rel in paths.prefix(20_000) {
                let url = root.appendingPathComponent(rel)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path), let m = attrs[.modificationDate] as? Date, let size = attrs[.size] as? Int, size <= 4 * 1024 * 1024 else { continue }
                let tags: [String]
                if let c = cacheSnapshot[rel], c.mtime == m { tags = c.tags }
                else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) { tags = TagScanner.scan(data) } else { continue }
                newCache[rel] = (m, tags)
                for t in tags { map[t.lowercased(), default: []].append(rel) }
            }
            let sorted = map.map { (tag: $0.key, files: $0.value.sorted()) }.sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.cache = newCache
                self.tags = sorted
                self.observers.notify()
            }
        }
    }
}

/// 收藏（持久化）与最近（NSDocumentController）
@MainActor
enum Favorites {
    private static let key = "sidebar.favorites"
    static var urls: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: key); NotificationCenter.default.post(name: didChange, object: nil) }
    }
    static let didChange = Notification.Name("com.korako.quire.favoritesDidChange")
    static func contains(_ u: URL) -> Bool { urls.contains { $0.standardizedFileURL == u.standardizedFileURL } }
    static func toggle(_ u: URL) { if contains(u) { urls.removeAll { $0.standardizedFileURL == u.standardizedFileURL } } else { urls.append(u) } }
    static func remove(_ u: URL) { if contains(u) { urls.removeAll { $0.standardizedFileURL == u.standardizedFileURL } } }
    /// 文件改名 / 移动后收藏跟着走
    static func replace(_ old: URL, with new: URL) {
        guard contains(old) else { return }
        urls = urls.map { $0.standardizedFileURL == old.standardizedFileURL ? new : $0 }
    }
}
