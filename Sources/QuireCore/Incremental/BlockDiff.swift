import Foundation

/// 块级增量 diff：找出新旧块序列的公共前缀 / 后缀，中间部分视为被替换。
/// 编辑场景几乎总是单点修改，O(n) 前后缀足够；渲染层只需重建 `newChanged` 范围内的块。
public struct BlockDiff: Hashable, Sendable {
    /// 旧序列中被替换的范围
    public var oldChanged: Range<Int>
    /// 新序列中被替换的范围
    public var newChanged: Range<Int>

    public var isEmpty: Bool { oldChanged.isEmpty && newChanged.isEmpty }

    public static func compute(old: [Block], new: [Block]) -> BlockDiff {
        let n = old.count, m = new.count
        var p = 0
        while p < n, p < m, old[p].contentHash == new[p].contentHash, old[p].kind == new[p].kind { p += 1 }
        var s = 0
        while s < n - p, s < m - p, old[n - 1 - s].contentHash == new[m - 1 - s].contentHash, old[n - 1 - s].kind == new[m - 1 - s].kind { s += 1 }
        return BlockDiff(oldChanged: p..<(n - s), newChanged: p..<(m - s))
    }
}
