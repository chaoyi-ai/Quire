import Foundation

/// 全文搜索扫描器：对一组文件做子串 / 正则匹配，流式回调（每个文件的命中一到就回调），可取消。
/// 子串匹配走 mmap + memchr 首字节跳跃，不把整个文件转成 String；命中行再解码。
/// 大小写不敏感时 ASCII 直接比较、非 ASCII 回退到 String 比较（只在候选行上做）。
public final class ContentSearch: @unchecked Sendable {
    public struct Hit: Sendable, Equatable {
        public var line: Int          // 1-based
        public var column: Int        // 1-based，UTF-16 单元（与 text / range 同一坐标）
        public var text: String       // 该行文本（去掉换行）
        public var range: Range<Int>  // 命中在 text 里的 UTF-16 范围（用于高亮）
    }
    public struct FileResult: Sendable {
        public var url: URL
        public var hits: [Hit]
    }
    public struct Options: Sendable {
        public var caseSensitive = false
        public var regex = false
        public var maxHitsPerFile = 200
        public var maxFileBytes = 8 * 1024 * 1024
        public init() {}
    }

    private let cancelled = NSLock()
    private var _cancelled = false
    public var isCancelled: Bool { cancelled.lock(); defer { cancelled.unlock() }; return _cancelled }
    public func cancel() { cancelled.lock(); _cancelled = true; cancelled.unlock() }
    public init() {}

    /// 一次扫描的统计：被跳过的文件（读不了 / 超过 maxFileBytes）——"没有找到"和"有 3 个文件没搜"是两回事
    public struct Summary: Sendable { public var skippedUnreadable = 0; public var skippedTooLarge = 0; public var invalidPattern = false }

    /// 同步扫描（调用方放后台线程）；`onFile` 在扫描线程上回调。返回跳过统计
    @discardableResult
    public func run(query: String, files: [URL], options: Options = Options(), onFile: (FileResult) -> Void) -> Summary {
        var summary = Summary()
        guard !query.isEmpty else { return summary }
        let regex: NSRegularExpression?
        if options.regex {
            guard let r = try? NSRegularExpression(pattern: query, options: options.caseSensitive ? [] : [.caseInsensitive]) else { summary.invalidPattern = true; return summary }
            regex = r
        } else { regex = nil }
        let needle = Array(query.utf8)
        let needleLower = Array(query.lowercased().utf8)
        let asciiNeedle = needle.allSatisfy { $0 < 0x80 }
        for url in files {
            if isCancelled { return summary }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { summary.skippedUnreadable += 1; continue }
            guard data.count <= options.maxFileBytes else { summary.skippedTooLarge += 1; continue }
            guard !data.isEmpty else { continue }
            var hits: [Hit] = []
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let n = raw.count
                var lineStart = 0, lineNo = 1
                while lineStart < n, hits.count < options.maxHitsPerFile {
                    // 找行尾
                    var lineEnd = lineStart
                    if let p = memchr(base + lineStart, 0x0A, n - lineStart) { lineEnd = UnsafeRawPointer(p) - UnsafeRawPointer(base) } else { lineEnd = n }
                    let lineLen = lineEnd - lineStart
                    if lineLen >= needle.count || regex != nil {
                        let lineBuf = UnsafeBufferPointer(start: base + lineStart, count: lineLen)
                        if let regex {
                            let text = String(decoding: lineBuf, as: UTF8.self)
                            let ns = text as NSString
                            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                                hits.append(Hit(line: lineNo, column: m.range.location + 1, text: text, range: m.range.location..<(m.range.location + m.range.length)))
                                if hits.count >= options.maxHitsPerFile { break }
                            }
                        } else if let col = Self.find(needle: needle, needleLower: needleLower, asciiNeedle: asciiNeedle, caseSensitive: options.caseSensitive, in: lineBuf) {
                            let text = String(decoding: lineBuf, as: UTF8.self)
                            // 行内全部命中
                            var searchStart = 0
                            let ns = text as NSString
                            let opts: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
                            _ = col
                            while searchStart < ns.length, hits.count < options.maxHitsPerFile {
                                let r = ns.range(of: query, options: opts, range: NSRange(location: searchStart, length: ns.length - searchStart))
                                guard r.location != NSNotFound else { break }
                                hits.append(Hit(line: lineNo, column: r.location + 1, text: text, range: r.location..<(r.location + r.length)))
                                searchStart = r.location + max(1, r.length)
                            }
                        }
                    }
                    lineStart = lineEnd + 1
                    lineNo += 1
                }
            }
            if !hits.isEmpty { onFile(FileResult(url: url, hits: hits)) }
        }
        return summary
    }

    /// 行内快速预筛：ASCII 不区分大小写时把行字节折成小写比较；非 ASCII 或区分大小写直接 memcmp 滑动；
    /// 非 ASCII 且不区分大小写 → 交给 String（只在长度足够的行上）
    private static func find(needle: [UInt8], needleLower: [UInt8], asciiNeedle: Bool, caseSensitive: Bool, in line: UnsafeBufferPointer<UInt8>) -> Int? {
        let n = line.count, m = needle.count
        guard m > 0, n >= m, let base = line.baseAddress else { return nil }
        if caseSensitive || asciiNeedle {
            let first = caseSensitive ? needle[0] : needleLower[0]
            let firstUpper = caseSensitive ? first : (first >= 0x61 && first <= 0x7A ? first - 0x20 : first)
            var i = 0
            while i + m <= n {
                let b = base[i]
                if b == first || b == firstUpper {
                    var k = 1
                    while k < m {
                        var c = base[i + k]
                        if !caseSensitive, c >= 0x41, c <= 0x5A { c += 0x20 }
                        if c != (caseSensitive ? needle[k] : needleLower[k]) { break }
                        k += 1
                    }
                    if k == m { return i }
                }
                i += 1
            }
            return nil
        }
        // 非 ASCII + 不区分大小写：解码后比较
        let s = String(decoding: line, as: UTF8.self)
        return s.range(of: String(decoding: needle, as: UTF8.self), options: .caseInsensitive) != nil ? 0 : nil
    }
}
