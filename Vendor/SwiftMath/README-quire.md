# SwiftMath（vendored）

来源：https://github.com/mgriebling/SwiftMath 1.7.3（MIT，见 LICENSE）。为什么不直接用远程包：

1. SwiftPM 给依赖生成的 `Bundle.module` 只会在 `Bundle.main.bundleURL/SwiftMath_SwiftMath.bundle` 和**编译机的绝对 .build 路径**里找资源，
   装进 `Quire.app/Contents/Resources` 的那份永远找不到——在别的机器上第一次渲染公式就 `fatalError`。
   补丁：`Sources/SwiftMath/MathBundle/ResourceLookup.swift`，`MathFont.swift` / `MTFont.swift` 的三处改用 `MathResources.mathFontsBundleURL`。
2. 原包带 11 套数学字体（7 MB）；Quire 只用默认的 Latin Modern，`mathFonts.bundle` 只保留 `latinmodern-math.*`（0.7 MB）。

升级时：拷新版本的 `Sources/`，重新做上面两步。
