import Foundation

/// 文风检查（iA Writer Style Check 式）：划掉填充词 / 冗余 / 陈词滥调，只在编辑器显示，不改文本。
/// 规则：内置英文 + 中文词表；用户规则文件（每行一条）：`短语` 加规则，`-短语` 加例外，`/正则/` 正则（只用 NSRegularExpression 的常规子集），`#` 注释。
public struct StyleChecker: Sendable {
    public enum Category: String, Sendable { case filler, redundancy, cliche, custom }
    public struct Match: Equatable, Sendable {
        public var range: NSRange
        public var category: Category
        public var phrase: String
    }
    public struct Rule: Sendable, Equatable {
        public var pattern: String
        public var isRegex: Bool
        public var category: Category
    }

    public var rules: [Rule]
    public var exceptions: [String]
    public var enabled: Set<Category> = [.filler, .redundancy, .cliche, .custom]

    public init(rules: [Rule] = StyleChecker.builtInRules, exceptions: [String] = []) {
        self.rules = rules; self.exceptions = exceptions
    }

    /// 解析用户规则文件内容并合并到内置规则
    public static func load(userRules text: String) -> StyleChecker {
        var rules = builtInRules
        var exceptions: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("-") { exceptions.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()); continue }
            if line.hasPrefix("/"), line.hasSuffix("/"), line.count > 2 {
                rules.append(Rule(pattern: String(line.dropFirst().dropLast()), isRegex: true, category: .custom))
            } else {
                rules.append(Rule(pattern: line, isRegex: false, category: .custom))
            }
        }
        return StyleChecker(rules: rules, exceptions: exceptions)
    }

    public func matches(in text: String) -> [Match] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let lower = text.lowercased() as NSString
        let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        var out: [Match] = []
        for rule in rules where enabled.contains(rule.category) {
            let ruleIsCJK = rule.pattern.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            // 内置中文词表只查含中文的段落，内置英文词表只查不含中文的段落（避免中文里误伤英文单词边界）；用户规则不分语言
            if rule.category != .custom, ruleIsCJK != hasCJK { continue }
            if rule.isRegex {
                guard let re = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                    out.append(Match(range: m.range, category: rule.category, phrase: ns.substring(with: m.range)))
                }
                continue
            }
            let needle = rule.pattern.lowercased()
            var start = 0
            while start < lower.length {
                let r = lower.range(of: needle, options: [], range: NSRange(location: start, length: lower.length - start))
                guard r.location != NSNotFound else { break }
                start = r.location + max(1, r.length)
                // 拉丁文要整词：两侧不能是字母
                if !ruleIsCJK {
                    let before = r.location > 0 ? lower.character(at: r.location - 1) : 0x20
                    let after = r.location + r.length < lower.length ? lower.character(at: r.location + r.length) : 0x20
                    if Self.isLetter(before) || Self.isLetter(after) { continue }
                }
                out.append(Match(range: r, category: rule.category, phrase: ns.substring(with: r)))
            }
        }
        // 例外：命中短语本身或其所在的更长例外短语
        if !exceptions.isEmpty {
            out.removeAll { m in
                let p = m.phrase.lowercased()
                return exceptions.contains { ex in ex == p || (lower.range(of: ex).location != NSNotFound && ex.contains(p)) }
            }
        }
        // 去重叠：按位置排序，长的优先
        out.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var result: [Match] = []
        var lastEnd = -1
        for m in out where m.range.location >= lastEnd { result.append(m); lastEnd = m.range.location + m.range.length }
        return result
    }

    private static func isLetter(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x27 || (c >= 0xC0 && c <= 0x24F)
    }

    // MARK: - 内置词表

    public static let builtInRules: [Rule] = {
        var r: [Rule] = []
        func add(_ list: [String], _ c: Category) { for p in list { r.append(Rule(pattern: p, isRegex: false, category: c)) } }
        add(["basically", "actually", "literally", "really", "very", "quite", "just", "rather", "pretty much", "sort of", "kind of", "in order to", "at this point in time", "needless to say", "it goes without saying", "for all intents and purposes", "in my opinion", "the fact that", "as a matter of fact", "in terms of", "on a daily basis", "due to the fact that", "in the event that", "a lot", "totally", "absolutely", "definitely", "obviously", "honestly", "simply", "somewhat", "virtually", "extremely", "truly"], .filler)
        add(["basic fundamentals", "combine together", "fall down", "end result", "final outcome", "past history", "free gift", "advance planning", "each and every", "first and foremost", "close proximity", "completely finished", "exact same", "future plans", "new innovation", "plan ahead", "repeat again", "return back", "revert back", "unexpected surprise", "true facts", "added bonus", "join together", "merge together", "mutual cooperation", "personal opinion", "postpone until later", "sum total", "12 noon", "12 midnight", "armed gunman", "PIN number", "ATM machine"], .redundancy)
        add(["at the end of the day", "think outside the box", "low-hanging fruit", "against all odds", "brass tacks", "the long and short of it", "in this day and age", "last but not least", "only time will tell", "a level playing field", "move the needle", "paradigm shift", "push the envelope", "circle back", "touch base", "going forward", "game changer", "it is what it is", "at the end of the day", "hit the ground running", "best of both worlds", "the bottom line", "tip of the iceberg", "win-win", "synergy", "leverage", "bandwidth", "deep dive", "take it to the next level", "all things considered"], .cliche)
        // 中文：填充 / 冗余 / 套话（自建词表）
        add(["基本上", "其实", "的话", "然后", "可以说", "在一定程度上", "某种程度上", "不得不说", "说实话", "老实说", "事实上", "总的来说", "一般来说", "所谓的", "相关的", "进行了", "进行", "作出", "给予", "具有", "非常非常", "比较", "相对来说", "方面", "情况", "问题", "工作", "一下"], .filler)
        add(["免费赠送", "亲眼目睹", "凯旋归来", "再次重申", "最后的结局", "非常十分", "十分非常", "进行研究", "进行讨论", "进行分析", "进行处理", "进行学习", "作出决定", "作出贡献", "给予支持", "给予帮助", "具有重要意义", "涉及到", "截止到", "大约左右", "大概左右", "约左右", "最终结果", "过去的历史", "共同合作", "提前预告", "首先第一", "全部都", "彼此互相", "突然猝死", "悬殊很大", "可以堪称", "许多的", "大多数的"], .redundancy)
        add(["众所周知", "综上所述", "不言而喻", "毋庸置疑", "与时俱进", "高屋建瓴", "深入浅出", "举足轻重", "可圈可点", "赋能", "抓手", "闭环", "颗粒度", "底层逻辑", "降维打击", "顶层设计", "打通", "沉淀", "赛道", "对齐", "拉齐", "落地", "复盘", "从某种意义上说", "一定意义上", "不可否认", "值得注意的是", "随着社会的发展", "随着科技的进步", "在这个日新月异的时代", "时代的浪潮", "有目共睹", "日新月异"], .cliche)
        return r
    }()
}
