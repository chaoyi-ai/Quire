import Foundation
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
    static func checker() -> StyleChecker {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return StyleChecker.load(userRules: text)
    }
}
