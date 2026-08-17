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
        // Apple 维护的 cmark-gfm Swift 封装；非 semver tag，按 swift-6.3.3-RELEASE 的 revision 锁定
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            revision: "de3e245b6044386b623ecce11d1ccb5fe766e3db"
        ),
    ],
    targets: [
        // 纯 Foundation：解析 · 块模型 · 增量 diff · 主题 · 高亮 · 大纲
        .target(
            name: "QuireCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            resources: [.copy("Themes")]
        ),
        // AppKit 渲染层：Block → NSAttributedString · TextKit 2 视图 · 附件 · Mermaid · 图片
        .target(
            name: "QuireRender",
            dependencies: ["QuireCore"],
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
