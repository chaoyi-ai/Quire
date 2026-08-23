import Foundation

/// 版本号比较（更新检查用）。放在 QuireCore 里是为了能被测试直接覆盖——以前 App 目标里一份、测试里镜像一份，测的不是真货
public enum VersionCompare {
    /// `a` 比 `b` 新（按点分数字段逐段比；非数字后缀忽略；段数不等时缺的当 0）
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
