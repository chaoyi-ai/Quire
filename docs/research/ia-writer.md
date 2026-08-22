# iA Writer 调研（2026-08，iA Writer 7.x for Mac）

> 目的：为 M7 定方向。iA Writer（ia.net/writer，$49.99 买断，原生 Mac/iOS/Windows，四次 App of the Year，ADA 2025 入围）是"专注写作"这条路线的标杆——和 Typora 的"所见即所得"正好是 Markdown 编辑器的另一极。
> 方法：浏览 ia.net/writer 首页（逐张看功能图）、support 全部章节（Basics / Library / Editor / Preview）、Features 平台对照表、字体仓库 iaolo/iA-Fonts。
> 结论先行：**iA Writer 的护城河不是 Markdown 功能，而是"写作环境"（排版、专注、无 chrome）和"文本智能"（词性高亮、文风检查、著作归属），全部本地、无 AI、不改文本。这些在 TextKit 2 上几乎都能原生做，且与 Quire"原生、省资源、不上云"的定位天然一致。M7 = 写作环境与文本智能；不做它的 Library/云/博客发布那一半。**

## 1. 观察到的产品细节（从官方演示图逐张看）

| 场景 | iA Writer 的做法 | 对 Quire 的启发 |
|---|---|---|
| 首页第一屏 | 一个无标题栏、无按钮的白框，等宽字体，蓝色光标；上一段淡灰、当前段纯黑——这就是 Focus Mode 的**段落**档 | 沉浸写作 = 去 chrome + 淡化非当前段落 + 高对比光标。Quire 的编辑器目前有工具栏 / 标签栏 / 行号栏，需要一个"隐藏一切"的模式 |
| 编辑器排版 | `#` / `##` **出挑到左边距**（hanging markers），正文左缘齐；`*drowsy*` 真斜体显示；只用自家三款字体 Mono / Duo / Quattro（IBM Plex 衍生，开源 iaolo/iA-Fonts） | 源码模式的"标记出挑"是辨识度最高的细节（Gruber 专门点名）。字体可选随包附带（开源、需署名） |
| Focus Mode | 三档：**句子** / 段落 / 打字机；⌘D；全屏深色下效果最好；文档明说"编辑阶段建议关掉，否则屏幕会跳" | 句级淡化需要句子切分（NaturalLanguage 的 NLTokenizer 句子单元）；打字机模式与选区编辑冲突要处理 |
| Syntax Highlight | 词性着色：名词 / 动词 / 形容词 / 副词 / 连词 各一色，像代码编辑器一样"看结构"；支持 En De Fr It Es Ru；可单独只开一类（"只看动词"） | macOS 的 NLTagger `.lexicalClass` 就是干这个的，本地、零依赖；中文词性需评估 |
| Style Check | 划掉填充词（basically）、冗余（combine together）、陈词滥调（against all odds）；**只在编辑器显示，不入预览 / 导出，不删字，不联网，无 AI**；自定义规则文件（字面 / 例外 `-` / 有限正则 `/…/`，正则子集明确列出哪些不支持"以免拖慢编辑"） | 一个规则引擎 + 内置词表 + 用户规则文件就能做；中文要自己建词表；正则子集的取舍值得照抄思路 |
| Authorship | 记录**你打的 vs 粘贴的**：自己的字黑白、AI 彩色渐变、引用淡化；可"标记选区为某作者"、"以某作者身份粘贴"；元数据存在**文件尾部**（其他编辑器可见），导出时剥离；文件图标带 Ⓐ | 2026 年的差异化功能，实现不难：记录 typed/pasted 区间 + 作者表，存文件尾注释块；难点是增量维护区间 |
| Stats | 字 / 词 / 句 / 阅读时间；选区统计；Windows 版有写作目标 | 与 M6 #65 合并，M7 补句子数与写作目标 |
| Library | 左栏 Organizer：Locations / Favorites / Smart Folders（按搜索式、路径、日期的动态文件夹，默认 Recents）/ Hashtags（`#tag` 自动索引）；中栏文件列表带摘要与日期；搜索有一套查询语法（`name:` / `#tag` / `[ ]` 未完成任务 / NEAR / AND OR NOT） | Quire 侧栏是目录树 + 大纲；可补 `#标签`、收藏、最近；Smart Folders 价值一般 |
| Wikilinks | `[[名字]]` 自动补全、`[[目标 \| 显示名]]`、就近解析（同目录 > 子目录 > 父目录）、⌘↩ 跳转、前进 / 后退历史；**导出时变成纯文本**（"隐藏的连接"） | 与侧栏目录缓存天然结合；就近解析规则直接照抄 |
| Content Blocks | 单独一行写 `Section.txt "标题"` / `Balance.csv` / `images/x.jpg (说明)` 即嵌入（transclusion）；`/` 触发补全；用于**把多章拼成一本书**；CSV 渲染成表格 | Quire 做成"包含块"：渲染时展开，导出时内联；不占用标准语法（iA 也是非标） |
| Templates | 预览 / PDF 模板：Modern（Sans）/ Classic（Serif）/ Manuscript（Mono / Duo / Quattro）/ GitHub；模板 = HTML+CSS 包，可自定义；文档内 `<style>@media print` 覆盖 | Quire 主题已经是"阅读模板"；缺的是**打印 / PDF 排版参数**（页边距、页眉页脚页码、标题编号） |
| Smart Automation | 智能引号 / 破折号（编辑器内替换 vs 仅预览替换两种）、列表续行、表格公式 `=(B1+B3)`、单位换算 | 列表续行已有；SmartyPants 在 M6；表格公式不做 |
| 其他 | docx 原生导入导出；博客发布（Ghost / Medium / WordPress / Micropub）；`ia-writer://` URL 命令；Apple Shortcuts | docx 走 M6 的 pandoc 可选；博客发布不做；URL scheme + Shortcuts 便宜可做 |

## 2. 功能清单对照

✅ 已有 · 🟡 部分 · ❌ 没有 · ➖ 不做

| 分类 | iA Writer | Quire 现状 | 归属 |
|---|---|---|---|
| 环境 | 无 chrome 沉浸写作（无标题栏 / 按钮） | ❌ | M7 |
| 环境 | 源码模式标记出挑（hanging `#` / `-` / `>`） | ❌ | M7 |
| 环境 | 自家字体 Mono / Duo / Quattro | ❌（M5 有字体覆盖） | M7（可选附带） |
| 环境 | Focus：句子 / 段落 / 打字机 | ❌ | M7（从 M6 移来，扩到句级） |
| 智能 | 词性高亮（6 语） | ❌ | M7 |
| 智能 | 文风检查 + 自定义规则 | ❌ | M7 |
| 智能 | 著作归属（人 / AI / 引用） | ❌ | M7 |
| 智能 | 统计（字词句、阅读时间、选区、目标） | ❌ | M6 #65 基础 · M7 句数 / 目标 |
| 智能 | 拼写 / 语法（系统） | ✅ | — |
| 组织 | `[[wikilink]]` 补全 / 就近解析 / 历史 | ❌ | M7 |
| 组织 | `#hashtag` 索引 | ❌ | M7 |
| 组织 | 收藏 / 最近 / Smart Folders | ❌ | M7 收藏 + 最近；Smart Folders 不做 |
| 组织 | 内容块（transclusion，CSV → 表格） | ❌ | M7 |
| 组织 | 全局搜索 + 查询语法 | ❌ | M6 #63（语法子集） |
| 组织 | 云 Library（iCloud / Dropbox …） | ➖（目录即库） | — |
| 预览 | 模板（Sans / Serif / Manuscript / GitHub） | ✅（10 套 JSON 主题） | — |
| 预览 | 数学 | ❌ | M5 |
| 导出 | PDF 排版参数（页边距 / 页眉页脚 / 编号） | 🟡 固定边距 | M7 |
| 导出 | docx 原生 | ❌ | M6 pandoc 可选 |
| 导出 | 博客发布 | ➖ | — |
| 集成 | URL 命令、Apple Shortcuts | ❌ | M7 |
| 自动化 | 智能引号 / 破折号 | ❌ | M6 SmartyPants |
| 自动化 | 表格公式 / 元数据变量 | ➖ | — |

## 3. 不照搬的地方

- **不做云 Library / 账号 / 博客发布**（DESIGN §1：不做云同步 / 账号）。目录就是库。
- **不做 docx 原生导入导出**：M6 的 pandoc 可选集成覆盖。
- **不做表格公式、元数据变量**：与"默认 GFM"冲突，用的人少。
- **文本智能全部本地、不改文本、不入导出**——这一条照抄 iA 的原则，而且是 Quire 的优势：NaturalLanguage 框架本机就有，零依赖零网络。
- **中文优先**：iA 的词性高亮 / 文风检查不支持中文；Quire 要先验证 NLTagger 对中文词性的可用性，文风词表自建。

## 4. 给 M7 的优先级

1. 沉浸写作环境 + Focus 三档 + 标记出挑——iA 的"手感"核心，成本低。
2. 词性高亮、文风检查——差异化且本地；先英文，中文视 NLTagger 评估结果。
3. Wikilinks + `#标签` + 收藏 / 最近——把 Quire 从"打开文件"变成"写笔记"。
4. 著作归属——2026 年独特卖点，格式要稳定（文件尾注释块，导出剥离）。
5. 内容块、PDF 排版参数、URL scheme / Shortcuts——外围。
