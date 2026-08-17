import Foundation

/// 快速标题扫描：只识别 ATX（`# x`）与 setext（下一行 `===`/`---`）标题，跳过围栏代码块与 front matter。
/// 用于侧栏里"非当前文档"的大纲预览：不建 AST，UTF-8 单趟，~100+ MB/s。
/// 与完整解析的差异（缩进代码块里的 #、列表内标题等）对导航来说可以接受；当前文档始终用完整解析结果。
public enum HeadingScanner {
    public struct Heading: Hashable, Sendable {
        public var level: Int
        public var title: String
        public var line: Int   // 1-based
    }

    public static func scan(_ data: Data, maxHeadings: Int = 2000) -> [Heading] {
        var out: [Heading] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            var lineNo = 0
            var fenceChar: UInt8 = 0, fenceLen = 0
            var inFrontMatter = false
            var prevLine: (start: Int, end: Int, indent: Int)? = nil   // 上一行（用于 setext）

            func lineText(_ s: Int, _ e: Int) -> String {
                var end = e
                while end > s, base[end - 1] == 0x20 || base[end - 1] == 0x09 || base[end - 1] == 0x0D { end -= 1 }
                return String(decoding: UnsafeBufferPointer(start: base + s, count: end - s), as: UTF8.self)
            }

            while i < n && out.count < maxHeadings {
                let ls = i
                while i < n, base[i] != 0x0A { i += 1 }
                let le = i
                i += 1
                lineNo += 1
                // 缩进
                var p = ls, indent = 0
                while p < le, base[p] == 0x20, indent < 4 { p += 1; indent += 1 }
                let c: UInt8 = p < le ? base[p] : 0

                // front matter
                if lineNo == 1, isRule(base, p, le, 0x2D), indent == 0 { inFrontMatter = true; prevLine = nil; continue }
                if inFrontMatter {
                    if isRule(base, p, le, 0x2D) || (c == 0x2E && p + 2 < le && base[p + 1] == 0x2E && base[p + 2] == 0x2E) { inFrontMatter = false }
                    prevLine = nil; continue
                }
                // 围栏
                if indent < 4, c == 0x60 || c == 0x7E {
                    var k = p; while k < le, base[k] == c { k += 1 }
                    let len = k - p
                    if len >= 3 {
                        if fenceChar == 0 { fenceChar = c; fenceLen = len; prevLine = nil; continue }
                        if c == fenceChar, len >= fenceLen { fenceChar = 0; prevLine = nil; continue }
                    }
                }
                if fenceChar != 0 { prevLine = nil; continue }
                if p >= le { prevLine = nil; continue }   // 空行

                // ATX
                if c == 0x23, indent < 4 {
                    var k = p; while k < le, base[k] == 0x23, k - p < 6 { k += 1 }
                    let level = k - p
                    if k >= le || base[k] == 0x20 || base[k] == 0x09 {
                        var t = k; while t < le, base[t] == 0x20 { t += 1 }
                        var tEnd = le
                        while tEnd > t, base[tEnd - 1] == 0x20 || base[tEnd - 1] == 0x0D { tEnd -= 1 }
                        var hEnd = tEnd
                        while hEnd > t, base[hEnd - 1] == 0x23 { hEnd -= 1 }
                        if hEnd < tEnd, hEnd == t || base[hEnd - 1] == 0x20 { tEnd = hEnd; while tEnd > t, base[tEnd - 1] == 0x20 { tEnd -= 1 } }
                        out.append(Heading(level: level, title: lineText(t, tEnd), line: lineNo))
                        prevLine = nil
                        continue
                    }
                }
                // setext：上一行是普通文本，本行全是 = 或 -
                if let prev = prevLine, indent < 4, prev.indent < 4, (isRule(base, p, le, 0x3D, allowSpaces: false) || isRule(base, p, le, 0x2D, allowSpaces: false)) {
                    let level = c == 0x3D ? 1 : 2
                    let title = lineText(prev.start + prev.indent, prev.end)
                    if !title.isEmpty, !title.hasPrefix("- "), !title.hasPrefix("* "), !title.hasPrefix(">"), !title.hasPrefix("|") {
                        out.append(Heading(level: level, title: title, line: lineNo - 1))
                        prevLine = nil
                        continue
                    }
                }
                prevLine = (ls, le, indent)
            }
        }
        return out
    }

    /// 至少 3 个 `char`，其余仅空白。allowSpaces=false（setext 下划线）时 char 之间不允许空白，只允许尾随空白。
    private static func isRule(_ base: UnsafePointer<UInt8>, _ s: Int, _ e: Int, _ char: UInt8, allowSpaces: Bool = true) -> Bool {
        var count = 0
        var seenSpaceAfterChar = false
        for k in s..<e {
            let b = base[k]
            if b == char {
                if seenSpaceAfterChar && !allowSpaces { return false }
                count += 1
            } else if b == 0x20 || b == 0x09 || b == 0x0D {
                if count > 0 { seenSpaceAfterChar = true }
            } else {
                return false
            }
        }
        return count >= 3
    }
}
