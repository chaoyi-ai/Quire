import Foundation

/// 文本统计：字词 / 字符 / 行 / 阅读时间。单趟扫描 unicodeScalars，1 MB < 5 ms。
/// 计数规则：CJK（汉字 / 假名 / 谚文）每个字算一个"字词"；其他文字按字母数字连续段算一个词；空白与标点分隔。
public struct TextStats: Equatable, Sendable {
    public var words = 0            // 字词（CJK 字 + 拉丁词）
    public var cjkCharacters = 0    // 其中 CJK 字数
    public var characters = 0       // 非空白字符数
    public var lines = 0            // 行数（按 \n，末尾无换行也算一行）
    public init() {}

    /// 阅读时间（分钟，向上取整）：中文 400 字 / 分钟，其他 200 词 / 分钟
    public var readingMinutes: Int {
        let latin = words - cjkCharacters
        let minutes = Double(cjkCharacters) / 400 + Double(latin) / 200
        return words == 0 ? 0 : max(1, Int(minutes.rounded(.up)))
    }

    public static func compute(_ s: String) -> TextStats {
        var st = TextStats()
        var inWord = false
        var sawAny = false
        for u in s.unicodeScalars {
            let v = u.value
            sawAny = true
            if v == 0x0A { st.lines += 1; inWord = false; continue }
            if v == 0x20 || v == 0x09 || v == 0x0D || u.properties.isWhitespace { inWord = false; continue }
            st.characters += 1
            if isCJK(v) {
                st.words += 1; st.cjkCharacters += 1; inWord = false
            } else if isWordScalar(u) {
                if !inWord { st.words += 1; inWord = true }
            } else {
                inWord = false   // 标点等
            }
        }
        if sawAny, !s.hasSuffix("\n") { st.lines += 1 }
        return st
    }

    @inline(__always) private static func isCJK(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2FA1F).contains(v) ||
        (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v)
    }
    @inline(__always) private static func isWordScalar(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        if v < 0x80 { return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x27 || v == 0x5F }
        return u.properties.isAlphabetic || u.properties.numericType != nil
    }
}
