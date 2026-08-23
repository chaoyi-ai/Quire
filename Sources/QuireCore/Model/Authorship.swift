import Foundation

/// 著作归属（iA Writer Authorship 的思路）：记录文档里哪些区间是谁写的——我键入的、AI 粘贴的、引用来的、自定义作者。
///
/// - 区间按 UTF-16 偏移（与 NSTextView 一致），互不重叠、按位置排序、相邻同作者合并
/// - 存在文件尾的 HTML 注释块里（`<!-- quire-authorship v1 hash=… … -->`），正文本身不变；注释块带正文哈希，
///   外部改过正文对不上哈希时整块丢弃（区间对不上还不如没有）
/// - 编辑时 `apply(replacing:withLength:author:)` 增量维护；没记录的区间（开启之前写的）就是"无归属"
public struct Authorship: Codable, Equatable, Sendable {
    public struct Author: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// `#RRGGBB`
        public var color: String
        public init(id: String, name: String, color: String) { self.id = id; self.name = name; self.color = color }
    }
    public struct Span: Equatable, Sendable {
        public var author: String
        public var start: Int
        public var length: Int
        public var end: Int { start + length }
        public init(author: String, start: Int, length: Int) { self.author = author; self.start = start; self.length = length }
    }

    public var authors: [Author]
    public var spans: [Span]

    public static let me = Author(id: "me", name: "我", color: "#3B82F6")
    public static let paste = Author(id: "paste", name: "粘贴", color: "#F59E0B")
    public static let ai = Author(id: "ai", name: "AI", color: "#A855F7")
    public static let quote = Author(id: "quote", name: "引用", color: "#22C55E")
    public static let defaultAuthors = [me, paste, ai, quote]
    /// 自定义作者轮流用的颜色
    public static let palette = ["#EC4899", "#14B8A6", "#F97316", "#6366F1", "#84CC16", "#EF4444"]

    public init(authors: [Author] = Authorship.defaultAuthors, spans: [Span] = []) { self.authors = authors; self.spans = spans }

    public func author(_ id: String) -> Author? { authors.first { $0.id == id } }

    @discardableResult
    public mutating func addAuthor(named name: String) -> Author {
        if let a = authors.first(where: { $0.name == name }) { return a }
        let custom = authors.filter { !Self.defaultAuthors.contains($0) }.count
        var id = name.lowercased().replacingOccurrences(of: " ", with: "-")
        if id.isEmpty || authors.contains(where: { $0.id == id }) { id = "a\(authors.count + 1)" }
        let a = Author(id: id, name: name, color: Self.palette[custom % Self.palette.count])
        authors.append(a)
        return a
    }

    // MARK: - 编辑维护

    /// 文本 `[start, start+length)` 被替换成 `newLength` 个字符；新内容归 `author`（nil = 无归属）
    public mutating func apply(replacing start: Int, length: Int, withLength newLength: Int, author: String?) {
        let end = start + length
        let delta = newLength - length
        var out: [Span] = []
        out.reserveCapacity(spans.count + 2)
        for s in spans {
            if s.end <= start { out.append(s); continue }                       // 完全在前
            if s.start >= end { out.append(Span(author: s.author, start: s.start + delta, length: s.length)); continue }   // 完全在后：平移
            // 有交集：保留替换区间之外的两头
            if s.start < start { out.append(Span(author: s.author, start: s.start, length: start - s.start)) }
            if s.end > end { out.append(Span(author: s.author, start: end + delta, length: s.end - end)) }
        }
        if newLength > 0, let author { out.append(Span(author: author, start: start, length: newLength)) }
        spans = out
        normalize()
    }

    /// 把一段标成某作者（nil = 清除归属）
    public mutating func assign(start: Int, length: Int, author: String?) {
        apply(replacing: start, length: length, withLength: length, author: author)
    }

    /// 排序、去空、相邻同作者合并；`textLength` 给了就裁掉越界的
    public mutating func normalize(textLength: Int? = nil) {
        var xs = spans.filter { $0.length > 0 && $0.start >= 0 }
        if let n = textLength { xs = xs.compactMap { s in s.start >= n ? nil : Span(author: s.author, start: s.start, length: min(s.length, n - s.start)) } }
        xs.sort { $0.start != $1.start ? $0.start < $1.start : $0.length > $1.length }
        var out: [Span] = []
        for s in xs {
            if let last = out.last, last.end >= s.start {
                if last.author == s.author { out[out.count - 1].length = max(last.end, s.end) - last.start; continue }
                if last.end >= s.end { continue }   // 被完全覆盖
                out.append(Span(author: s.author, start: last.end, length: s.end - last.end)); continue
            }
            out.append(s)
        }
        spans = out
    }

    /// 各作者的字符数（无归属不算）
    public var characterCounts: [String: Int] {
        var d: [String: Int] = [:]
        for s in spans { d[s.author, default: 0] += s.length }
        return d
    }

    // MARK: - 文件尾注释块

    public static let marker = "<!-- quire-authorship"

    /// 把正文与注释块分开。`mismatch`：有注释块但哈希对不上（正文被外部改过）→ 返回的 authorship 只保留作者表、区间清空
    public static func split(_ source: String) -> (body: String, authorship: Authorship?, mismatch: Bool) {
        guard let r = source.range(of: marker, options: .backwards) else { return (source, nil, false) }
        let tail = source[r.lowerBound...]
        guard tail.hasSuffix("-->\n") || tail.hasSuffix("-->") else { return (source, nil, false) }
        var body = String(source[..<r.lowerBound])
        if body.hasSuffix("\n\n") { body.removeLast() }   // embed 时在正文后加的那个空行
        // 首行：<!-- quire-authorship v1 hash=XXXX
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3 else { return (body, nil, false) }
        let header = lines[0]
        let hash = header.split(separator: " ").first { $0.hasPrefix("hash=") }.map { String($0.dropFirst(5)) }
        let json = lines[1..<(lines.count - 1)].joined(separator: "\n").replacingOccurrences(of: "-->", with: "")
        guard let data = json.data(using: .utf8), let a = try? JSONDecoder().decode(Authorship.self, from: data) else { return (body, nil, false) }
        if let hash, hash != Self.hash(body) {
            return (body, Authorship(authors: a.authors, spans: []), true)
        }
        var fixed = a
        fixed.normalize(textLength: (body as NSString).length)
        return (body, fixed, false)
    }

    /// 正文 + 注释块（没有区间时只返回正文——不往干净文件里塞东西）
    public func embed(into body: String) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard !spans.isEmpty, let data = try? enc.encode(self), let json = String(data: data, encoding: .utf8) else { return body }
        var out = body
        if !out.hasSuffix("\n") { out += "\n" }
        // 哈希算的是补过换行的正文：split 恢复出来的正文就是这个样子
        return out + "\n\(Self.marker) v1 hash=\(Self.hash(out))\n\(json)\n-->\n"
    }

    /// FNV-1a 64 位，十六进制
    public static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: - Codable（区间存成 [author, start, length] 数组，省空间）

    enum CodingKeys: String, CodingKey { case authors, spans }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authors = try c.decode([Author].self, forKey: .authors)
        let raw = try c.decode([[SpanValue]].self, forKey: .spans)
        spans = raw.compactMap { r in
            guard r.count == 3, case .s(let a) = r[0], case .i(let st) = r[1], case .i(let len) = r[2] else { return nil }
            return Span(author: a, start: st, length: len)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(authors, forKey: .authors)
        try c.encode(spans.map { [SpanValue.s($0.author), .i($0.start), .i($0.length)] }, forKey: .spans)
    }
    enum SpanValue: Codable {
        case s(String), i(Int)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .i(i) } else { self = .s(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .s(let v): try c.encode(v); case .i(let v): try c.encode(v) }
        }
    }
}
