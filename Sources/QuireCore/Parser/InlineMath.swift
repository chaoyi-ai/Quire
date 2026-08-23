import Foundation

/// `$…$` 行内数学切分（Pandoc 规则）：
/// 开头 `$` 后面不能是空白或 `$`；结尾 `$` 前面不能是空白或反斜杠，后面不能紧跟数字（`$2 和 $3` 是钱不是公式）；中间非空。
enum InlineMath {
    /// 把成对的独占行 `$$` 改写为 ```math / ```（同行数），跳过已有围栏内部。
    static func rewriteDisplayBlocks(_ s: String) -> String {
        guard s.contains("$$") else { return s }
        var out: [Substring] = []
        var inFence: Substring? = nil     // 当前围栏的标记（``` 或 ~~~ 及其长度）
        var inMath = false
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line[line.startIndex..<t.startIndex]
            if indent.count > 3 { out.append(line); continue }
            if let f = inFence {
                if t.hasPrefix(f) { inFence = nil }
                out.append(line); continue
            }
            if !inMath, t.hasPrefix("```") || t.hasPrefix("~~~") {
                let ch = t.first!
                inFence = t.prefix(while: { $0 == ch })
                out.append(line); continue
            }
            if t.trimmingCharacters(in: .whitespaces) == "$$" {
                // 保留缩进：列表项里的 $$ 块得留在列表项里
                out.append(indent + (inMath ? "```" : "```math")); inMath.toggle(); continue
            }
            out.append(line)
        }
        if inMath { return s }   // 没闭合：原样交给 cmark
        return out.joined(separator: "\n")
    }

    static func split(_ s: String) -> [Inline] {
        guard s.contains("$") else { return [.text(s)] }
        let u = Array(s.utf16)
        var out: [Inline] = []
        var textStart = 0
        var i = 0
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A }
        func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
        while i < u.count {
            guard u[i] == 0x24 /* $ */, i + 1 < u.count, !isSpace(u[i + 1]), u[i + 1] != 0x24 else { i += 1; continue }
            // 找结尾
            var j = i + 2
            var found = -1
            while j < u.count {
                if u[j] == 0x24, !isSpace(u[j - 1]), u[j - 1] != 0x5C, j + 1 >= u.count || !isDigit(u[j + 1]) { found = j; break }
                j += 1
            }
            guard found > i + 1 else { i += 1; continue }
            if found - 1 - (i + 1) < 0 { i += 1; continue }
            if textStart < i { out.append(.text(String(utf16CodeUnits: Array(u[textStart..<i]), count: i - textStart))) }
            out.append(.inlineMath(String(utf16CodeUnits: Array(u[(i + 1)..<found]), count: found - i - 1)))
            i = found + 1
            textStart = i
        }
        if textStart < u.count { out.append(.text(String(utf16CodeUnits: Array(u[textStart..<u.count]), count: u.count - textStart))) }
        return out.isEmpty ? [.text(s)] : out
    }
}
