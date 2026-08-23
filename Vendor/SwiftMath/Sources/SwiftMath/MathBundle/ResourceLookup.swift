import Foundation

/// Quire 本地补丁：SwiftPM 生成的 `Bundle.module` 只会在 `Bundle.main.bundleURL/SwiftMath_SwiftMath.bundle`
/// 与编译机的绝对构建路径里找资源 bundle，装进 Quire.app/Contents/Resources 的那份永远找不到——
/// 在别的机器上第一次渲染公式就 fatalError。这里先看 Contents/Resources，再退回 `Bundle.module`（开发 / 测试时有效）。
enum MathResources {
    static let mathFontsBundleURL: URL? = {
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
            .map { $0.appendingPathComponent("SwiftMath_SwiftMath.bundle") }
        for url in candidates {
            if let b = Bundle(url: url), let fonts = b.url(forResource: "mathFonts", withExtension: "bundle") { return fonts }
        }
        return Bundle.module.url(forResource: "mathFonts", withExtension: "bundle")
    }()
}
