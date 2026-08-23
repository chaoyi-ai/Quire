import Foundation

/// 文件名模糊匹配（快速打开 / wikilink 补全用）。子序列匹配 + 打分：
/// 边界处命中（开头、`/` `-` `_` `.` 空格之后、大小写切换）加分，连续命中加分，跨过的字符扣分，文件名部分命中按 2 倍计。
/// 全部在 unicodeScalars 上做，大小写不敏感；CJK 逐字比较。
public enum FuzzyMatcher {
    public struct Match: Equatable, Sendable {
        public var score: Int
        public var positions: [Int]   // 命中的 scalar 下标（用于高亮）
        public init(score: Int, positions: [Int]) { self.score = score; self.positions = positions }
    }

    public static func match(query: String, candidate: String) -> Match? {
        let q = Array(query.lowercased().unicodeScalars)
        guard !q.isEmpty else { return Match(score: 0, positions: []) }
        let c = Array(candidate.unicodeScalars)
        let cl = Array(candidate.lowercased().unicodeScalars)
        guard cl.count == c.count else { return slowMatch(q, c) }
        let n = c.count, m = q.count
        guard m <= n else { return nil }
        let lastSlash = c.lastIndex(of: "/") ?? -1
        // DP：dp[j][k] = q[0...j] 匹配且 q[j] 落在 c[k] 的最高分；贪心取最早出现会把 "d" 配到目录名上，DP 才能选文件名开头
        let none = Int.min / 4
        var dp = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
        var back = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
        @inline(__always) func placement(_ k: Int) -> Int {
            var s = 1
            if k == 0 || isBoundary(c, k) { s += 10 }
            return k > lastSlash ? s * 2 : s
        }
        for k in 0..<n where cl[k] == q[0] { dp[0][k] = placement(k) - min(k, 10) }
        if m > 1 {
            for j in 1..<m {
                for k in j..<n where cl[k] == q[j] {
                    var best = none, bi = -1
                    for p in (j - 1)..<k where dp[j - 1][p] != none {
                        let consec = k == p + 1 ? 8 : 0
                        let gap = min(k - p - 1, 10)
                        let v = dp[j - 1][p] + placement(k) + (k > lastSlash ? consec * 2 : consec) - gap
                        if v > best { best = v; bi = p }
                    }
                    if bi >= 0 { dp[j][k] = best; back[j][k] = bi }
                }
            }
        }
        var endK = -1, endScore = none
        for k in 0..<n where dp[m - 1][k] > endScore { endScore = dp[m - 1][k]; endK = k }
        guard endK >= 0 else { return nil }
        var positions = [Int](repeating: 0, count: m)
        var k = endK
        for j in stride(from: m - 1, through: 0, by: -1) { positions[j] = k; k = back[j][k] }
        var score = endScore - n / 8                    // 短路径略占优
        if positions.allSatisfy({ $0 > lastSlash }) { score += 15 }   // 全部命中在文件名里
        return Match(score: score, positions: positions)
    }

    private static func isBoundary(_ c: [Unicode.Scalar], _ k: Int) -> Bool {
        guard k > 0 else { return true }
        let p = c[k - 1]
        if p == "/" || p == "-" || p == "_" || p == " " || p == "." { return true }
        // 小写 → 大写切换（camelCase）
        return p.properties.isLowercase && c[k].properties.isUppercase
    }

    /// lowercased 改变了 scalar 数量（极少数脚本）时的退路：不区分大小写逐 scalar 比较
    private static func slowMatch(_ q: [Unicode.Scalar], _ c: [Unicode.Scalar]) -> Match? {
        var positions: [Int] = []; var i = 0
        for qc in q {
            var found = -1
            var k = i
            while k < c.count { if String(c[k]).lowercased() == String(qc).lowercased() { found = k; break }; k += 1 }
            guard found >= 0 else { return nil }
            positions.append(found); i = found + 1
        }
        return Match(score: positions.count, positions: positions)
    }

    /// 对一组候选排序：分数高在前，同分短的在前
    public static func rank(query: String, candidates: [String], limit: Int = 50) -> [(String, Match)] {
        var out: [(String, Match)] = []
        for c in candidates { if let m = match(query: query, candidate: c) { out.append((c, m)) } }
        out.sort { a, b in a.1.score != b.1.score ? a.1.score > b.1.score : a.0.count < b.0.count }
        return Array(out.prefix(limit))
    }
}
