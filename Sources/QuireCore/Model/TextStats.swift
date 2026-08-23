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
        // 热路径不碰 Unicode.Scalar.Properties（ICU 查表，每次 ~30 ns；1 MB 全走它要 36 ms）：
        // ASCII / CJK / 常见字母区直接按范围判断，只有罕见字符才查属性。
        for u in s.unicodeScalars {
            let v = u.value
            sawAny = true
            if v < 0x80 {
                if v == 0x0A { st.lines += 1; inWord = false; continue }
                if v == 0x20 || v == 0x09 || v == 0x0D || v == 0x0B || v == 0x0C { inWord = false; continue }
                st.characters += 1
                if (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x27 || v == 0x5F {
                    if !inWord { st.words += 1; inWord = true }
                } else { inWord = false }
                continue
            }
            if isCJK(v) { st.characters += 1; st.words += 1; st.cjkCharacters += 1; inWord = false; continue }
            if v == 0x3000 || v == 0xA0 || v == 0x2028 || v == 0x2029 || (v >= 0x2000 && v <= 0x200A) { inWord = false; continue }
            st.characters += 1
            if (v >= 0x3000 && v <= 0x303F) || (v >= 0xFF00 && v <= 0xFF0F) || (v >= 0xFF1A && v <= 0xFF20) || (v >= 0xFF3B && v <= 0xFF40) || (v >= 0xFF5B && v <= 0xFF65) || (v >= 0x2010 && v <= 0x2027) || (v >= 0x2030 && v <= 0x205E) {
                inWord = false   // CJK / 全角 / 通用标点
            } else if (v >= 0xC0 && v <= 0x24F) || (v >= 0x370 && v <= 0x52F) || (v >= 0xFF10 && v <= 0xFF19) || (v >= 0xFF21 && v <= 0xFF3A) || (v >= 0xFF41 && v <= 0xFF5A) || isWordScalar(u) {
                if !inWord { st.words += 1; inWord = true }   // 带音标拉丁 / 希腊 / 西里尔 / 全角字母数字 / 其他字母
            } else {
                inWord = false
            }
        }
        if sawAny, !s.hasSuffix("\n") { st.lines += 1 }
        return st
    }

    @inline(__always) private static func isCJK(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2FA1F).contains(v) ||
        (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v)
    }
    /// 罕见字符才走这里（ICU 属性查表）
    private static func isWordScalar(_ u: Unicode.Scalar) -> Bool {
        u.properties.isAlphabetic || u.properties.numericType != nil
    }
}
