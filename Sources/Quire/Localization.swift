import Foundation

/// App 层字符串本地化（见 QuireRender 的 `RL`）。键 = 中文原文。
@inline(__always)
func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
