# Quire 路线图

> 里程碑与任务同步维护在 GitHub：[Milestones](https://github.com/chaoyi-ai/Quire/milestones) · [Issues](https://github.com/chaoyi-ai/Quire/issues)。
> 本文是权威来源；GitHub issue 是执行单元。每个任务标注 `[#issue]`。

原则：**先能读、再能编、始终快。** 每个里程碑结束时 App 都可用、可发布，且性能预算不退化。

## 总览

| 里程碑 | 主题 | 交付物 | 状态 |
|--------|------|--------|------|
| M0 | 基础设施 | 仓库、文档、SwiftPM 骨架、CI、主题文件、基准数据集 | ✅ 完成 |
| M1 | 阅读器 MVP | 打开 .md，原生渲染全部基础块，代码高亮，多主题，目录，自动重载，查找 | ✅ 完成 |
| M2 | 表格 + Mermaid | 原生表格视图，Mermaid 离屏渲染 + 缓存，更多语言，代码块工具 | ✅ 完成（行号/超长行滚动移入 M4） |
| M3 | 编辑器 | 源码编辑器 + 高亮，分栏同步预览，增量渲染，保存/撤销/自动保存 | ✅ 完成 |
| M4 | 性能与打磨 | 基准门禁，内存 / 启动优化，大文件模式，导出 HTML/PDF，偏好设置，发布 0.1 | ✅ 完成（表格可查找 → M5） |
| M5 | 1.0 发布（基础补全 + 速赢） | 本地化、数学（先 spike）、字体覆盖、可访问性、快速打开、全局搜索、字数、剪贴板互通、沉浸 / Focus / 标记出挑、公证 + Homebrew、Quick Look | 2026-08 复审重排 |
| M6 | 混合实时预览与就地编辑（对标 Typora） | Spike go/no-go → 行内实时预览、表格架构决策与就地编辑、图片粘贴、数学块、悬浮工具栏、扩展语法、导出补全、CLI | 调研见 [research/typora.md](research/typora.md) |
| M7 | 文本智能与组织（对标 iA Writer） | 词性高亮、文风检查、著作归属、Wikilinks / 标签 / 收藏、内容块 `![[file]]`、PDF 排版参数、URL scheme | 调研见 [research/ia-writer.md](research/ia-writer.md) |

---

## M0 · 基础设施

**验收**：`swift build && swift test` 通过；`scripts/build_app.sh` 产出可启动的 `dist/Quire.app`（空窗口）；CI 绿；10 套主题 JSON 通过校验测试。

- [x] 仓库、许可证、README、设计文档、性能预算、主题规范、路线图
- [x] `Package.swift`：`QuireCore` / `QuireRender` / `Quire` / `quire-bench` + 测试目标；依赖 swift-markdown（pin revision）
- [x] `assets/Info.plist`（文档类型 `net.daringfireball.markdown`、`public.plain-text` 别名 .md/.markdown/.mdown/.txt 可选）、`scripts/build_app.sh`（组装 + ad-hoc 签名）、`scripts/make_icon.swift`
- [x] `scripts/fetch_mermaid.sh`：固定版本 + SHA256 校验，写入 `Vendor/mermaid/`
- [x] 10 套内置主题 JSON + `Theme` 解码/校验/`extends` 单元测试
- [x] `Tests/Fixtures/` 基准数据集 + 生成脚本 `scripts/gen_fixtures.swift`
- [x] GitHub Actions：macOS runner `swift build -c release`、`swift test`、`quire-bench` 与预算比对
- [x] Issue / PR 模板、`CONTRIBUTING.md`

## M1 · 阅读器 MVP

**验收**：打开 `Tests/Fixtures/medium.md`，所有非表格/非 Mermaid 块正确渲染；切换 10 套主题无闪烁；目录可跳转；外部修改文件 1 s 内刷新且保持滚动位置；`quire-bench full` < 200 ms（1 MB）；常驻内存 < 40 MB（small.md）。

### QuireCore
- [x] `MarkdownParser`：swift-markdown → `Document`/`Block`/`Inline`，携带 `sourceRange` 与 `contentHash`；GFM 扩展开启（表格、删除线、任务列表、自动链接、脚注）
- [x] 特化：`mermaid` 围栏 → `.mermaid`；独占段落的单图 → `.image` 块；YAML front matter → `.frontMatter`
- [x] `Outline`：标题树 + GitHub 规则 id 生成（含重名 `-n`）
- [x] `SyntaxHighlighter` 框架：`Lexer` 协议、`Token`、语言注册表、别名（`js`→`javascript`）
- [x] 语言（第一批）：swift · javascript/typescript · python · json · bash/shell · c/cpp · go · rust · html/xml · css · yaml · markdown · sql · toml · diff · plain
- [x] `ThemeStore`：内置 + 用户目录加载、校验、`extends`、目录监听
- [x] 单元测试：解析结构、outline id、每语言至少 1 个 token 断言、主题校验

### QuireRender
- [x] `AttributedStringBuilder`：Block/Inline → `NSAttributedString`；段落样式来自主题；自定义属性 key
- [x] 标题（h1/h2 底线）、段落、强调/删除线、行内代码、链接、图片（本地 + 远程 + 占位 + downsample + `NSCache`）
- [x] 列表（有序/无序/嵌套/任务复选框，用制表位对齐）、引用（多层）、分割线、HTML 块（原样代码显示）、front matter（折叠灰块）
- [x] 代码块：等宽字体 + 高亮 token 着色 + `NSTextLayoutFragment` 子类绘制圆角背景 + 语言标签
- [x] `ReaderTextView`（TextKit 2，只读、可选择、内容宽度居中约束、链接点击）
- [x] `ThemeApplier.reapply`：不重解析地切换主题
- [x] 测试：属性断言（字体、颜色、段落样式）

### Quire (App)
- [x] `NSDocument` 子类（只读打开 .md），窗口 + 工具栏（主题、目录开关、外观）
- [x] 目录侧栏 `NSOutlineView`，滚动联动高亮，点击跳转
- [x] 文件监控（DispatchSource）+ 重载保持滚动位置
- [x] 主题菜单、外观（亮/暗/跟随系统）、缩放（⌘+/⌘-/⌘0）
- [x] 查找（`NSTextFinder`）、打印（原生）
- [x] 后台解析/渲染管线（`DocumentSession` actor），主线程只装配
- [x] `os_signpost` 埋点；`quire-bench parse/render/full/theme/highlight`

## M2 · 表格 + Mermaid

**验收**：`table-heavy.md` 表格对齐/换行/斑马纹正确且滚动 60 fps；`mermaid.md` 20 张图首次渲染 < 3 s、二次打开 < 200 ms（缓存）；无 mermaid 文档不出现 WebKit 进程；代码块可一键复制、可选行号。

- [x] `TableAttachmentView`：CoreText 单元格排版、列宽算法、对齐、表头、斑马纹、悬停、单元格内行内样式、超宽水平滚动
- [x] 尺寸由 `NSTextAttachment.attachmentBounds` 按片段宽度计算，窗口变宽自动重排（NSTextView 不驱动 ViewProvider，见 issue #56）
- [x] `MermaidRenderer`：惰性单例离屏 `WKWebView`、批量渲染、SVG → `NSImage`、错误块、30 s 空闲销毁
- [x] Mermaid 磁盘缓存（内容 + 主题哈希，LRU 200 MB）
- [x] 主题 → `mermaid.theme` 与透明背景
- [x] 代码块复制按钮（行号 / 超长行水平滚动 → M4，issue #31）
- [x] 语言（第二批）：java · kotlin · c# · ruby · php · lua · dart · objective-c · dockerfile · makefile · ini · graphql · protobuf · latex · nginx
- [x] 脚注渲染（定义列表 + 回跳链接）
- [x] 测试：表格列宽算法、Mermaid 缓存键、第二批语言 token

## M3 · 编辑器

**验收**：在 `large-1mb.md` 中段连续输入，预览更新 < 16 ms/击键（增量路径），无整页闪烁；保存/撤销/自动保存符合 macOS 文档行为；分栏滚动双向同步。

- [x] `MarkdownLexer`（QuireCore）：行级 Markdown 词法（标题、列表、引用、围栏、行内强调/代码/链接）
- [x] `EditorTextView`（TextKit 2）：增量高亮（按段落）、行号 gutter、当前行高亮、软换行
- [x] 输入辅助：列表续行、围栏闭合、Tab/Shift-Tab 缩进、⌘B/⌘I/⌘K/⌘E（表格 `|` 对齐格式化 → M4 备选）
- [x] `NSDocument` 读写：保存、另存、自动保存、版本、撤销
- [x] 增量渲染：块级 diff（`contentHash`）→ 只替换变更 range；`quire-bench incremental`
- [x] 分栏布局：源码 / 预览 / 分栏 三态；滚动同步映射表（sourceRange ↔ NSTextRange）
- [x] 新建文档、拖拽打开、最近文档
- [x] 测试：diff 正确性（插入/删除/移动块）、lexer token、同步映射

## M4 · 性能与打磨 → 0.1 发布

**验收**：全部 [PERFORMANCE.md](PERFORMANCE.md) 预算达标并进 CI 门禁；导出 HTML/PDF 可用；GitHub Release 附 `Quire.app.zip`。

- [x] `scripts/bench.sh` 与 CI 门禁（预算表；基线回归比对待稳定 runner）
- [x] 启动优化：540 → 350–400 ms（懒建编辑器、同步首帧渲染、无启动动画）；`scripts/bench_launch.sh`
- [x] 内存复核：40 MB / 90 MB（small / 1 MB）
- [x] 大文件模式（> 8 MB，可调）：关闭高亮/Mermaid，提示条
- [ ] 表格文本可查找 → M5
- [x] 导出 HTML（内联主题 CSS）、PDF（原生打印管线，按块分页）
- [x] 偏好设置窗口（SwiftUI）：主题对、外观、代码行号、复制按钮、链接下划线、自动重载、大文件阈值、编辑器行号（字体覆盖 → M5）
- [x] 应用图标、About、autosavesInPlace
- [x] 发布流程：`scripts/release.sh`、GitHub Release、CHANGELOG

## M4.5 · 侧栏文件树（0.2.0）✅

- [x] 目录树 → 文件 → 大纲混合导航（懒加载、FSEvents、快速标题扫描 `HeadingScanner`）
- [x] 路径栏切根目录、⌘⇧O 打开文件夹、⌘⇧J 定位当前文件

## M5 · 1.0 发布（基础补全 + 速赢）

> 2026-08 路线图复审后重排：1.0 的承诺是"读得最好 + 能写 + 有工作台"，不押在最难的混合实时预览上（移到 M6）。把只依赖现有源码编辑器、1–3 天一项的速赢从 M6 / M7 拉进来。

**验收**：zh-Hans / en 两套 UI 完整；数学块 / 行内数学原生渲染（无 WebView）；⌘P 三次击键内打开根目录任意文件；⌘⇧F 在 1000 个文件 / 50 MB 的目录里 300 ms 内出首批结果；⌘⇧D 一键进入无 chrome 写作，Focus 切换句子时视口位移 0 px、帧时间 < 8 ms；公证后的 DMG 可经 Homebrew 安装且 Gatekeeper 不拦；1 MB 文档的启动 / 内存 / 滚动指标与 M4 基线持平；VoiceOver 能读出表格内容与 Mermaid 的源码摘要。

### 5.1 基础补全（按此顺序）
- [x] **本地化 zh-Hans / en（最先做）**：后续里程碑会新增大量 UI 字符串，晚做回填成本翻倍（#53）→ 0.3.0：`L()` / `RL()`，键 = 中文原文，测试保证两套 .strings 与代码一致；设置里可覆盖界面语言
- [x] Spike：数学渲染方案验证（#83）→ **go：SwiftMath 1.7.3**（iosMath 的 Swift 移植，MIT，CoreText + Latin Modern Math）。实测：首次渲染（字体加载）11 ms，200 个公式 58 ms（0.29 ms / 式），内存 +9 MB，错误有可读信息；自带 11 套字体 7 MB，打包时只留 Latin Modern（0.7 MB），App 体积 7.0 → 8.9 MB，仍在 10 MB 预算内。自绘 KaTeX 子集不值得：SwiftMath 已覆盖 TeX 常用宏与矩阵 / 分式 / 积分 / 上下标。见 ADR-15
- [x] 数学公式（#51，0.4.0）：`$$…$$` 块（独占行的 `$$` 先改写成 ```math 围栏再喂 cmark，块内 `=` / `\\` 不被动；也认 GitLab 风格 ```math）与 `$…$` 行内（Pandoc 规则，`$2 和 $3` 不算）；块级居中成图，行内按 descent 对齐基线；渲染失败显示源码 + 错误；大文件模式不渲染；HTML 导出写成 `\[…\]` / `\(…\)` 并引 MathJax CDN（与 Mermaid 同一开关）；设置里可整体关闭。无 `$$` 的文档零额外开销（parse 仍 42 ms）
- [x] 主题级字体覆盖：设置 → 阅读：正文字体 / 代码字体 / 基础字号，通过 `RenderOptions` 排在主题字体列表之前，找不到自然落回主题（0.3.7）
- [x] 可访问性：附件（表格 / Mermaid / 图片）都带 `accessibilityDescription`——表格给 1×1 透明图挂上行列文本，Mermaid 挂源码，图片挂 alt；工具栏按钮有标签，字数胶囊是可访问按钮；单元测试断言三种附件的描述（#84，0.3.8）
- [x] 内部锚点跳转 / 相对链接打开 / 图片（点击用系统看图器打开）（#52）

### 5.2 工作台速赢（从 M6 拉入）
- [x] 快速打开 ⌘P：`FileIndex`（根目录后台整树扫描，≤ 50k 文件，复用侧栏的 FSEvents 流合并 0.8 s 重扫）+ `FuzzyMatcher`（DP 打分：边界 / 连续 / 文件名加权，CJK 逐字）+ 悬浮面板（↑↓ ⏎ Esc，命中字符着色）；这个索引也是 M7 wikilinks / 内容块补全的依赖（#62，0.3.3）
- [x] 全局搜索 ⌘⇧F：侧栏顶部搜索框，`ContentSearch`（mmap + memchr 行扫描，不把整文件转 String；ASCII 折叠大小写，非 ASCII 只在候选行解码）流式出结果：文件 → 命中行（行号 + 片段高亮）→ 点击跳到该行；Esc 清空 / 收起，↓ 进结果；50 MB 全扫 ~350 ms（debug），预算进 PERFORMANCE.md（#63，0.3.5）。正则开关 → 后续
- [x] 字数统计：右下角胶囊「N 字 · M 分钟」，点击看明细（字词 / 中文字 / 字符 / 行 / 阅读时间），有选区时显示选区；与解析同一趟后台计算，1 MB 2.2 ms（#65，0.3.1）。写作目标 → 随 M7 Focus 一起做
- [x] 剪贴板互通：编辑 → 复制为 Markdown（⇧⌘C）/ HTML（`.html` 给富文本 App + HTML 代码）/ 纯文本（去标记）；粘贴浏览器 / 富文本的 HTML 自动转 Markdown（`HTMLToMarkdown`：libxml2 tidy 解析，不经 WebKit），⇧⌘V 粘纯文本，设置可关（#66，0.3.4）

### 5.3 写作环境速赢（从 M7 拉入；只依赖源码编辑器）
- [x] 沉浸模式（⌘⇧D）：全屏 + 隐藏工具栏 / 标签栏 / 侧栏 / 行号 / 字数，编辑器居中限宽；Esc 或再按一次退出，退出全屏一并退出（#71，0.3.2）
- [x] Focus 三档（⌘D 循环；显示 → 专注 子菜单直选）：句子（NLTokenizer 切句，CJK 标点也认）/ 段落 / 打字机（只在键盘引起的光标移动时居中，点击不跳）。淡化用置顶透明层奇偶裁剪画，不改 textStorage；1 MB 击键 1.5 ms（#61，0.3.2）
- [x] 源码模式标记出挑：`#`、`-`、`1.`、`>` 出挑到左边距，正文左缘对齐，嵌套按缩进加深；设置里可关（#72，0.3.2）
- [x] 编辑器排版参数：设置 → 编辑：字体（等宽 + 已装 iA Writer）/ 字号 / 行距 / 行宽（60–100 字符，居中成列）；「下载 iA Writer 字体…」从 iaolo/iA-Fonts 取 6 个变量字体到 `~/Library/Fonts`（SHA256 校验、CTFontManager 注册），不随包（#73，0.3.6）

### 5.4 分发
- [ ] **公证（Developer ID + notarytool）**：需要 Apple Developer 账号的 Developer ID 证书与 App 专用密码（只有仓库所有者能做）；`scripts/release.sh` 预留接入点（#54，**待所有者提供证书**）
- [x] 更新检查：Quire 菜单「检查更新…」+ 每天一次启动后 8 s 后台比对 GitHub Releases（只读，不上传；可跳过某版本；设置可关）（#54，0.4.1）
- [x] Homebrew cask 文件 `Casks/quire.rb`（`release.sh` 自动更新版本与 sha256）；放到 tap 仓库 `chaoyi-ai/homebrew-quire` 后即可 `brew install --cask quire`——未公证前 caveats 提示去 quarantine（#54，0.4.1）
- [ ] Quick Look 预览扩展（复用 QuireRender）（#55）。**2026-08-23 spike 未通过**：纯 SwiftPM 手工组装 .appex（`-e _NSExtensionMain` + `-application_extension`、XPC! 包、沙盒 entitlements、ad-hoc 签名、资源 bundle 复制进 appex）能编译链接，但 `pluginkit -a` 不登记、`qlmanage -p` 在 `EXConcreteExtension makeExtensionContextAndXPCConnectionForRequest` 处 abort。怀疑 ad-hoc 签名 / 缺 Team ID 或入口方式；下一步：用 Xcode 生成一次标准 appex 对照 Mach-O 与 plist，或等 Developer ID 签名后再试。另注意 appex 会让 App +4 MB（静态链接一份 QuireCore/QuireRender/SwiftMath）
- [ ] 发布 1.0

**测试**：本地化字符串完整性测试（两套 .strings key 集合相等）；全局搜索 / 快速打开的基准进 `quire-bench`；Focus / 沉浸模式的几何测试（视口位移、隐藏后正文列宽）；VoiceOver 属性单元测试（附件 `accessibilityLabel`）。

## M6 · 混合实时预览与就地编辑（对标 Typora）→ 1.x

依据 [docs/research/typora.md](research/typora.md)。原则不变：不用 WebView 渲染正文、JSON 主题、默认 GFM、每项过 `scripts/bench.sh`。

**先验证再投入**：混合模式是整条路线技术风险最高的一项（TextKit 2 上源码与渲染混排，表格 / Mermaid 是片段里自绘的附件）。先做两周 spike，拿原型 + 性能数据 + go/no-go，再决定 6.1 的实现路径；表格架构（继续附件自绘 / 改文本流 / 改子视图）在 spike 里一并决策，它同时决定 #45 和 #57 怎么做。

**验收**：在混合模式里从零写出一份含表格、图片、数学的文档，全程不切到源码；表格文本可被 ⌘F 找到；打开 1 MB 文档的启动 / 内存 / 滚动指标与 M4 基线持平；击键路径 < 8 ms（`view/editor-keystroke-1mb`）。

### 6.0 验证
- [x] Spike：混合实时预览技术验证（#85，0.4.2）→ **go**。原型 `HybridTextView`（ReaderTextView 子类，⌘4「混合（实验）」）：点击块 → 该块的渲染串换成原始源码行（等宽、代码底色）并可编辑，编辑只允许落在该块内；击键回写文档源码（不重渲染）；离开块（点别处 / Esc / ⌘↩）宿主重解析、按 diff 增量重渲染，块被拆分 / 合并交给解析器。附件块（表格 / Mermaid / 图片 / 数学）激活后就是它们的 Markdown 源码。坑：增量替换按上一版 ranges 定位，源码态的块必须先换回上一版渲染串再替换，否则留残片（`restoreSourceForm`）。未做：方向键跨块、点击处光标精确定位、源码态语法高亮、撤销分组、1 MB 击键回写走整篇 join（~5 ms，要改成行索引）
- [x] 表格架构决策：**表格继续是附件自绘**。编辑 = 源码态（激活后是 Markdown 表格文本），不做渲染态单元格编辑；#57 改为"源码态表格辅助：Tab 跳格、自动对齐格式化、`|a|b|` 回车生成"；#45 表格可查找另做（附件文本镜像进查找）

### 6.1 混合模式与就地编辑
- [x] 行内实时预览模式（#50，0.4.2 原型 → 0.4.13 打磨）：点击处光标精确定位（渲染前文末尾倒查源码）、↑↓ 在块首尾跨块、源码态用 MarkdownLexer 着色（`BlockRole.source` 整块浅底，无复制按钮）、块级元素（表格 / 图片 / Mermaid / 数学 / 代码 / HTML）源码下方保留渲染预览并随编辑 150 ms 刷新（Typora 的做法）。未做：撤销按块分组、1 MB 击键回写行索引化（现 ≈ 5 ms）
- [x] 表格文本可查找（#45，0.4.10）：表格附件后面跟一段不可见镜像（0.01pt、透明、U+2028 分行 / Tab 分列），⌘F 能命中并滚到表格，复制表格段落得到 TSV；视觉零影响
- [x] 表格源码辅助（#57，0.4.11；表格留附件自绘，编辑在源码编辑器 / 混合模式源码态）：`TableFormatter` 等宽对齐（CJK 算 2 格，保留 `:--:` 对齐标记）；Tab / ⇧Tab 在单元格间移动并选中内容，越过分隔行，末格 Tab 追加一行；表头行回车自动补分隔行与空行，表内回车补新行；格式 → 格式化表格（⌘⇧T）。增删列 / 拖列宽 → 不做（源码态直接改）
- [x] 图片：编辑器里粘贴剪贴板图片（截图 / 浏览器复制）→ 存到 `<文档目录>/assets/<文档名>/pasted-时间戳.png` 并插入 `![](相对路径)`，光标停在 `[]` 里；独占的 `<img src width>` HTML 块按图片渲染（可带 `<p align>` 包装），`![](x){width=50%}` / `width="300"` 按指定宽度显示且不超内容列（#58，0.4.3）
- [x] 数学块：混合模式里点击公式 → 源码 + 下方实时预览（同一套块级预览机制），⌘↩ / Esc / 点击外部退出（#59，0.4.13）。公式编号 / `\label` `\ref` → 随 M7 需要时再做
- [x] 悬浮格式工具条（选中文字时浮在选区上方：粗 / 斜 / 删除线 / 代码 / 链接 / H1–H3 / 引用 / 列表，滚动跟随、失焦隐藏、设置可关）与右键样式菜单；新增 setHeadingLevel / toggleQuote / toggleBulletList 行级切换（#60，0.4.12）

### 6.2 工作台与语法
- [x] 侧栏显示规则：设置 → 侧栏：显示隐藏文件、显示非 Markdown 文件（双击用默认 App 打开）、额外扩展名按 Markdown 处理；改规则后已展开的文件夹重扫并保持展开。键盘：↑↓←→（系统）、回车打开 / 折叠展开、空格 Quick Look（#64，0.4.5）
- [x] 扩展行内语法（设置 → 扩展语法 逐项开关，默认全关）：`==高亮==`、`~下标~`（GFM 把单波浪线也当删除线，开着时按原文区分 `~` / `~~`）、`^上标^`、`<u>下划线</u>`（把 inline HTML 对包起来）、`:emoji:`（150 个 GitHub 短码）。后处理 `.text` / `.html` 节点，不改 cmark；HTML 导出 `<mark>/<sub>/<sup>/<u>`，粘贴 HTML 反向转换（#67，0.4.8）
- [x] `[TOC]` / `[[TOC]]` / `{{TOC}}` 独占段落 → 按标题生成嵌套链接列表（解析期展开，点击走内部锚点）；标题自动编号（按文档最小级别相对计，开着时增量渲染退化为全量）；智能标点用 cmark `CMARK_OPT_SMART`。三者在设置 → 阅读 开关，TOC 默认开（#68，0.4.6）

### 6.3 导出与集成
- [x] PDF 书签（大纲 → `PDFOutline` 嵌套，目标页与页内位置按打印分页算）；导出为图片（800pt 宽整页 PNG 2×，上限 16000pt 高并提示）；pandoc 可选：装了 pandoc 才出现 导出 → Word / EPUB / LaTeX 与 导入 Word / HTML / EPUB…（stdin 喂源码，`--resource-path` 文档目录）（#69，0.4.9）。调试钩子 `QUIRE_EXPORT_PNG=path`
- [x] `quire` 命令行工具（随包 `Contents/Resources/quire`；`quire file.md` / `quire .`——目录里没有 .md 时新建文档并把侧栏根设为该目录），设置 → 语言区「安装命令行工具」软链到 `/usr/local/bin`；服务菜单「Open in Quire」（Info.plist NSServices + servicesProvider）（#70，0.4.4）

**测试**：混合模式的源码 ↔ 渲染往返测试（任意文档进出混合模式字节不变）；表格编辑的 GFM 写回测试；扩展语法开关关闭时 CommonMark spec 抽样结果不变。

## M7 · 文本智能与组织（对标 iA Writer）→ 1.x

依据 [docs/research/ia-writer.md](research/ia-writer.md)。原则：**全部本地、不改文本、不入导出、可整体关闭**；文本智能只处理可见段落并在后台增量计算，1 MB 文档开启全部功能后击键路径仍 < 8 ms、空闲 CPU 0%。

**验收**：英文文档开启词性高亮 + 文风检查后滚动 60 fps、空闲 CPU 0%、常驻内存增量 < 10 MB；中文词性高亮按评估结果决定开 / 关；`[[` 弹出补全并能就近解析到同名文件，`[[../../etc/passwd]]` 之类越界路径被拒绝；著作归属在其他编辑器里只表现为文件尾一段注释，导出产物不含，外部修改文件后归属区间仍与文本对齐或被整体丢弃并提示（不得错位）。

### 7.1 文本智能
- [x] 词性高亮（#74，0.5.0）：显示 → 词性高亮：全部 / 只看名词 / 动词 / 形容词 / 副词 / 连词介词。NLTagger 只处理可见段落 ± 一屏，后台分词，主线程只给"正文色"的字改色（标记 / 代码 / 链接不动）；编辑与滚动防抖重着色。**中文评估结论**：NLTagger 对 zh-Hans 的 lexicalClass 全部返回 OtherWord（能分词、不能分词性），所以中文段落不着色；支持 en / de / fr / it / es / pt / ru / nl
- [ ] 文风检查：规则引擎划掉填充词 / 冗余 / 陈词滥调；内置英文词表 + 自建中文词表；用户规则文件 `~/Library/Application Support/Quire/style-rules.txt`（字面 / `-` 例外 / `/…/` 有限正则，明确列出支持的子集）；只在编辑器显示（#75）

### 7.2 著作归属（Authorship）
- [ ] 记录键入 vs 粘贴区间；作者表（我 / AI / 引用 / 自定义，各有颜色）；"以某作者粘贴"、"标记选区为某作者"；存文件尾 `<!-- quire-authorship … -->` 注释块，编辑时增量维护区间，**外部修改后按内容哈希重对齐、对不上则丢弃并提示**；导出 / 复制时剥离；⇧⌘A 开关（#77）

### 7.3 链接与组织
- [ ] `[[wikilink]]`：输入 `[[` 弹补全（复用 #62 索引）；`[[目标 | 显示名]]`；就近解析（同目录 > 子目录 > 父目录），**解析结果必须在根目录内**；⌘↩ / ⌘点击跳转；前进 / 后退历史；渲染为链接，导出为纯文本（#78）
- [ ] `#标签` 索引进侧栏（点击 = 全局搜索 #63）；收藏与最近（#79）
- [ ] 内容块（transclusion）：**用 `![[file]]`（Obsidian 风格，与 wikilinks 同族），不用 iA 的裸行写法——裸行会改变合法 GFM 段落的语义**；`.csv` → 表格、图片、`.md` 展开；默认关；渲染时展开、导出时内联；循环包含与越界路径检测（#80）

### 7.4 导出与集成
- [ ] PDF 排版参数：页边距、页眉 / 页脚占位符、标题编号、标题不孤行，进导出面板并记忆（#81）
- [ ] `quire://open?path=…&line=…` URL scheme（**来自外部 App 的打开先弹确认，路径限制在已打开的根目录或用户明确选择过的位置**）；Apple Shortcuts 动作（打开、新建、追加文本、导出 PDF）（#82）

**测试**：词性 / 文风标注不改变 textStorage 字符串（字节级断言）；著作归属区间在插入 / 删除 / 外部重载后的对齐测试；wikilink / 内容块路径解析的越界用例；导出产物不含归属注释块。

## 长期想法（未排期）

- tree-sitter 作为可选高亮后端
- 可选沙盒 / 公证发行
- 快捷键自定义、Vim 键位、文本片段（snippets）（社区贡献）
- 文章列表视图（文件名 + 正文摘要）、"Open in Quire" VS Code 扩展
- Smart Folders（按查询式的动态文件夹）、表格公式、元数据变量（iA Writer 有，用的人少）
