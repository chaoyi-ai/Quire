import Foundation

/// `#标签` 扫描（Twitter 规则：`#` 后紧跟字母 / 数字 / CJK / 下划线，前面不能是字母数字；`#` 后是空格的是标题；围栏代码里不算）。
public enum TagScanner {
    /// 返回文件里出现的标签（去重、保留首次出现顺序）
    public static func scan(_ data: Data, maxTags: Int = 200) -> [String] {
        var tags: [String] = []
        var seen = Set<String>()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            var inFence = false
            var lineStart = true
            while i < n, tags.count < maxTags {
                let b = base[i]
                if lineStart {
                    // 围栏
                    var k = i; while k < n, base[k] == 0x20 { k += 1 }
                    if k + 2 < n, (base[k] == 0x60 && base[k+1] == 0x60 && base[k+2] == 0x60) || (base[k] == 0x7E && base[k+1] == 0x7E && base[k+2] == 0x7E) { inFence.toggle(); while i < n, base[i] != 0x0A { i += 1 }; lineStart = true; i += 1; continue }
                    lineStart = false
                }
                if b == 0x0A { lineStart = true; i += 1; continue }
                if inFence { i += 1; continue }
                if b == 0x23 {
                    let prev: UInt8 = i == 0 ? 0x20 : base[i - 1]
                    let prevOK = !isAlnum(prev) && prev != 0x23 && prev != 0x2F && prev != 0x2E && prev != 0x26   // 不在 URL / 实体里
                    var j = i + 1
                    while j < n, isTagByte(base[j]) { j += 1 }
                    if prevOK, j > i + 1 {
                        // 解码后按 scalar 截到第一个非 字母/数字/下划线/CJK 处（CJK 标点在 UTF-8 里也是 ≥0x80 的字节）
                        let raw = String(decoding: UnsafeBufferPointer(start: base + i + 1, count: j - i - 1), as: UTF8.self)
                        let tag = String(String.UnicodeScalarView(raw.unicodeScalars.prefix { isTagScalar($0) }))
                        if isValid(tag), !seen.contains(tag.lowercased()) { seen.insert(tag.lowercased()); tags.append(tag) }
                    }
                    i = max(j, i + 1); continue
                }
                i += 1
            }
        }
        return tags
    }

    private static func isTagScalar(_ u: Unicode.Scalar) -> Bool {
        if u == "_" { return true }
        let v = u.value
        if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) { return true }
        if v < 0x80 { return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) }
        return u.properties.isAlphabetic || u.properties.numericType != nil
    }
    private static func isAlnum(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b >= 0x80 }
    private static func isTagByte(_ b: UInt8) -> Bool { isAlnum(b) || b == 0x5F }
    /// 全数字（如 #1、#123 issue 号）、颜色（#fff）、不算标签
    private static func isValid(_ t: String) -> Bool {
        guard let f = t.unicodeScalars.first else { return false }
        if t.allSatisfy({ $0.isNumber }) { return false }
        // 颜色值：3 / 6 / 8 位十六进制且至少含一个数字（#fff 这种纯字母的也算，但 #cafe / #bad / #beef 是词不是色）
        if [3, 6, 8].contains(t.count), t.allSatisfy({ $0.isHexDigit }), t.contains(where: { $0.isNumber }) || t.count == 3 && t.allSatisfy({ "fF".contains($0) || $0.isNumber }) { return false }
        return f.properties.isAlphabetic || f == "_" || (0x4E00...0x9FFF).contains(f.value)
    }
}
