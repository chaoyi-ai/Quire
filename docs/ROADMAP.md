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
| M5 | 可视化编辑 | 行内实时预览编辑，数学公式，脚注/锚点，本地化，Homebrew 分发，发布 1.0 | |
| M6 | 写作工作台（对标 Typora） | 表格就地编辑、图片粘贴、快速打开 / 全局搜索、字数、剪贴板互通、扩展语法开关、导出补全 | 调研见 [research/typora.md](research/typora.md) |
| M7 | 写作环境与文本智能（对标 iA Writer） | 沉浸模式、Focus 句 / 段 / 打字机、标记出挑、词性高亮、文风检查、著作归属、Wikilinks / 标签 / 收藏、内容块、PDF 排版参数 | 调研见 [research/ia-writer.md](research/ia-writer.md) |

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

## M5 · 可视化编辑 → 1.0

- [ ] 行内实时预览模式（光标块显源码，其余渲染）
- [ ] 表格文本可查找（镜像隐藏文本或自定义 finder client）
- [ ] 主题级字体覆盖（设置里选字体 / 字号）
- [ ] 数学公式（评估 SwiftMath 或自绘 KaTeX 子集，不引入 WebView）
- [x] 内部锚点跳转 / 相对链接打开 / 图片（点击用系统看图器打开）
- [ ] 本地化：zh-Hans / en
- [ ] Homebrew cask、Sparkle 或手动更新检查（可关闭）
- [ ] Quick Look 预览扩展（复用 QuireRender）

## M6 · 写作工作台（对标 Typora）→ 1.x

依据 [docs/research/typora.md](research/typora.md)。原则不变：不用 WebView 渲染正文、JSON 主题、默认 GFM、每项过 `scripts/bench.sh`。M5 的混合实时预览是 M6 一切"就地编辑"的地基，M6 在其之上补 Typora 用户最依赖的写作与工作台能力。

**验收**：在混合模式里从零写出一份含表格、图片、数学的文档，全程不切到源码；⌘P 三次击键内打开根目录任意文件；⌘⇧F 在 1000 个文件 / 50 MB 的目录里 300 ms 内出首批结果；打开 1 MB 文档的启动 / 内存 / 滚动指标与 M4 基线持平。

### 6.1 就地编辑（依赖 M5 混合模式）
- [ ] 表格：Tab / ⇧Tab 跳格、回车新行、末行回车退出；右键 / 菜单增删行列、设列对齐；拖拽调列宽（写回为内容宽度，不引入非标语法）；`|a|b|` 回车生成表格
- [ ] 图片：粘贴剪贴板图片 → 存到 `assets/<文档名>/` 相对路径并插入 `![](…)`（目录可在偏好里改）；拖入同理（已有）；`<img width>` / `{width=50%}` 的缩放显示（只读渲染，写法不改）
- [ ] 数学块：源码 + 预览组合控件（`$$` 回车进入，⌘↩ / 点击外部退出）；公式自动编号与 `\label` / `\ref`（M5 数学基础之上）
ef`（M5 数学基础之上）
- [ ] 悬浮格式工具栏（选中文字时：粗 / 斜 / 代码 / 链接 / 标题级别）与右键样式菜单
- 专注模式 / 打字机模式 → 移到 M7（iA Writer 的三档 Focus 一起做）

### 6.2 工作台
- [ ] 快速打开 ⌘P：根目录内模糊匹配文件名（后台索引、FSEvents 增量更新，复用侧栏的目录缓存）
- [ ] 全局搜索 ⌘⇧F：根目录全文搜索，流式结果（文件 → 命中行 → 点击跳到该行），自研扫描器走 mmap + memchr，大小写 / 正则开关；性能预算写进 PERFORMANCE.md
- [ ] 侧栏显示规则：隐藏文件、非 Markdown 文件、自定义扩展名；文件树键盘导航（↑↓←→ / 回车打开 / 空格 Quick Look）
- [ ] 字数统计：状态栏右下角（字 / 词 / 行 / 阅读分钟，有选区时显示选区），惰性计算，1 MB 文档 < 5 ms

### 6.3 剪贴板与语法
- [ ] 复制为 HTML（富文本 App 可粘）/ 复制为 Markdown（⇧⌘C）/ 复制为纯文本；粘贴 HTML 自动转 Markdown（⇧⌘V 粘纯文本）
- [ ] 扩展行内语法（偏好里逐项开关，默认关）：`==高亮==`、`~下标~`、`^上标^`、`<u>下划线</u>`、`:emoji:`
- [ ] `[TOC]` 块、标题自动编号（主题级开关）、SmartyPants 智能标点（可选）

### 6.4 导出与集成
- [ ] PDF 书签（大纲 → PDF outline）、导出为图片（整页 PNG，2×）
- [ ] pandoc 可选集成：检测到 `pandoc` 时在导出 / 导入菜单出现 docx / epub / LaTeX（不内置、不下载）
- [ ] `quire` 命令行工具（`quire file.md` / `quire .`），偏好里一键安装到 `/usr/local/bin`
- [ ] macOS 服务菜单 "在 Quire 中打开"

## M7 · 写作环境与文本智能（对标 iA Writer）→ 1.x

依据 [docs/research/ia-writer.md](research/ia-writer.md)。iA Writer 的价值在"写作环境"与"本地文本智能"，两者都能在 TextKit 2 + NaturalLanguage 上原生做。原则：**全部本地、不改文本、不入导出、可整体关闭**；文本智能只处理可见段落并在后台增量计算，1 MB 文档开启全部功能后击键路径仍 < 8 ms（`view/editor-keystroke-1mb`）。

**验收**：⌘⇧D 一键进入无 chrome 全屏写作，Focus 句级淡化随光标即时跟随且不抖动；英文文档开启词性高亮 + 文风检查后滚动 60 fps、空闲 CPU 0%；中文词性高亮按评估结果决定开 / 关；`[[` 弹出补全并能就近解析到同名文件；著作归属在其他编辑器里只表现为文件尾一段注释，导出产物不含。

### 7.1 写作环境
- [ ] 沉浸模式（⌘⇧D）：隐藏工具栏 / 标签栏 / 侧栏 / 行号栏，只剩正文列；全屏 + 深色组合记忆；Esc 退出
- [ ] Focus 三档（⌘D 循环）：**句子**（NLTokenizer 句切分，当前句纯色、其余淡化）/ 段落 / 打字机（光标锁中线；有选区或鼠标点击时不强行居中，避免 iA 文档里提到的"屏幕跳"）
- [ ] 源码模式标记出挑：`#`、`-`、`1.`、`>` 出挑到左边距，正文左缘对齐（段落样式 firstLineHeadIndent 负缩进 + 制表位）
- [ ] 编辑器排版参数：行宽（字符数）/ 行距 / 字号 / 字体，进偏好；可选附带开源字体 iA Writer Mono / Duo / Quattro（IBM Plex 衍生，OFL，随包需署名）或引导用户安装

### 7.2 文本智能（本地、不改文本、不入导出）
- [ ] 词性高亮：NLTagger `.lexicalClass`，名 / 动 / 形 / 副 / 连 / 代 各一色（主题里定义）；可只开一类；只标注可见段落 + 前后各一屏，后台计算、主线程只着色；先英文，**中文先做可用性评估**（NLTagger 对 zh 的 lexicalClass 覆盖），不可用则中文只做分词着色或关闭
- [ ] 文风检查：规则引擎划掉填充词 / 冗余 / 陈词滥调；内置英文词表 + 自建中文词表（"进行…的操作"、"的的"、套话）；用户规则文件 `~/Library/Application Support/Quire/style-rules.txt`（字面 / `-` 例外 / `/…/` 有限正则，明确列出支持的子集）；只在编辑器显示
- [ ] 统计扩展：句子数、每段字数、写作目标（字数 / 截止），进度显示在状态栏（基础统计在 M6 #65）

### 7.3 著作归属（Authorship）
- [ ] 记录键入 vs 粘贴区间；作者表（我 / AI / 引用 / 自定义，各有颜色）；"以某作者粘贴"、"标记选区为某作者"
- [ ] 存储：文件尾一段 `<!-- quire-authorship … -->` 注释块（其他编辑器可见但无害），编辑时随文本变化增量维护区间；导出 HTML / PDF / 复制时剥离
- [ ] 显示：⇧⌘A 开关；我 = 正常，AI = 渐变色，引用 = 淡化；侧栏文件图标角标

### 7.4 链接与组织
- [ ] `[[wikilink]]`：输入 `[[` 弹补全（根目录文件名索引，复用 M6 快速打开的索引）；`[[目标 | 显示名]]`；就近解析（同目录 > 子目录 > 父目录）；⌘↩ / ⌘点击跳转；前进 / 后退历史（⌃⌘← / →）；渲染为链接，导出为纯文本
- [ ] `#标签`：扫描文档里的 hashtag（Twitter 规则），侧栏"标签"分组，点击 = 全局搜索该标签
- [ ] 收藏与最近：侧栏顶部"收藏 / 最近 25 个"，右键加入收藏
- [ ] 内容块（transclusion）：单独一行的 `/chapter.md "标题"`、`data.csv`（→ 表格）、`img.png (说明)`，渲染时展开、导出时内联；`/` 触发补全；循环包含检测

### 7.5 导出与集成
- [ ] PDF 排版参数：页边距、页眉 / 页脚（标题、页码、日期占位符）、标题编号、分页规则（标题不孤行），进导出面板并记忆
- [ ] `quire://open?path=…&line=…` URL scheme；Apple Shortcuts 动作（打开、新建、追加文本、导出 PDF）

## 长期想法（未排期）

- tree-sitter 作为可选高亮后端
- 可选沙盒 / 公证发行
- 快捷键自定义、Vim 键位、文本片段（snippets）（社区贡献）
- 文章列表视图（文件名 + 正文摘要）、"Open in Quire" VS Code 扩展
- Smart Folders（按查询式的动态文件夹）、表格公式、元数据变量（iA Writer 有，用的人少）
