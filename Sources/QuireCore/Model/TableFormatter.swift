import Foundation

/// Markdown 表格源码辅助（源码态编辑用）：识别表格行、格式化对齐、生成分隔行、单元格定位。
public enum TableFormatter {
    /// 是否像表格行：以 | 开头或至少含 2 个未转义的 |
    public static func isTableLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return t.hasPrefix("|") || unescapedPipeCount(t) >= 2
    }
    public static func isSeparatorLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.unicodeScalars.allSatisfy { "|:- ".unicodeScalars.contains($0) }
    }

    /// 拆单元格（去首尾 |，尊重 `\|`）
    public static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var cur = ""
        var prevBackslash = false
        for ch in t {
            if ch == "|", !prevBackslash { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" }
            else { cur.append(ch) }
            prevBackslash = ch == "\\"
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// 连续的表格行区间（含表头、分隔行、数据行），按行号
    public static func tableBlock(lines: [String], containing index: Int) -> ClosedRange<Int>? {
        guard index < lines.count, isTableLine(lines[index]) else { return nil }
        var lo = index, hi = index
        while lo > 0, isTableLine(lines[lo - 1]) { lo -= 1 }
        while hi + 1 < lines.count, isTableLine(lines[hi + 1]) { hi += 1 }
        return lo...hi
    }

    /// 把一组表格行格式化成各列等宽（CJK 算 2 格），分隔行按对齐标记保留；单元格数对齐到最多列
    public static func format(_ lines: [String]) -> [String] {
        let rows = lines.map(cells)
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return lines }
        var widths = [Int](repeating: 3, count: cols)
        var sepIndex: Int? = nil
        for (i, r) in rows.enumerated() {
            if isSeparatorLine(lines[i]) { sepIndex = i; continue }
            for (c, cell) in r.enumerated() { widths[c] = max(widths[c], displayWidth(cell)) }
        }
        var alignments = [Character?](repeating: nil, count: cols)   // l / c / r
        if let s = sepIndex {
            for (c, cell) in rows[s].enumerated() {
                let l = cell.hasPrefix(":"), r = cell.hasSuffix(":")
                alignments[c] = l && r ? "c" : (r ? "r" : (l ? "l" : nil))
            }
        }
        return rows.enumerated().map { (i, r) in
            var out = "|"
            for c in 0..<cols {
                if i == sepIndex {
                    let w = widths[c]
                    switch alignments[c] {
                    case "c": out += " :" + String(repeating: "-", count: max(1, w - 2)) + ": |"
                    case "r": out += " " + String(repeating: "-", count: max(1, w - 1)) + ": |"
                    case "l": out += " :" + String(repeating: "-", count: max(1, w - 1)) + " |"
                    default: out += " " + String(repeating: "-", count: w) + " |"
                    }
                } else {
                    let cell = c < r.count ? r[c] : ""
                    let pad = widths[c] - displayWidth(cell)
                    switch alignments[c] {
                    case "r": out += " " + String(repeating: " ", count: pad) + cell + " |"
                    case "c": out += " " + String(repeating: " ", count: pad / 2) + cell + String(repeating: " ", count: pad - pad / 2) + " |"
                    default: out += " " + cell + String(repeating: " ", count: pad) + " |"
                    }
                }
            }
            return out
        }
    }

    /// `| a | b |` 表头行 → 分隔行
    public static func separator(forHeader line: String) -> String {
        let n = max(1, cells(line).count)
        return "|" + String(repeating: " --- |", count: n)
    }

    /// 行内各单元格内容的字符范围（UTF-16，相对行首；不含两侧 |，含内边空格）
    public static func cellRanges(_ line: String) -> [NSRange] {
        let ns = line as NSString
        var bounds: [Int] = []   // 未转义 | 的位置
        var prevBackslash = false
        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            if ch == 0x7C, !prevBackslash { bounds.append(i) }
            prevBackslash = ch == 0x5C
        }
        guard !bounds.isEmpty else { return [NSRange(location: 0, length: ns.length)] }
        var ranges: [NSRange] = []
        let trimmedStart = ns.length - (line.drop(while: { $0 == " " }) as Substring).utf16.count
        if bounds[0] > trimmedStart { ranges.append(NSRange(location: 0, length: bounds[0])) }   // 开头没有 | 的首格
        for k in 0..<bounds.count {
            let start = bounds[k] + 1
            let end = k + 1 < bounds.count ? bounds[k + 1] : ns.length
            if end > start || k + 1 < bounds.count { ranges.append(NSRange(location: start, length: max(0, end - start))) }
        }
        // 末尾 | 之后只有空白 → 不是一格
        if let last = ranges.last, last.location == (bounds.last! + 1), ns.substring(with: last).trimmingCharacters(in: .whitespaces).isEmpty, bounds.count >= 2 { ranges.removeLast() }
        return ranges
    }

    static func unescapedPipeCount(_ s: String) -> Int {
        var n = 0, prev: Character = " "
        for ch in s { if ch == "|", prev != "\\" { n += 1 }; prev = ch }
        return n
    }
    static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (($1.value >= 0x1100 && $1.value <= 0x115F) || ($1.value >= 0x2E80 && $1.value <= 0xA4CF) || ($1.value >= 0xAC00 && $1.value <= 0xD7A3) || ($1.value >= 0xF900 && $1.value <= 0xFAFF) || ($1.value >= 0xFE30 && $1.value <= 0xFE4F) || ($1.value >= 0xFF00 && $1.value <= 0xFF60) || ($1.value >= 0xFFE0 && $1.value <= 0xFFE6) || $1.value >= 0x20000 ? 2 : 1) }
    }
}
