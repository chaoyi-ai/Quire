import Foundation

/// 资源 bundle 查找。
///
/// SwiftPM 生成的 `Bundle.module` 只会在 `Bundle.main.bundleURL/<包名>_<目标>.bundle` 与**编译机的绝对 .build 路径**里找，
/// `scripts/build_app.sh` 装进 `Quire.app/Contents/Resources/` 的那份它永远找不到——在别的机器上第一个 `L("…")` 就 fatalError
/// （0.3.0–0.5.8 的发布包全都这样，本机因为 .build 还在所以从没发现）。所以所有模块都经这里取资源：
/// 先 `Contents/Resources`，再 `Bundle.main.bundleURL`（`swift run` 时不存在），最后才回退 `Bundle.module`（开发 / 测试）。
public enum ResourceBundle {
    public static func locate(_ name: String, fallback: () -> Bundle) -> Bundle {
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let b = Bundle(url: base.appendingPathComponent(name + ".bundle")) { return b }
        }
        return fallback()
    }
}
