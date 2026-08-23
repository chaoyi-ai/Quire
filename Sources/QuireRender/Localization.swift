import Foundation

/// QuireRender 模块内的字符串本地化。
/// 键 = 中文原文（`zh-Hans.lproj` 为恒等映射，`en.lproj` 为译文）；找不到时返回键本身，代码里永远可读。
/// 测试 `LocalizationTests` 保证代码里出现的每个键在两套 .strings 里都存在。
@inline(__always)
public func RL(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
