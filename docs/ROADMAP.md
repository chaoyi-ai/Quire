# Quire 路线图

> 里程碑与任务同步维护在 GitHub：[Milestones](https://github.com/chaoyi-ai/Quire/milestones) · [Issues](https://github.com/chaoyi-ai/Quire/issues)。
> 本文是权威来源；GitHub issue 是执行单元。每个任务标注 `[#issue]`。

原则：**先能读、再能编、始终快。** 每个里程碑结束时 App 都可用、可发布，且性能预算不退化。

## 总览

| 里程碑 | 主题 | 交付物 | 状态 |
|--------|------|--------|------|
| M0 | 基础设施 | 仓库、文档、SwiftPM 骨架、CI、主题文件、基准数据集 | 进行中 |
| M1 | 阅读器 MVP | 打开 .md，原生渲染全部基础块，代码高亮，多主题，目录，自动重载，查找 | |
| M2 | 表格 + Mermaid | 原生表格视图，Mermaid 离屏渲染 + 缓存，更多语言，代码块工具 | |
| M3 | 编辑器 | 源码编辑器 + 高亮，分栏同步预览，增量渲染，保存/撤销/自动保存 | |
| M4 | 性能与打磨 | 基准门禁，内存 / 启动优化，大文件模式，导出 HTML/PDF，偏好设置，发布 0.1 | |
| M5 | 可视化编辑 | 行内实时预览编辑，数学公式，脚注/锚点，本地化，Homebrew 分发，发布 1.0 | |

---

## M0 · 基础设施

**验收**：`swift build && swift test` 通过；`scripts/build_app.sh` 产出可启动的 `dist/Quire.app`（空窗口）；CI 绿；10 套主题 JSON 通过校验测试。

- [ ] 仓库、许可证、README、设计文档、性能预算、主题规范、路线图
- [ ] `Package.swift`：`QuireCore` / `QuireRender` / `Quire` / `quire-bench` + 测试目标；依赖 swift-markdown（pin revision）
- [ ] `assets/Info.plist`（文档类型 `net.daringfireball.markdown`、`public.plain-text` 别名 .md/.markdown/.mdown/.txt 可选）、`scripts/build_app.sh`（组装 + ad-hoc 签名）、`scripts/make_icon.swift`
- [ ] `scripts/fetch_mermaid.sh`：固定版本 + SHA256 校验，写入 `Vendor/mermaid/`
- [ ] 10 套内置主题 JSON + `Theme` 解码/校验/`extends` 单元测试
- [ ] `Tests/Fixtures/` 基准数据集 + 生成脚本 `scripts/gen_fixtures.swift`
- [ ] GitHub Actions：macOS runner `swift build -c release`、`swift test`、`quire-bench` 与预算比对
- [ ] Issue / PR 模板、`CONTRIBUTING.md`

## M1 · 阅读器 MVP

**验收**：打开 `Tests/Fixtures/medium.md`，所有非表格/非 Mermaid 块正确渲染；切换 10 套主题无闪烁；目录可跳转；外部修改文件 1 s 内刷新且保持滚动位置；`quire-bench full` < 200 ms（1 MB）；常驻内存 < 40 MB（small.md）。

### QuireCore
- [ ] `MarkdownParser`：swift-markdown → `Document`/`Block`/`Inline`，携带 `sourceRange` 与 `contentHash`；GFM 扩展开启（表格、删除线、任务列表、自动链接、脚注）
- [ ] 特化：`mermaid` 围栏 → `.mermaid`；独占段落的单图 → `.image` 块；YAML front matter → `.frontMatter`
- [ ] `Outline`：标题树 + GitHub 规则 id 生成（含重名 `-n`）
- [ ] `SyntaxHighlighter` 框架：`Lexer` 协议、`Token`、语言注册表、别名（`js`→`javascript`）
- [ ] 语言（第一批）：swift · javascript/typescript · python · json · bash/shell · c/cpp · go · rust · html/xml · css · yaml · markdown · sql · toml · diff · plain
- [ ] `ThemeStore`：内置 + 用户目录加载、校验、`extends`、目录监听
- [ ] 单元测试：解析结构、outline id、每语言至少 1 个 token 断言、主题校验

### QuireRender
- [ ] `AttributedStringBuilder`：Block/Inline → `NSAttributedString`；段落样式来自主题；自定义属性 key
- [ ] 标题（h1/h2 底线）、段落、强调/删除线、行内代码、链接、图片（本地 + 远程 + 占位 + downsample + `NSCache`）
- [ ] 列表（有序/无序/嵌套/任务复选框，用制表位对齐）、引用（多层）、分割线、HTML 块（原样代码显示）、front matter（折叠灰块）
- [ ] 代码块：等宽字体 + 高亮 token 着色 + `NSTextLayoutFragment` 子类绘制圆角背景 + 语言标签
- [ ] `ReaderTextView`（TextKit 2，只读、可选择、内容宽度居中约束、链接点击）
- [ ] `ThemeApplier.reapply`：不重解析地切换主题
- [ ] 测试：属性断言（字体、颜色、段落样式）

### Quire (App)
- [ ] `NSDocument` 子类（只读打开 .md），窗口 + 工具栏（主题、目录开关、外观）
- [ ] 目录侧栏 `NSOutlineView`，滚动联动高亮，点击跳转
- [ ] 文件监控（DispatchSource）+ 重载保持滚动位置
- [ ] 主题菜单、外观（亮/暗/跟随系统）、缩放（⌘+/⌘-/⌘0）
- [ ] 查找（`NSTextFinder`）、打印（原生）
- [ ] 后台解析/渲染管线（`DocumentSession` actor），主线程只装配
- [ ] `os_signpost` 埋点；`quire-bench parse/render/full/theme/highlight`

## M2 · 表格 + Mermaid

**验收**：`table-heavy.md` 表格对齐/换行/斑马纹正确且滚动 60 fps；`mermaid.md` 20 张图首次渲染 < 3 s、二次打开 < 200 ms（缓存）；无 mermaid 文档不出现 WebKit 进程；代码块可一键复制、可选行号。

- [ ] `TableAttachmentView`：CoreText 单元格排版、列宽算法、对齐、表头、斑马纹、悬停、单元格内行内样式、超宽水平滚动
- [ ] `NSTextAttachmentViewProvider` 集成、高度缓存、窗口宽度变化重排
- [ ] `MermaidRenderer`：惰性单例离屏 `WKWebView`、批量渲染、SVG → `NSImage`、错误块、30 s 空闲销毁
- [ ] Mermaid 磁盘缓存（内容 + 主题哈希，LRU 200 MB）
- [ ] 主题 → `mermaid.theme` 与透明背景
- [ ] 代码块 overlay：复制按钮、行号（偏好开关）、超长行水平滚动
- [ ] 语言（第二批）：java · kotlin · c# · ruby · php · lua · dart · objective-c · dockerfile · makefile · ini · graphql · protobuf · latex · nginx
- [ ] 脚注渲染（定义列表 + 回跳链接）
- [ ] 测试：表格列宽算法、Mermaid 缓存键、第二批语言 token

## M3 · 编辑器

**验收**：在 `large-1mb.md` 中段连续输入，预览更新 < 16 ms/击键（增量路径），无整页闪烁；保存/撤销/自动保存符合 macOS 文档行为；分栏滚动双向同步。

- [ ] `MarkdownLexer`（QuireCore）：行级 Markdown 词法（标题、列表、引用、围栏、行内强调/代码/链接）
- [ ] `EditorTextView`（TextKit 2）：增量高亮（按段落）、行号 gutter、当前行高亮、软换行
- [ ] 输入辅助：列表续行、围栏闭合、Tab/Shift-Tab 缩进、⌘B/⌘I/⌘K、表格 `|` 对齐格式化
- [ ] `NSDocument` 读写：保存、另存、自动保存、版本、撤销
- [ ] 增量渲染：块级 diff（`contentHash`）→ 只替换变更 range；`quire-bench incremental`
- [ ] 分栏布局：源码 / 预览 / 分栏 三态；滚动同步映射表（sourceRange ↔ NSTextRange）
- [ ] 新建文档、拖拽打开、最近文档
- [ ] 测试：diff 正确性（插入/删除/移动块）、lexer token、同步映射

## M4 · 性能与打磨 → 0.1 发布

**验收**：全部 [PERFORMANCE.md](PERFORMANCE.md) 预算达标并进 CI 门禁；导出 HTML/PDF 可用；GitHub Release 附 `Quire.app.zip`。

- [ ] `scripts/bench.sh` 与 CI 门禁（退化 > 10% 失败）
- [ ] 启动优化：延迟加载主题目录监听 / Mermaid / 偏好；测量 `os_signpost`
- [ ] 内存优化：渲染块缓存策略、图片缓存上限、Instruments 复核
- [ ] 大文件模式（> 8 MB）：关闭高亮/Mermaid，提示条
- [ ] 表格文本可查找（镜像隐藏文本或自定义 finder client）
- [ ] 导出 HTML（内联主题 CSS）、PDF（原生打印管线）
- [ ] 偏好设置窗口（SwiftUI 可）：主题对、字体覆盖、行号、链接下划线、自动重载
- [ ] 应用图标、About、崩溃不丢数据复核
- [ ] 发布流程：`scripts/release.sh`、GitHub Release、CHANGELOG

## M5 · 可视化编辑 → 1.0

- [ ] 行内实时预览模式（光标块显源码，其余渲染）
- [ ] 数学公式（评估 SwiftMath 或自绘 KaTeX 子集，不引入 WebView）
- [ ] 内部锚点跳转 / 相对链接打开 / 图片查看器
- [ ] 本地化：zh-Hans / en
- [ ] Homebrew cask、Sparkle 或手动更新检查（可关闭）
- [ ] Quick Look 预览扩展（复用 QuireRender）

## 长期想法（未排期）

- tree-sitter 作为可选高亮后端
- 可选沙盒 / 公证发行
- 快捷键自定义、Vim 键位（社区贡献）
