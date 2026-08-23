import AppKit
import QuireCore

/// 用户文风规则文件：~/Library/Application Support/Quire/style-rules.txt（每行一条：短语 / -例外 / /正则/ / # 注释）
enum StyleRulesStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Quire/style-rules.txt")
    }
    static let template = """
    # Quire 文风检查：自定义规则（每行一条，改完保存即生效——下次开启文风检查时重新读取）
    # 短语          → 加一条规则（不分大小写；拉丁文整词匹配）
    # -短语         → 例外：内置或自定义规则里不再划掉它
    # /正则/        → 正则规则（NSRegularExpression 语法）
    #
    # 例：
    # 老铁
    # -as a matter of fact
    # /reg(exp?|ular expression)/
    """
    /// 读用户规则；文件读不了或有坏正则时弹一次提示（不吞：否则用户以为规则生效了）
    @MainActor static func checker() -> StyleChecker {
        var text = ""
        if FileManager.default.fileExists(atPath: url.path) {
            do { text = try String(contentsOf: url, encoding: .utf8) }
            catch { warn(String(format: L("读不了文风规则文件 %@：%@"), url.path, error.localizedDescription)) }
        }
        let c = StyleChecker.load(userRules: text)
        if !c.problems.isEmpty {
            warn(String(format: L("文风规则里有 %d 条正则无效（已跳过）：%@"), c.problems.count, c.problems.map { "第 \($0.line) 行 \($0.message)" }.joined(separator: "；")))
        }
        return c
    }
    @MainActor private static var warned: Set<String> = []
    @MainActor private static func warn(_ message: String) {
        guard !warned.contains(message) else { return }   // 同一个问题只提醒一次
        warned.insert(message)
        let a = NSAlert(); a.messageText = L("文风规则"); a.informativeText = message; a.runModal()
    }
}
