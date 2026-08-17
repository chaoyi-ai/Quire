import Foundation

/// 内置 + 用户主题集合。加载失败的主题记录在 `errors`，不静默。
public struct ThemeCatalog: Sendable {
    public var themes: [Theme]              // 按名称排序
    public var errors: [ThemeLoadFailure]

    public func theme(id: String) -> Theme? { themes.first { $0.id == id } }
    public func themes(for appearance: Appearance) -> [Theme] { themes.filter { $0.appearance == appearance } }
    public var byID: [String: Theme] { Dictionary(themes.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }) }
    public static let empty = ThemeCatalog(themes: [], errors: [])
}

public struct ThemeLoadFailure: Sendable, CustomStringConvertible {
    public var path: String
    public var error: ThemeError
    public var description: String { "\(path): \(error)" }
}

public enum ThemeStore {
    /// 用户主题目录：`~/Library/Application Support/Quire/Themes`
    public static var userThemesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Quire/Themes", isDirectory: true)
    }

    public static var builtInDirectory: URL? {
        Bundle.module.url(forResource: "Themes", withExtension: nil)
    }

    /// 只加载内置主题（同步，通常 < 5 ms）
    public static func loadBuiltIn() -> ThemeCatalog {
        guard let dir = builtInDirectory else { return .empty }
        return load(directories: [dir])
    }

    /// 内置 + 用户目录；用户主题同 id 覆盖内置
    public static func loadAll(userDirectory: URL? = nil) -> ThemeCatalog {
        var dirs: [URL] = []
        if let b = builtInDirectory { dirs.append(b) }
        dirs.append(userDirectory ?? userThemesDirectory)
        return load(directories: dirs)
    }

    /// 加载顺序（每个目录内）：默认主题 → 无 extends 主题 → extends 主题，保证基底先就绪。
    public static func load(directories: [URL]) -> ThemeCatalog {
        var loader = ThemeLoader()
        var errors: [ThemeLoadFailure] = []
        let fm = FileManager.default

        struct Candidate { let url: URL; let data: Data; let id: String?; let extends: Bool }

        for dir in directories {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            var candidates: [Candidate] = []
            for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
                guard let data = try? Data(contentsOf: url) else { continue }
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                candidates.append(Candidate(url: url, data: data, id: obj?["id"] as? String, extends: obj?["extends"] != nil))
            }
            let defaultIDs = Set(loader.defaults.values)
            func rank(_ c: Candidate) -> Int {
                if let id = c.id, defaultIDs.contains(id) { return 0 }
                return c.extends ? 2 : 1
            }
            candidates.sort { (rank($0), $0.url.lastPathComponent) < (rank($1), $1.url.lastPathComponent) }

            for c in candidates {
                do {
                    let t = try loader.load(data: c.data, sourcePath: c.url.path)
                    loader.available[t.id] = t
                } catch let e as ThemeError {
                    errors.append(.init(path: c.url.path, error: e))
                } catch {
                    errors.append(.init(path: c.url.path, error: .invalidJSON(error.localizedDescription)))
                }
            }
        }
        let themes = loader.available.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ThemeCatalog(themes: themes, errors: errors)
    }
}
