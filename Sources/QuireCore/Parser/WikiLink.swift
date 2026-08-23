import Foundation

/// `[[目标]]` / `[[目标 | 显示名]]` 维基链接（iA Writer / Obsidian 风格）。
/// 解析成 `.link(destination: "quire-wiki:目标", …)`；渲染层按 scheme 识别，导出为纯文本。
public enum WikiLink {
    public static let scheme = "quire-wiki:"

    /// 从文本节点里切出 wikilink；`[[x]]s` 的尾缀（复数 / 词形）留在后面的文本里自然显示
    static func split(_ s: String) -> [Inline] {
        guard s.contains("[[") else { return [.text(s)] }
        var out: [Inline] = []
        var rest = Substring(s)
        while let open = rest.range(of: "[[") {
            guard let close = rest[open.upperBound...].range(of: "]]") else { break }
            let inner = rest[open.upperBound..<close.lowerBound]
            if inner.isEmpty || inner.contains("\n") || inner.contains("[") { out.append(.text(String(rest[..<close.upperBound]))); rest = rest[close.upperBound...]; continue }
            if !rest[..<open.lowerBound].isEmpty { out.append(.text(String(rest[..<open.lowerBound]))) }
            let parts = inner.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let target = parts[0]
            let title = parts.count > 1 ? parts[1] : target
            out.append(.link(destination: scheme + target, title: nil, children: [.text(title)]))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return out.isEmpty ? [.text(s)] : out
    }

    public static func isWikiLink(_ destination: String?) -> Bool { destination?.hasPrefix(scheme) ?? false }
    public static func target(_ destination: String) -> String { String(destination.dropFirst(scheme.count)) }

    /// 就近解析：候选按"同目录 > 子目录 > 父目录（按距离）"排序；名字不分大小写、可不带扩展名、可带相对路径
    /// - candidates: 根目录下的相对路径列表（FileIndex 提供）
    /// - fromDir: 当前文档目录相对根目录的路径（"" = 根）
    public static func resolve(_ target: String, candidates: [String], fromDir: String) -> String? {
        let t = target.lowercased().replacingOccurrences(of: "\\", with: "/")
        let wantsPath = t.contains("/")
        func stem(_ p: String) -> String { (p as NSString).lastPathComponent.lowercased() }
        func withoutExt(_ n: String) -> String { (n as NSString).deletingPathExtension }
        var matches: [String] = []
        for c in candidates {
            let lc = c.lowercased()
            if wantsPath {
                if lc == t || withoutExt(lc) == t || lc.hasSuffix("/" + t) || withoutExt(lc).hasSuffix("/" + t) { matches.append(c) }
            } else {
                let s = stem(c)
                if s == t || withoutExt(s) == t { matches.append(c) }
            }
        }
        guard !matches.isEmpty else { return nil }
        let from = fromDir.lowercased().split(separator: "/").map(String.init)
        func distance(_ p: String) -> (Int, Int) {
            let dir = (p.lowercased() as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
            var common = 0
            while common < from.count, common < dir.count, from[common] == dir[common] { common += 1 }
            let up = from.count - common           // 要往上走几层
            let down = dir.count - common          // 再往下走几层
            // 同目录 (0,0) < 子目录 (0,n) < 父目录 (m,0) < 旁支
            return (up, down)
        }
        return matches.min { a, b in
            let da = distance(a), db = distance(b)
            if da.0 != db.0 { return da.0 < db.0 }
            if da.1 != db.1 { return da.1 < db.1 }
            return a.count < b.count
        }
    }
}
