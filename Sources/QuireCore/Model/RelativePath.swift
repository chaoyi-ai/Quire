import Foundation

/// 计算文件相对目录的路径。`/tmp` → `/private/tmp` 这类符号链接会让枚举出的路径与根目录前缀对不上，
/// 两边各取「原样」与「解析符号链接后」两种形式交叉匹配；都不匹配时回退到文件名。
public enum RelativePath {
    public static func relative(_ file: URL, to root: URL) -> String {
        let roots = Set([root.path, root.resolvingSymlinksInPath().path].map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        for p in [file.path, file.resolvingSymlinksInPath().path] {
            for r in roots where p.hasPrefix(r) { return String(p.dropFirst(r.count)) }
        }
        return file.lastPathComponent
    }
}
