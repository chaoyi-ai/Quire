import Foundation

/// 扩展行内语法（默认全关，偏好里逐项开）：`==高亮==`、`~下标~`、`^上标^`、`<u>下划线</u>`、`:emoji:`。
/// 在 cmark 解析之后对 `.text` / `.html` 节点做后处理；关着时 CommonMark 行为完全不变。
public struct ExtendedInlineOptions: Equatable, Sendable {
    public var highlight = false
    public var subscriptText = false
    public var superscriptText = false
    public var underline = false
    public var emoji = false
    public init() {}
    public var any: Bool { highlight || subscriptText || superscriptText || underline || emoji }
}

enum ExtendedInline {
    static func apply(_ inlines: [Inline], options: ExtendedInlineOptions) -> [Inline] {
        guard options.any else { return inlines }
        var out: [Inline] = []
        // 1) <u>…</u>：把 .html("<u>") 与 .html("</u>") 之间的节点包起来
        var i = 0
        while i < inlines.count {
            if options.underline, case .html(let open) = inlines[i], open.lowercased().replacingOccurrences(of: " ", with: "") == "<u>" {
                if let close = inlines[(i + 1)...].firstIndex(where: { if case .html(let c) = $0 { return c.lowercased().replacingOccurrences(of: " ", with: "") == "</u>" }; return false }) {
                    out.append(.underline(apply(Array(inlines[(i + 1)..<close]), options: options)))
                    i = close + 1; continue
                }
            }
            out.append(recurse(inlines[i], options: options))
            i += 1
        }
        // 2) 文本节点里的 ==x== / ~x~ / ^x^ / :emoji:
        var result: [Inline] = []
        for node in out {
            if case .text(let t) = node { result.append(contentsOf: splitText(t, options: options)) } else { result.append(node) }
        }
        return result
    }

    private static func recurse(_ inline: Inline, options: ExtendedInlineOptions) -> Inline {
        switch inline {
        case .emphasis(let c): return .emphasis(apply(c, options: options))
        case .strong(let c): return .strong(apply(c, options: options))
        case .strikethrough(let c): return .strikethrough(apply(c, options: options))
        case .link(let d, let t, let c): return .link(destination: d, title: t, children: apply(c, options: options))
        default: return inline
        }
    }

    /// 成对定界符：`==x==`、`~x~`、`^x^`——内容非空、不跨空白开头结尾；`:name:` 查表
    static func splitText(_ s: String, options: ExtendedInlineOptions) -> [Inline] {
        let u = Array(s.utf16)
        guard u.contains(where: { $0 == 0x3D || $0 == 0x7E || $0 == 0x5E || $0 == 0x3A }) else { return [.text(s)] }
        var out: [Inline] = []
        var textStart = 0
        var i = 0
        func str(_ r: Range<Int>) -> String { String(utf16CodeUnits: Array(u[r]), count: r.count) }
        func flush(_ upTo: Int) { if textStart < upTo { out.append(.text(str(textStart..<upTo))) } }
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 }
        while i < u.count {
            let c = u[i]
            // ==高亮==
            if options.highlight, c == 0x3D, i + 1 < u.count, u[i + 1] == 0x3D, i + 2 < u.count, !isSpace(u[i + 2]) {
                var j = i + 3
                while j + 1 < u.count, !(u[j] == 0x3D && u[j + 1] == 0x3D && !isSpace(u[j - 1])) { j += 1 }
                if j + 1 < u.count, j > i + 2 {
                    flush(i); out.append(.highlight([.text(str((i + 2)..<j))])); i = j + 2; textStart = i; continue
                }
            }
            // ~下标~ / ^上标^（单字符定界，内容里不能有空格）
            if (options.subscriptText && c == 0x7E) || (options.superscriptText && c == 0x5E), i + 1 < u.count, !isSpace(u[i + 1]), u[i + 1] != c {
                var j = i + 1
                while j < u.count, u[j] != c, !isSpace(u[j]) { j += 1 }
                if j < u.count, u[j] == c, j > i + 1 {
                    flush(i)
                    let inner: [Inline] = [.text(str((i + 1)..<j))]
                    out.append(c == 0x7E ? .subscript(inner) : .superscript(inner))
                    i = j + 1; textStart = i; continue
                }
            }
            // :emoji:
            if options.emoji, c == 0x3A, i + 1 < u.count {
                var j = i + 1
                while j < u.count, (u[j] >= 0x61 && u[j] <= 0x7A) || (u[j] >= 0x30 && u[j] <= 0x39) || u[j] == 0x5F || u[j] == 0x2B || u[j] == 0x2D { j += 1 }
                if j < u.count, u[j] == 0x3A, j > i + 1, let e = Emoji.table[str((i + 1)..<j)] {
                    flush(i); out.append(.text(e)); i = j + 1; textStart = i; continue
                }
            }
            i += 1
        }
        flush(u.count)
        return out.isEmpty ? [.text(s)] : out
    }
}

/// 常用 GitHub 短码（子集）
enum Emoji {
    static let table: [String: String] = [
        "smile": "😄", "smiley": "😃", "grinning": "😀", "laughing": "😆", "joy": "😂", "rofl": "🤣", "wink": "😉", "blush": "😊", "heart_eyes": "😍",
        "thinking": "🤔", "neutral_face": "😐", "sweat_smile": "😅", "sob": "😭", "cry": "😢", "angry": "😠", "rage": "😡", "scream": "😱", "sunglasses": "😎",
        "thumbsup": "👍", "+1": "👍", "thumbsdown": "👎", "-1": "👎", "clap": "👏", "pray": "🙏", "wave": "👋", "ok_hand": "👌", "point_right": "👉", "point_left": "👈",
        "muscle": "💪", "eyes": "👀", "heart": "❤️", "broken_heart": "💔", "star": "⭐", "sparkles": "✨", "fire": "🔥", "zap": "⚡", "boom": "💥", "100": "💯",
        "tada": "🎉", "confetti_ball": "🎊", "gift": "🎁", "trophy": "🏆", "rocket": "🚀", "bulb": "💡", "warning": "⚠️", "x": "❌", "white_check_mark": "✅", "heavy_check_mark": "✔️",
        "question": "❓", "exclamation": "❗", "bangbang": "‼️", "information_source": "ℹ️", "no_entry": "⛔", "construction": "🚧", "bug": "🐛", "wrench": "🔧", "hammer": "🔨", "gear": "⚙️",
        "memo": "📝", "pencil": "📝", "pencil2": "✏️", "book": "📖", "books": "📚", "bookmark": "🔖", "link": "🔗", "paperclip": "📎", "pushpin": "📌", "calendar": "📅",
        "clock": "🕐", "hourglass": "⏳", "bell": "🔔", "mag": "🔍", "lock": "🔒", "unlock": "🔓", "key": "🔑", "package": "📦", "file_folder": "📁", "open_file_folder": "📂",
        "computer": "💻", "iphone": "📱", "email": "📧", "speech_balloon": "💬", "thought_balloon": "💭", "chart_with_upwards_trend": "📈", "chart_with_downwards_trend": "📉", "bar_chart": "📊",
        "sunny": "☀️", "cloud": "☁️", "umbrella": "☔", "snowflake": "❄️", "rainbow": "🌈", "earth_asia": "🌏", "moon": "🌙", "coffee": "☕", "tea": "🍵", "beer": "🍺",
        "pizza": "🍕", "apple": "🍎", "cake": "🍰", "dog": "🐶", "cat": "🐱", "panda_face": "🐼", "penguin": "🐧", "octocat": "🐙", "see_no_evil": "🙈", "monkey": "🐒",
        "arrow_right": "➡️", "arrow_left": "⬅️", "arrow_up": "⬆️", "arrow_down": "⬇️", "recycle": "♻️", "copyright": "©️", "tm": "™️", "red_circle": "🔴", "green_circle": "🟢", "yellow_circle": "🟡",
        "china": "🇨🇳", "us": "🇺🇸", "jp": "🇯🇵", "uk": "🇬🇧", "de": "🇩🇪", "fr": "🇫🇷",
    ]
}
