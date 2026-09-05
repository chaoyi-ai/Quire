# Quire 设计文档

> 状态：Living document。任何架构级改动先改这里，再改代码。
> 配套文档：[性能预算](PERFORMANCE.md) · [主题规范](THEMES.md) · [路线图](ROADMAP.md)

## 1. 一句话定位

**Quire 是一个 macOS 原生的 Markdown 阅读器 / 编辑器，把"快"和"省"当作第一功能。**
打开一个 Markdown 文件应该像打开 TextEdit 一样瞬间；空闲时不占 CPU；内存占用是 Electron 类工具的十分之一量级；同时不牺牲现代 Markdown 该有的东西：多主题、代码高亮、GFM 表格、Mermaid 图。

## 2. 目标与非目标

### 目标

| # | 目标 | 可度量的定义 |
|---|------|--------------|
| G1 | 快 | 冷启动到首屏 < 300 ms；1 MB Markdown 解析 + 渲染 < 200 ms；滚动 60 fps；编辑回显 < 16 ms |
| G2 | 省 | 典型文档常驻内存 < 40 MB；空闲 CPU 0%；无常驻定时器；无后台进程（Mermaid 除外，见 §6.7） |
| G3 | 原生 | AppKit + TextKit 2；系统外观/字体/滚动/辅助功能/查找/打印全部原生 |
| G4 | 完整 | CommonMark + GFM（表格、任务列表、删除线、自动链接、脚注）+ 代码高亮 + Mermaid + 数学（后期） |
| G5 | 多主题 | 主题即数据（JSON），内置 8+ 套，支持用户主题、跟随系统明暗、热切换不重解析 |
| G6 | 可编辑 | 源码编辑 + 分栏实时预览（M3）；行内可视化编辑（M6，先 spike） |
| G7 | 开源 | MIT；纯 SwiftPM，`swift build` 即可编译；无私有依赖 |

### 非目标（至少 1.0 之前）

- 不做笔记库 / 知识管理：M7 之后有了 `[[wikilink]]` 与 `#标签` 索引，但它们只是「文件夹 + 文件」之上的轻量导航——不做图谱、不做独立的标签数据库、不强迫用户进入一个"库"
- 不做云同步 / 账号
- 不做插件系统（先把内核做扎实；主题是唯一扩展点）
- 不做 Windows / Linux（原生是有代价的，我们付这个代价）
- 不做完整 WYSIWYG（Typora 式）——M6 先 spike 验证再做"行内实时预览"与表格 / 图片 / 数学的就地编辑（见 `docs/research/typora.md`），M7 补 iA Writer 式的本地文本智能与组织（见 `docs/research/ia-writer.md`），写作环境（沉浸 / Focus）提前到 M5；仍不追求所见即所得的完备性
- 不用 WebView 渲染正文（Mermaid 是唯一例外，且被严格隔离）

## 3. 关键技术决策（ADR 摘要）

| ID | 决策 | 备选 | 理由 |
|----|------|------|------|
| ADR-1 | **正文用 TextKit 2 原生渲染，不用 WKWebView** | WKWebView + HTML/CSS（Typora / MarkText / 大多数工具的做法） | WebKit 一个进程起步 60–100 MB，冷启动慢，主题 = CSS 但一切都隔着一层 IPC；原生渲染让选择/查找/辅助功能/打印/字体渲染都是系统级的，且内存 < 40 MB 可实现。代价：表格 / Mermaid / 数学要自己想办法（见 §6） |
| ADR-2 | **解析器用 cmark-gfm（C API 直调）** | 自写解析器；swift-markdown；Down（cmark）；Ink | cmark-gfm 是 GitHub 生产级 C 实现，快且符合 GFM 规范，自带 Table / Strikethrough / TaskList / Footnotes / 源码位置。最初用 swift-markdown 封装，实测其中间 AST 层占解析时间 45%（1 MB：136 ms → 直调 42 ms），且不暴露脚注扩展，故改为直接遍历 cmark 节点（ADR-12）。自写解析器不值得 |
| ADR-3 | **块级增量渲染** | 每次全量重渲染 | 编辑器场景每次击键都全量渲染 1 MB 文档不可接受；按顶级块哈希 diff，只重建变化块的 attributed string 与布局 |
| ADR-4 | **Mermaid 用惰性离屏 WKWebView 渲染成 SVG，缓存后显示为图片** | 原生实现 Mermaid（工程量巨大）；始终常驻 WebView；JavaScriptCore（Mermaid 需要 DOM，跑不起来） | Mermaid 事实上只有 JS 实现。把 WebView 限制为：文档含 mermaid 块时才创建、全局单例、渲染完空闲 30 s 后销毁、结果按内容哈希落盘缓存。绝大多数文档从不触发 WebKit |
| ADR-5 | **代码高亮用自研轻量词法器（每语言 <150 行）** | tree-sitter（C + 每语言几百 KB 语法，二进制体积和内存都涨）；Highlightr（highlight.js 跑在 JavaScriptCore 里，慢且占内存） | 阅读器场景不需要语义级高亮；关键字 / 字符串 / 注释 / 数字 / 类型 的词法高亮覆盖 95% 的观感需求。词法器接口设计成可替换，未来 tree-sitter 可作为可选后端 |
| ADR-6 | **表格用自定义 NSView 附件（NSTextAttachmentViewProvider）** | TextKit 1 的 NSTextTable（老、慢、不可控外观）；把表格转成等宽文本 | 自绘表格视图可精确控制对齐、斑马纹、边框、单元格换行、水平滚动；作为附件嵌入 TextKit 2 文本流保持整体滚动统一 |
| ADR-7 | **纯 SwiftPM，脚本组装 .app** | Xcode 工程；XcodeGen；Tuist | 贡献者 `swift build` 就能跑；库层可以 `swift test`；Xcode 直接打开 `Package.swift` 也能开发。App 壳由 `scripts/build_app.sh` 组装 |
| ADR-8 | **主题即 JSON 数据** | 硬编码 Swift；CSS | 用户可写、可分享；热切换只需重建 attributed string 属性，不需重新解析 |
| ADR-9 | **最低 macOS 14** | 12 / 13 | TextKit 2 在 14 才够稳（12/13 的 NSTextView TextKit 2 有大量回退到 TextKit 1 的坑）；Swift 6 并发 API 完整 |
| ADR-10 | **文件监控用 DispatchSource，不轮询** | Timer 轮询 mtime | 零空闲 CPU |
| ADR-11 | **属性字符串 run 追加走 ObjC 直通（`CQuireAttr`），属性字典预先 uniqued 并缓存** | 纯 Swift `NSAttributedString(string:attributes:)` | 实测：Swift 侧每个 run 要把 `[Key: Any]` 桥接为 NSDictionary 再 uniquing 哈希，1.5 µs/run；ObjC 直通 + 预 uniqued 字典 + `replaceCharacters/setAttributes` 为 0.25 µs/run（6×）。1 MB 文档 ≈ 20 万 run，渲染从 527 ms 降到 109 ms。同时严禁"先 append 再回头 addAttribute(range:)"（O(runs) 字典合并） |
| ADR-12 | **不经 swift-markdown，直接遍历 cmark-gfm 节点** | swift-markdown Swift AST | 见 ADR-2：少一层 AST 拷贝，解析 3× 提速，且拿到 footnotes；类型判断对扩展节点（table / strikethrough / tasklist）用 `cmark_node_get_type_string` |
| ADR-15 | **数学用 SwiftMath（iosMath 的 Swift 移植）原生绘制，不用 MathJax/KaTeX + WebView** | WebView 跑 MathJax；自绘 KaTeX 子集 | 运行时依赖从"只有 cmark-gfm"变为 + SwiftMath（MIT，纯 Swift，CoreText + OpenType MATH 表）。spike 数据：0.29 ms / 式、首次 11 ms、+9 MB / 200 式；只打包 Latin Modern 一套字体（0.7 MB）。`$$` 块在喂 cmark 前改写成 ```math 围栏，避免块内 `=` 被当 setext 标题；无 `$$` 的文档不做这一步 |
| ADR-14 | **编辑器"淡化 / 高亮当前句"不用 TextKit 2 渲染属性，用置顶透明子视图画** | `setRenderingAttributes` / 临时属性 | 实测：NSTextView 在视口布局时用自己的临时属性覆盖 `setRenderingAttributes`；`removeRenderingAttribute` 对子范围是空操作；TextKit 2 把片段画在子 layer，view 自己 `draw(_:)` 的内容在其下面。透明子视图（zPosition 置顶、hitTest 返回 nil）按 `enumerateTextSegments` 的行段奇偶裁剪盖半透明背景色，精确到句子中段、不改 textStorage、零布局开销 |
| ADR-13 | **TextKit 2 三条硬规矩**：① 整体换内容先清空再 `setAttributedString`；② 视口外片段位置只信 `enumerateTextLayoutFragments(from:options:.ensuresLayout)`，滚动到远处后必须"设视口 → 布局视口 → 重算"收敛；③ 不对整份 textStorage 做属性枚举，附件位置由渲染阶段按块标记 | 直接换内容 / `textLayoutFragment(for:)` / 全文 `enumerateAttribute` | 实测 1 MB：已有布局时直接 `setAttributedString` 4.3 s（TextKit 2 逐段落对账旧元素），清空后再设 10 ms；`textLayoutFragment(for: location)` 对未布局位置返回错误片段（估算几何可互相重叠），主题切换后恢复位置会落到文首；全文 `enumerateAttribute(.attachment)` 13 万 run 要 100 ms/次，原先每次 setRendered / 增量替换 / 改宽都做一遍。见 `ReaderTextView.setRendered / scroll(toBlock:) / forEachLoadableAttachment` |

## 4. 架构分层

```
┌────────────────────────────────────────────────────────────┐
│  QuireApp (executable, AppKit)                              │
│  NSDocument · 窗口/工具栏/侧栏 · 菜单 · 偏好设置 · 编辑器 UI   │
├────────────────────────────────────────────────────────────┤
│  QuireRender (library, AppKit)                              │
│  Block → NSAttributedString · ReaderTextView(TextKit 2)      │
│  TableView 附件 · CodeBlock 背景绘制 · ImageLoader           │
│  MermaidRenderer(离屏 WebKit + 缓存) · ThemeApplier          │
├────────────────────────────────────────────────────────────┤
│  QuireCore (library, Foundation only — 可在 CI 跑测试)        │
│  MarkdownParser(swift-markdown 封装) · Block 模型 · 增量 diff  │
│  Theme 模型 + 加载/校验 · SyntaxHighlighter + Lexers          │
│  Outline(TOC) 提取 · FrontMatter · 大纲/查找索引               │
├────────────────────────────────────────────────────────────┤
│  cmark-gfm (C, GitHub 维护 / Apple fork)  ·  CQuireAttr (ObjC 直通)  ·  SwiftMath │
└────────────────────────────────────────────────────────────┘
```

**依赖方向严格向下。** `QuireCore` 不 import AppKit，这样解析/高亮/主题逻辑能在 Linux CI 或纯命令行基准里跑。

### 目标划分（SwiftPM）

| Target | 类型 | 说明 |
|--------|------|------|
| `QuireCore` | library | 纯逻辑；单元测试覆盖主体 |
| `CQuireAttr` | C/ObjC | 属性字符串 run 追加直通（约 40 行，见 ADR-11） |
| `QuireRender` | library | AppKit 渲染层；快照测试（后期） |
| `Quire` | executable | App 壳 |
| `quire-bench` | executable | 性能基准 CLI（解析/渲染/高亮），CI 中跑 |
| `QuireCoreTests` | test | |
| `QuireRenderTests` | test | |

## 5. 数据流

### 5.1 阅读模式

```
文件 ─read─▶ String ─parse(后台)─▶ Document{blocks:[Block]} ─render─▶ [BlockRender]
                                        │                                │
                                  Outline(TOC)                    NSTextContentStorage
                                                                          │
                                                          ReaderTextView (TextKit 2, viewport lazy layout)
```

- 读文件、解析、生成 attributed string 都在后台队列；只有"把 NSTextStorage 装进 view"在主线程。
- `Document` 是值类型、不可变；每个 `Block` 携带 `sourceRange` 与 `contentHash`。

### 5.2 编辑模式（M3）

```
NSTextView(源码) ─textDidChange─▶ debounce(≈50ms) ─▶ parse(后台) ─▶ diff(old.blocks, new.blocks) by contentHash
                                                                         │
                                                       只对变更块重建 attributed string ─▶ 替换对应 range
```

- 滚动同步：源码行号 ↔ 块 `sourceRange` ↔ 渲染侧 `NSTextRange`，双向映射表在每次 diff 后增量更新。

### 5.3 主题切换

`Theme` 变化 → 不重新解析 → 对已渲染的每个块重新应用属性（`ThemeApplier.reapply(theme:to:)`）→ 一次 `NSTextStorage` 事务。目标 < 50 ms（1 MB 文档）。

## 6. 渲染管线细节

### 6.1 块模型

```swift
enum Block: Hashable {
  case heading(level: Int, inlines: [Inline], id: String)
  case paragraph([Inline])
  case codeBlock(language: String?, code: String)          // ``` 围栏 / 缩进
  case mermaid(source: String)                              // ```mermaid 特化
  case blockQuote([Block])
  case list(ordered: Bool, start: Int, items: [ListItem])   // ListItem 含 checkbox
  case table(Table)                                         // GFM 表格
  case thematicBreak
  case html(String)                                         // 原样显示为代码
  case image(url: String, alt: String, title: String?)      // 独占一行的图片提升为块
  case frontMatter(String)
  case footnoteDefinition(label: String, [Block])
}
```

`Inline`：`text / emphasis / strong / strikethrough / code / link / image / softBreak / lineBreak / footnoteRef / html`。

`Block` 是值类型 + `Hashable`，`contentHash` 缓存在 `RenderedBlock` 中用于 diff。

### 6.2 属性字符串生成

- 每个块 → 一个 `NSAttributedString` 段（以段落分隔符结束）。
- 段落样式全部来自 `Theme.typography`（字号、行高、段距、内容最大宽度）。
- 自定义属性 key（`QuireAttribute.*`）标记块类型、代码语言、链接目标、标题 id，供 TextKit 2 的 fragment 绘制与交互使用。
- 内容宽度：`NSTextContainer` 宽度受 `Theme.layout.maxContentWidth` 约束并居中，超宽内容（表格 / 代码）在附件内水平滚动。

### 6.3 代码块

- 高亮在 `QuireCore.SyntaxHighlighter` 中完成，输出 `[Token(range, kind)]`；渲染层只查主题色。
- 背景圆角块由 `NSTextLayoutFragment` 子类在 `draw(at:in:)` 中绘制（TextKit 2 官方推荐方式），不用附件 → 代码文本可选择、可查找。
- 行号（可选）、语言标签、复制按钮：叠加在 fragment 上的轻量 overlay view，按视口惰性创建。
- 超长代码不换行、水平滚动（用 `lineBreakMode = .byClipping` + 附件内滚动 —— 需要实测决定，见路线图 M2）。

### 6.4 表格

- `TableAttachmentView: NSView`，自绘（CoreText 排版单元格，或每格一个 `NSTextField`——先用 CoreText，省视图数量）。
- 列宽算法：先按内容自然宽度，若总宽 > 可用宽，按比例压缩可换行列；最小列宽 = 最长单词。
- 支持对齐、表头加粗、斑马纹、悬停行高亮、单元格内行内样式（粗体/代码/链接）。
- 通过 `NSTextAttachmentViewProvider` 提供 view；高度在布局前计算并缓存。

### 6.5 图片

- 本地 / 远程；ImageIO 按目标像素宽度 downsample（`kCGImageSourceThumbnailMaxPixelSize`），绝不解码原图到内存。
- `NSCache` 限额（默认 64 MB，主题不可改）；远程图片走 `URLSession` 后台，占位符先撑高，避免布局跳动。
- SVG 由系统 `NSImage` 解码（macOS 11+）。

### 6.6 链接与交互

- 点击链接：`http(s)` 交给系统；`#anchor` 内部跳转；相对路径 `.md` 在同窗口打开；其他文件交 Finder。
- 标题 id 生成规则与 GitHub 一致（小写、去标点、空格→`-`、重名加 `-n`）。

### 6.7 Mermaid（唯一 WebKit 例外）

```
```mermaid 块 ─hash(source + theme.mermaidTheme)─▶ 磁盘缓存命中? ─是─▶ SVG → NSImage → 附件
                                                    │否
                                          MermaidRenderer(单例) ─惰性创建 WKWebView(不可见)─▶ mermaid.render() ─▶ SVG
                                                    │
                                              写缓存 · 30 s 空闲后销毁 WebView
```

- `mermaid.min.js` 不入库，`scripts/fetch_mermaid.sh` 按固定版本 + SHA256 拉取到 `Vendor/mermaid/`，构建时打入 bundle。
- 渲染串行队列；一次 `evaluateJavaScript` 批量渲染同一文档所有图。
- 失败：显示源码 + 错误信息块（不静默）。
- 缓存目录 `~/Library/Caches/com.korako.quire/mermaid/`，LRU 上限 200 MB。

### 6.8 侧栏：文件树 + 大纲

**当前章节高亮的平滑规则（0.7.1）**——目标是"滚动时高亮像在跟着读，而不是抽搐"：

1. **取样只信排好的片段**：`blockIndex(atY:)` 先在视口范围（`viewportRange`）内逐片段找框包含取样点的那一个；`textLayoutFragment(for: point)` 在估算区会给出错误片段（估算高度和实际差几倍），高亮会跳到八竿子打不着的章节。估算片段不包含取样点就返回 nil——"不知道"比"乱答"好，调用方保持上一次的值。
2. **候选章节要稳 80 ms 才提交**：快速 / 惯性滚动时取样点掠过一串标题，每帧都改高亮就是"跳来跳去"；80 ms 后再算一次仍是它才改。实测（60 px/帧下滚 3 s）：高亮改动 89 → 14 次，方向回退 24 → 0。
3. **没有"顶上是标题就以它为准"**：慢滚时 40% 处已经是下一章 B，标题 A 一到顶边又退回 A，A 滚过去再回 B。从侧栏跳到标题的场景改为**锚定**：目标标题还贴着顶边时高亮锚在它上，离开顶边才恢复跟随。
4. **树自己少动**：只在高亮行跑出可视区时滚到刚好露出（不居中）；鼠标在树里时完全不滚——用户正准备点别的。

一棵 `NSOutlineView`：根目录（默认文档所在文件夹）→ 子文件夹 → Markdown 文件 → 标题层级。
- 当前文档的大纲来自完整解析（`Outline`），随每次解析更新；滚动时高亮当前标题（监听 viewport 变化，不用定时器）。
- 其他文件的大纲在展开时后台用 `HeadingScanner`（ATX + setext、跳过围栏/front matter 的单趟扫描）生成，按 mtime 缓存，> 4 MB 不扫。
- 目录内容只在展开时后台列举；整棵树一个 FSEvents 流监听变化，刷新时按 URL 复用节点以保持展开状态。
- 图标为缓存的 SF Symbol（不逐行查 `NSWorkspace` 图标）；行视图复用；单目录最多列 5000 项。

### 6.9 查找

原生 `NSTextFinder`（TextKit 2 支持）；附件内文本（表格）不可查找 —— 已知限制，M4 评估把表格文本镜像成隐藏可查找文本。

## 7. 编辑器设计（M3 / M6）

### M3 源码编辑器
- `NSTextView`（TextKit 2）+ 增量 Markdown 高亮（按段落重高亮，`QuireCore.MarkdownLexer`）。
- 分栏：左源码 / 右预览，可切换 只源码 / 只预览 / 分栏。
- 同步滚动、保存、自动保存（`NSDocument` 原生）、撤销、行号、当前行高亮、软换行。
- 输入辅助：列表续行、代码围栏自动闭合、Tab 缩进、粗体/斜体/链接快捷键、表格格式化。

### M6 行内实时预览（"可视化编辑"，spike 已 go）
- 单栏；光标所在块显示源码，其余块显示渲染结果（Obsidian Live Preview 模式）。`HybridTextView` 继承 `ReaderTextView`：激活块 = 用该块 `sourceRange` 覆盖的原始行替换渲染串里的那段；编辑限制在块内；击键只回写源码，离开块才重解析 + 按 diff 重渲染。
- 复用 M1 渲染器与 M3 高亮器，用同一份 `Document`；不写第二套渲染。
- 表格 / Mermaid / 图片 / 数学等附件块激活后就是 Markdown 源码——不做渲染态的单元格编辑。

### M7 著作归属

文件尾一段 HTML 注释块：

```
<!-- quire-authorship v1 hash=<FNV-1a 64 of body>
{"authors":[{"id":"me","name":"我","color":"#3B82F6"},…],"spans":[["me",19,10],["paste",29,11]]}
-->
```

- 正文不受影响：任何 Markdown 工具都把它当注释；`MarkdownDocument.source` 永远是去掉注释块的正文，渲染 / 导出 / 复制天然看不到它
- 区间按 UTF-16 偏移，与 NSTextView 一致；在 `NSTextStorageDelegate.willProcessEditing`（只看 `.editedCharacters`）处按 `(editedRange, delta)` 增量维护，撤销 / 重做 / 程序插入都经过这里；`setSource` 整体替换不经过（那是磁盘重载，重新 split）
- 哈希对不上（正文被外部改过）：区间整体丢弃、作者表保留、提示一次——错位的归属比没有更糟
- 没有区间就不写注释块：不往干净文件里塞东西

## 7.5 资源 bundle 与打印管线（2026-08 review 后补）

- **资源查找**：SwiftPM 给每个目标生成的 `Bundle.module` 只会在 `Bundle.main.bundleURL/<包>_<目标>.bundle`（.app 根目录，codesign 不允许放东西）和**编译机的绝对 .build 路径**里找，所以 `build_app.sh` 装进 `Contents/Resources` 的 bundle 永远找不到——0.3.0–0.5.8 的发布包在别的机器上第一个 `L("…")` 就 fatalError，本机因为 .build 还在从没发现。现在所有资源都经 `QuireCore.ResourceBundle.locate`（先 `Contents/Resources`，再 bundleURL，最后才 `Bundle.module`），SwiftMath vendored 到 `Vendor/SwiftMath` 打同样的补丁。`scripts/smoke_app.sh` 把 App 拷到别处、用 sandbox 禁止读 .build 再跑一遍"打开 → 渲染公式 → 导出 PDF"，`build_app.sh` 与 CI 都跑。
- **打印 / 导出**：`NSPrintOperation.run()` 是同步的，屏幕视图那套"先占位、异步加载"对它没用。打印视图 `loadsAttachmentsAutomatically = false`，`loadAllAttachmentsForExport()` 等图片（含表格单元格里的）、Mermaid 全部就绪再 `layoutAllForPrinting`；`Exporter.writePDF/writeImage` 是 async，⌘P 经 `MarkdownDocument.print(withSettings:…)` 先异步准备视图再调 super。页眉页脚走 AppKit 自带的 `pageHeader / pageFooter`——自己重写 `drawPageBorder` 改 frame 会触发 TextKit 重排、分页错位。
- **增量渲染的块位置**：`Block` 的相等性不看 `sourceRange`，`render(_:reusing:)` 复用的块必须换成新解析的 `Block`（行号变了），否则混合模式、复制为 Markdown、滚动同步拿旧行号切源码。

### 7.6 滚动稳定与窗口宽度（0.5.10）

- TextKit 2 的文档高度对未排版区域是估算的（1 MB 文档估 307k pt、实际 844k），快速滚动时滚动条随估算修正来回跳。`ReaderTextView.startProgressiveLayout` 在首帧后用主线程空闲分批 `ensureLayout`（每批自适应到 ~12 ms），每批后把 frame 高度推到 `usageBoundsForTextContainer`（NSTextView 只在视口排版时自己长高）。排好的片段很占内存（每 MB 文本 ≈ 330 MB），所以只对 ≤ 200 KB 的文档做；侧栏取样 `blockIndex(atY:)` 只信 `state == .layoutAvailable` 的片段。
- 切模式的窗口宽度（`switchPanes`）：双栏 = 两个正文窗格。窗格用 `.preferResizingSiblingsWithFixedSplitView`（折叠本身不碰窗口），顺序是"先撑窗口 → 先展开再折叠 → 下一轮 run loop 校正宽度并把分栏分到等宽"——同一轮里改窗口会撞上 AppKit 折叠时临时加的约束（内容视图比窗口还宽）；先折叠再展开会让侧栏吃掉腾出的宽度。侧栏 `holdingPriority` 300，宽度变化落在正文窗格上。

## 8. 主题系统

见 [THEMES.md](THEMES.md)。核心约束：

- 主题文件 = JSON；`Theme` 结构体解码 + 校验（缺字段回退到 `base` 主题，非法颜色报错不静默）。
- 内置主题打入 bundle；用户主题在 `~/Library/Application Support/Quire/Themes/*.json`，目录监听热加载。
- 明暗对：主题声明 `appearance: light | dark`，"跟随系统"模式按用户选定的一对切换。

### 8.1 窗口铬（chrome）的颜色规则（0.6.3–0.6.9 收敛）

**一切铬色都从主题背景推导，不用任何系统材质色。** 这样切主题时铬和正文永远同步，不会出现灰带、硬缝或"侧栏压标题"。

| 部件 | 颜色 | 说明 |
|---|---|---|
| 窗口背景（`window.backgroundColor`） | = 主题 `background` | 透明标题栏 / 工具栏区、侧栏浮板外那圈圆角缝露出的都是它 |
| 侧栏浮板 | 主题背景 深色提亮 6% / 浅色压暗 3%，**不透明** | 盖在 `.sidebar` 材质上（材质只借圆角，不借颜色；透窗会把后面的亮窗透进来） |
| 标题栏 / 工具栏 | 透明（`titlebarAppearsTransparent`，无分隔线） | 所以看到的就是窗口背景；图标按钮不带底座，只保留模式分段控件的胶囊 |
| 字数胶囊 | 主题背景 深色提亮 8% / 浅色压暗 4%，alpha 0.9 | 在 `effectiveAppearance` 下解 cgColor |
| 正文 | 从安全区之下开始 | 铬坐在实心主题色上，正文不钻到铬底下 |

时序约束：窗口背景与观察者在 `DocumentWindowController.init` 里就位（状态恢复 / 合并标签出来的窗口不一定走 `showWindow`）；`ThemeManager` 对 `NSApp.effectiveAppearance` 的响应必须**同步**刷新——系统自动切深浅色时窗口先按新外观重画，主题晚一帧就闪旧色。

## 9. 文件监控与重载

- `DispatchSource.makeFileSystemObjectSource`（`.write .rename .delete`）；编辑器保存时用 atomic write 触发 rename，要重新 open fd。
- 重载保留滚动位置（按可见首块的 `contentHash` **就近**定位——文档里可能有内容相同的重复块，不能取第一个匹配）。
- 有未保存改动时磁盘文件被改：不静默覆盖也不静默忽略，弹 sheet 让用户选"重新载入（丢弃改动）/ 保留我的改动"；同一份磁盘内容只问一次。

## 10. 目录结构

```
Quire/
├── Package.swift             # QuireCore · CQuireAttr · QuireRender · Quire · quire-bench（依赖 cmark-gfm pin、Vendor/SwiftMath）
├── Sources/
│   ├── QuireCore/            # Foundation only
│   │   ├── Parser/           #   cmark-gfm 桥接、扩展行内、行内数学、wikilink、内容块
│   │   ├── Model/            #   Block / Outline / 文本统计 / 全文搜索 / 标签 / 著作归属 / 文风规则
│   │   ├── Incremental/      #   块级 diff
│   │   ├── Highlight/        #   Markdown 与代码词法器
│   │   ├── Theme/ Themes/    #   主题模型、加载器；内置主题 JSON（资源）
│   │   ├── Export/           #   HTML 导出、HTML → Markdown
│   │   └── Watch/            #   文件监听
│   ├── CQuireAttr/           # ObjC 直通：批量 append 属性 run（避开 Swift 字典桥接）
│   ├── QuireRender/          # AppKit：AttributedStringBuilder · ReaderTextView / EditorTextView / HybridTextView · 表格 / 数学 / Mermaid 附件 · 渐进排版
│   ├── Quire/                # App 壳：NSDocument · 窗口 · 菜单 · 偏好 · 主题管理 · URL scheme / Intents
│   │   └── Sidebar/          #   侧栏（容器、段视图、文件树 + 大纲、收藏 / 标签、设置）
│   └── quire-bench/          # 基准 CLI（fixture 由 FixtureGenerator 生成）
├── Tests/QuireCoreTests · QuireRenderTests（含本地化键一致性、几何、混合模式）
├── Vendor/SwiftMath/         # vendored（改了资源定位、字体只留 Latin Modern）；Vendor/mermaid/ 构建时拉取
├── Casks/quire.rb            # Homebrew cask（release.sh 更新）
├── assets/                   # Info.plist · 图标 · 权限
├── scripts/                  # build_app.sh · smoke_app.sh · release.sh · bench.sh / bench_gate.sh · bench_launch.sh · appintents_metadata.sh · fetch_mermaid.sh · make_icon.swift
├── docs/                     # 本文档、PERFORMANCE、THEMES、ROADMAP、research/（typora · ia-writer · sidebar）
└── .github/workflows/        # CI：build + test + bench 门禁 + 冒烟
```

## 11. 并发模型

- Swift 6 语言模式，严格并发。
- `MarkdownParser`、`SyntaxHighlighter`、`ThemeStore` 是 `Sendable` 值/actor。
- 渲染管线：`DocumentSession`（actor）持有当前 `Document` 与已渲染块缓存；UI 层通过 `@MainActor` 视图模型订阅。
- 绝不在主线程做解析 / 高亮 / 图片解码。

## 11.5 本地化

- 键 = 中文原文：代码里写 `L("设置…")`（App 层）/ `RL("复制代码")`（QuireRender），源码保持可读；`zh-Hans.lproj` 是恒等映射，`en.lproj` 是译文；找不到键时返回键本身。
- 字符串随各自的 SwiftPM 资源 bundle（`Quire_Quire.bundle` / `Quire_QuireRender.bundle`）；主 bundle 只放空的 `*.lproj/InfoPlist.strings`，让 AppKit 的系统面板 / 标准菜单项跟随同一语言。
- `LocalizationTests` 扫源码：每个 `L()` / `RL()` 键都在两套 .strings 里、两套键集合相等、无未用键、占位符数量一致——加字符串忘了翻译会直接红。
- SwiftUI 里不用 `Text("字面量")` 的隐式查表（它查主 bundle），统一 `Text(L("…"))`。
- 界面语言：默认跟随系统；设置里可覆盖（写 App 域的 `AppleLanguages`，重启生效）。

## 12. 错误与降级策略

- 解析永不失败（cmark 容错）；渲染单块失败 → 该块显示为纯文本 + 日志，不影响其他块。
- 主题加载失败 → 回退默认主题并在偏好设置里显示错误。
- Mermaid 失败 → 显示源码 + 错误。
- 文件 > 8 MB → "大文件模式"：关闭高亮与 Mermaid，只做基础渲染并提示。

## 13. 测试策略

- `QuireCore`：单元测试（解析结构、增量 diff 正确性、高亮 token、主题解码、outline id 规则）；CommonMark spec 抽样。
- `QuireRender`：attributed string 属性断言；后期加位图快照。
- 基准：`quire-bench` 输出 JSON，CI 与 `docs/PERFORMANCE.md` 中的预算比对，超预算即失败。
