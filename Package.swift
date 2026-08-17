// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Quire",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuireCore", targets: ["QuireCore"]),
        .library(name: "QuireRender", targets: ["QuireRender"]),
        .executable(name: "Quire", targets: ["Quire"]),
        .executable(name: "quire-bench", targets: ["quire-bench"]),
    ],
    dependencies: [
        // cmark-gfm（GitHub 生产级 C 实现，Apple 维护的 fork）。直接走 C API，见 ADR-2 / ADR-12。
        // gfm 分支无 semver tag，按 revision 锁定（与 swift-markdown swift-6.3.3-RELEASE 所用一致）
        .package(
            url: "https://github.com/swiftlang/swift-cmark.git",
            revision: "7898f1b3e4befeecee56cb4a3bc8eebd2cb63219"
        ),
    ],
    targets: [
        // 纯 Foundation：解析 · 块模型 · 增量 diff · 主题 · 高亮 · 大纲
        .target(
            name: "QuireCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            resources: [.copy("Themes")]
        ),
        // ObjC 直通：属性字符串 run 追加（避免 Swift 字典桥接，6× 提速；见 ADR-11）
        .target(
            name: "CQuireAttr",
            path: "Sources/CQuireAttr"
        ),
        // AppKit 渲染层：Block → NSAttributedString · TextKit 2 视图 · 附件 · Mermaid · 图片
        .target(
            name: "QuireRender",
            dependencies: ["QuireCore", "CQuireAttr"],
            resources: [.copy("Resources/Mermaid")]
        ),
        // App 壳
        .executableTarget(
            name: "Quire",
            dependencies: ["QuireCore", "QuireRender"]
        ),
        // 性能基准 CLI
        .executableTarget(
            name: "quire-bench",
            dependencies: ["QuireCore", "QuireRender"]
        ),
        .testTarget(
            name: "QuireCoreTests",
            dependencies: ["QuireCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "QuireRenderTests",
            dependencies: ["QuireRender"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
