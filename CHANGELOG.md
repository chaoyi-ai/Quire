# Changelog

## 0.3.1 — 2026-08-23

- 新增：字数统计（#65）。阅读 / 编辑窗格右下角胶囊显示「N 字 · M 分钟」，有选区时显示选区字数，点击弹出明细（字词 / 其中中文字 / 字符 / 行 / 阅读时间）。CJK 每字计一、拉丁按词计；与解析同一趟后台计算，1 MB 约 2 ms，新增 `stats/large-1mb` 基准门禁（< 5 ms）。设置 → 阅读 可关闭。

## 0.3.0 — 2026-08-23

M5（1.0 发布）第一项。

- 新增：界面本地化 zh-Hans / en。全部菜单、工具栏、设置、侧栏、提示与错误文案跟随系统语言；设置 → 语言 可覆盖为简体中文 / English（重启生效）。实现：`L()` / `RL()` 以中文原文为键，`LocalizationTests` 保证代码、zh-Hans、en 三者键集合一致，漏翻即红。

## 0.2.7 — 2026-08-18

- 修复：侧栏点标题后阅读视图定位偏上——目标块被对齐到滚动视图 bounds 顶部，而顶部有工具栏 + 标签栏盖住的 88pt（`automaticallyAdjustsContentInsets`），标题藏在工具栏下面。现在所有"可见区顶部"计算（跳转、位置恢复、顶部块取样、编辑器同步）都加上 `contentInsets.top`；滚到文首时内容顶贴在标签栏下方。
- 改进：侧栏"当前章节"高亮不再按最顶上一行算（下一标题到了屏幕正中还高亮上一章尾巴）：取样点在可见区顶部往下 40%，下一标题升到中线以上即切换；刚从侧栏跳到某标题时以该标题为准；滚到底时高亮末章。滚动同步仍按顶部块（`onTopBlockChanged` / `onSectionChanged` 分开）。
- 测试：`ScrollGeometryTests`（带 contentInsets 的跳转落点、章节切换阈值）。

## 0.2.6 — 2026-08-18

- 修复：表格单元格文字上窄下宽——行高按 `lineHeight + 内边距` 算，而单行文字的自然高度（字体 ascent+descent）比 lineHeight 小，绘制时顶对齐把多出来的高度全留在下面。现在测量时记下每格文字高度，绘制时垂直居中（同一行里较矮的单元格同样居中，与浏览器 `vertical-align: middle` 一致）。

## 0.2.5 — 2026-08-18

代码审查版本：清理"假完成 / 死代码 / 双重逻辑"，复测性能并修掉三个视图层卡点。

- 性能：主题切换 / 外部重载 / 缩放时阅读视图整体换内容，1 MB 文档主线程 **4.1 s → 44 ms**（TextKit 2 已有布局时直接 `setAttributedString` 会逐段落对账；先清空再设）。
- 性能：不再对整份 textStorage 枚举附件（1 MB 100 ms/次，原先每次 setRendered、每次击键增量替换、每次改宽都做）；渲染阶段按块标记有无图片 / Mermaid，只扫这些块。
- 性能：编辑器击键路径 1 MB 文档 ≈ 10 ms → 0.8 ms（分块 `getCharacters` 一趟建行索引 + 每行围栏状态表；增量高亮起始状态查表）。
- 性能：`quire-bench views` 新增视图层基准（`view/reader-setRendered-1mb`、`view/editor-keystroke-1mb`）并纳入门禁；`blockIndex(forLine:)` 二分。
- 修复：主题切换 / 重载后恢复滚动位置——原实现的偏移在异步二次对齐里被抹掉，且对未布局位置 `textLayoutFragment(for:)` 返回错误片段，1 MB 文档会回到文首；按内容哈希找回原块时取第一个匹配（重复内容的文档会跳到前面）。现在：偏移进对齐计算、片段用 `ensuresLayout` 枚举、"设视口 → 布局视口 → 重算"收敛、哈希就近匹配。编辑器滚动同步同样收敛。
- 修复：大文件模式下每次都新建 `RenderStyle`，导致增量渲染路径永远不命中（每次击键全量重设）；现在派生 style 缓存。
- 修复：有未保存改动时磁盘文件被外部修改，原来只 NSLog 一句就跳过（注释写着"M4：冲突处理 UI"但从未做）。现在弹 sheet 让用户选择重新载入或保留改动。
- 修复：Mermaid 串行渲染用 10 ms 忙等轮询排队，改为 continuation 队列；侧栏大纲不变时不再重载；目录变化只遍历一次；`HeadingScanner.isRule` 逻辑理顺。
- 清理死代码：`QuireAttribute` 里从未读取的 8 个自定义属性（headingID / imageSource / taskChecked / listDepth / table / mermaidSource / footnoteLabel / quoteLast）及其写入、`Document.lineCount`、`DocumentRenderer.rerender`、`RenderStyle.codeBold`、`MermaidRenderer.errorText/isWebViewAlive`、`ReaderTextView.imageRequestsInFlight/resetCursorRects/isFlipped`、`EditorTextView.showsLineNumbers`、`Theme.withAlpha`、`GenericLexer.hashComments`、`Languages.cLikeConstants`、`NSImage.tinted`、`AppDelegate.pendingFiles` 等；`ReaderViewController.apply` 里一个恒真条件。
- 文档：DESIGN.md ADR-13（TextKit 2 三条硬规矩）；PERFORMANCE.md 新预算与基线。

## 0.2.4 — 2026-08-17

- 修复：阅读模式下切到编辑 / 分栏时崩溃（编辑器视图尚未加载就被同步源码）。
- 修复：行内代码框左右不对称——代码含 CJK 时 SF Mono 回退到 PingFang，回退 run 把尾部窄空格撑宽。现在两侧留白改为正文字体的独立 run（同样纳入框内），几何测试保证左右对称。
- 修复：编辑器顶部内容被工具栏遮住（`automaticallyAdjustsContentInsets`）。

## 0.2.3 — 2026-08-17

- 新增：拖放。从 Finder 拖 `.md` 到阅读区 / 编辑器 / 侧栏即打开（多选可同时打开）；拖图片到编辑器在落点插入 `![名称](相对路径)`，其他文件插入 `[文件名](相对路径)`。
- 修复：0.2.2 的行内代码框位置偏上（固定行高时字形贴底，按整行居中不对）。改为以基线为准：上伸 + 2pt … 下伸 + 2pt。

## 0.2.2 — 2026-08-17

- 修复：行内代码背景上下留白不一致（原来用 `.backgroundColor`，高度跟着较小的代码字体、按基线对齐）。改为在布局片段里自绘圆角框，按行高垂直居中。
- 修复：Mermaid / 远程图片异步渲染完成替换占位时，视口被 TextKit 2 重排带跑（表现为滚到该块顶部）。替换前后用"顶部块 + 块内偏移"锁住可见位置；并按"离视口最近优先"的顺序渲染。

## 0.2.1 — 2026-08-17

- 修复：侧栏点击较远章节时，左侧高亮随动画逐个章节跳动、最后停在错误位置。原因一是滚动动画途中每帧都在按"顶部块"更新高亮，二是取样点落在目标块上方 4pt（上一个块）；另外 TextKit 2 对视口外只估算高度，按估算 y 滚动会落空（1 MB 文档偏差达数百块）。现在：导航期间挂起滚动驱动高亮、完成后明确高亮目标章节；先用 `scrollRangeToVisible` 进入视口再按真实片段位置对齐（两遍），1 MB 文档 6 ms 且精确到块；超过 3 屏的跳转不做动画。
- 侧栏点击去重（action 与 selectionDidChange 各触发一次）。

## 0.2.0 — 2026-08-17

- 侧栏升级为**文件树 + 大纲**混合导航：根目录（默认文档所在文件夹，可用路径栏 / ⌘⇧O 切换）→ 子文件夹 → Markdown 文件 → 标题层级。当前文件加粗并展开完整大纲（完整解析结果）；其他文件展开时用快速标题扫描（`HeadingScanner`，~1 GB/s，按 mtime 缓存，> 4 MB 不扫）。点击标题跳转，点击文件在新标签页打开，点击其他文件的标题打开并跳到该行。
- 性能：目录与标题只在展开时后台加载；整棵树一个 FSEvents 流（合并 0.6 s）监听增删改并复用节点保持展开状态；图标用缓存的 SF Symbol；1200 项根目录不影响启动时间，空闲 CPU 0%。
- 菜单：文件 → 在侧栏打开文件夹…（⌘⇧O）；显示 → 在侧栏中显示当前文件（⌘⇧J）。

## 0.1.1 — 2026-08-17

- 修复：长文档只显示首屏、无法滚动（代码创建的 NSTextView 默认 `maxSize` 等于初始 frame，阅读视图与编辑器均被卡在 600 pt）。加回归测试。
- 阅读视图：点击图片用系统看图器打开。

## 0.1.0 — 2026-08-17

首个公开版本。

### 阅读
- 原生渲染（AppKit + TextKit 2，无 WebView）：标题 / 段落 / 强调 / 删除线 / 行内代码 / 链接 / 图片（本地 + 远程，downsample）/ 列表（含任务）/ 引用 / 分割线 / HTML 块 / front matter / 脚注
- 代码高亮：自研词法器，30+ 语言，无 JS 运行时
- GFM 表格：原生绘制，自适应列宽、对齐、斑马纹、单元格内行内样式
- Mermaid：惰性离屏 WebKit 渲染（唯一用到 WebKit 的地方），2× 位图缓存到磁盘，空闲 30 s 销毁
- 10 套内置主题（GitHub Light/Dark、Paper、Solarized、Nord、Dracula、One Dark、Gruvbox），JSON 自定义主题、热切换、跟随系统明暗
- 目录侧栏、外部修改自动重载（保持滚动位置）、缩放、查找、打印、代码复制按钮、可选代码行号
- 大文件模式（默认 > 8 MB：关闭高亮与 Mermaid）

### 编辑
- 源码编辑器（TextKit 2）：增量 Markdown 高亮、行号、当前行、软换行
- 列表 / 任务 / 有序 / 引用续行，围栏自动闭合，Tab/Shift-Tab 多行缩进，⌘B/⌘I/⌘K/⌘E
- 阅读 / 编辑 / 分栏三态，分栏双向滚动同步；块级增量预览（击键 → 预览 1.4 ms）
- 标准 NSDocument：保存 / 另存 / 自动保存 / 版本 / 撤销

### 导出
- HTML（内联主题 CSS，代码高亮为 span，Mermaid 经 CDN 脚本渲染）
- PDF（原生打印管线，按块边界分页）

### 性能（Apple M 系列，macOS 26）
- 解析 1 MB：42 ms；解析 + 渲染：160 ms；主题切换：114 ms；增量编辑：1.4 ms
- 热启动到首帧：350–400 ms；常驻内存 40 MB（典型）/ 90 MB（1 MB 文档）；空闲 CPU 0%
- App 6.5 MB（含 mermaid.min.js）

详见 docs/PERFORMANCE.md、docs/DESIGN.md（ADR）。
