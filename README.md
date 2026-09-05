# Quire

<p>
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-black">
  <img alt="swift" src="https://img.shields.io/badge/Swift-6-orange">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue">
  <a href="https://github.com/chaoyi-ai/Quire/actions"><img alt="ci" src="https://github.com/chaoyi-ai/Quire/actions/workflows/ci.yml/badge.svg"></a>
</p>

**高性能、低资源占用的 macOS 原生 Markdown 阅读器 / 编辑器。**
多主题 · 代码高亮 · GFM 表格 · Mermaid · 纯 AppKit + TextKit 2，正文不用 WebView。

> A fast, lightweight, native macOS Markdown reader/editor. Multiple themes, syntax-highlighted code, GFM tables and Mermaid — rendered with AppKit/TextKit 2, no WebView for the document body.

<p align="center">
  <img src="docs/screenshots/reader-light.png" width="800" alt="Quire 阅读模式（GitHub Light）">
  <br>
  <img src="docs/screenshots/split-dark.png" width="800" alt="Quire 分栏编辑（One Dark）">
</p>

## 为什么又一个 Markdown 阅读器？

因为现有的大多数在 WebView 里跑：一个进程起步 100 MB、冷启动半秒、滚动是浏览器的滚动。
Quire 的第一功能是**快和省**，其他功能都在这个前提下做：

| 指标 | 预算 | 0.7 实测（M 系列 / macOS 26） |
|------|------|------|
| 解析 1 MB Markdown | < 60 ms | 47 ms |
| 解析 + 渲染 1 MB Markdown | < 200 ms | 166 ms |
| 编辑回显（1 MB 文档中段修改） | < 16 ms | 1.1 ms |
| 热启动到首帧 | < 400 ms（目标 300） | 350–400 ms |
| 常驻内存（典型文档 / 1 MB 文档） | < 40 / 120 MB | 40 / 90 MB |
| 空闲 CPU | 0% | 0% |
| App 体积（含 Mermaid、数学字体） | < 15 MB | 10 MB |
| 进程数（不含 Mermaid 渲染期间） | 1 | 1 |

完整预算与测量方法见 [docs/PERFORMANCE.md](docs/PERFORMANCE.md)。

## 特性

- **原生渲染**：AppKit + TextKit 2，选择 / 查找 / 打印 / 辅助功能全是系统级
- **完整 Markdown**：CommonMark + GFM（表格、任务列表、删除线、自动链接、脚注）
- **代码高亮**：自研轻量词法器，30+ 语言，无 JS 运行时
- **Mermaid**：唯一使用 WebKit 的地方——惰性、离屏、渲染完销毁、结果缓存
- **多主题**：10 套内置（GitHub / Paper / Solarized / Nord / Dracula / One Dark / Gruvbox），JSON 自定义主题、热切换、跟随系统明暗；窗口铬（标题栏 / 侧栏 / 字数胶囊）颜色全部从主题背景推导，不用系统材质色
- **侧栏**：目录树 → Markdown 文件 → 文件内大纲，一棵树导航整个文件夹（Quire 的特色）；位置栏切换最近根目录，常驻筛选框（打字按名筛树、回车全文搜索），右键新建 / 重命名 / 废纸篓、拖拽移动，收藏与 `#标签` 分组；懒加载、FSEvents 监听、其他文件大纲快速扫描（不做完整解析）
- **阅读器**：外部修改自动刷新（保持滚动位置）、缩放、查找、打印
- **编辑器**：源码编辑 + Markdown 高亮、行号、当前行高亮、列表/围栏/引用续行、⌘B/I/K、⌃⇧` 行内代码、分栏同步滚动、大纲跟随光标、块级增量预览（击键 → 预览 1.1 ms）
- **导出**：HTML（内联主题 CSS）、PDF（按块边界分页、书签、纸张 / 边距 / 页眉页脚可调）、PNG；pandoc 可选
- **写作环境**：混合实时预览（⌘4，块级就地编辑）、专注 / 打字机 / 沉浸模式、悬挂标记、格式工具条、表格辅助、图片 / 富文本粘贴、字数统计
- **文本智能**：词性高亮、文风检查（本地，可自定义规则）
- **组织**：`[[维基链接]]`、`#标签` / 收藏 / 最近分组、内容块 `![[file]]`、快速打开 ⌘P、全局搜索 ⌘⇧F
- **自动化**：`quire://` URL scheme、`quire` 命令行、Apple Shortcuts 动作（见下）
- **本地化**：简体中文 / English

## 快速开始

下载：[Releases](https://github.com/chaoyi-ai/Quire/releases)（`Quire-x.y.z.zip`，ad-hoc 签名；首次打开需右键 → 打开）。

从源码：

```bash
git clone https://github.com/chaoyi-ai/Quire.git && cd Quire
scripts/build_app.sh          # 拉取 mermaid.min.js → swift build -c release → dist/Quire.app（末尾跑隔离冒烟）
open dist/Quire.app
```

开发：

```bash
swift build                    # 编译全部
swift test                     # QuireCore / QuireRender 单元测试
swift run -c release quire-bench all   # 性能基准
open Package.swift             # 用 Xcode 开发
```

要求：macOS 14+，Xcode 16+ / Swift 6。

## 自动化

**URL scheme**（来自其他 App 的请求，目标不在已打开目录内时会先弹确认）：

```
quire://open?path=/abs/file.md&line=12
quire://new?text=…&path=/abs/new.md          # path 可省 = 未命名文档
quire://append?path=/abs/file.md&text=…      # 追加到文件末尾（已打开的文档直接改并保存）
quire://export?path=/abs/file.md&to=/abs/out.pdf   # 或 .html
```

**命令行**（设置 → 安装命令行工具，装到 `/usr/local/bin/quire`）：

```bash
quire README.md                    # 打开文件
quire .                            # 在侧栏打开当前目录
quire open notes.md --line 42
quire new "# 标题" --path ~/notes/new.md
echo "- [ ] 待办" | quire append ~/notes/todo.md -
quire export README.md README.pdf
```

**Shortcuts**：Quire 提供 4 个动作——Open in Quire、New Document in Quire、Append Text to Markdown File、Export Markdown as PDF（返回 PDF 文件，可接后续动作）。在 Shortcuts 的动作列表里搜 "Quire"。

## 文档

| 文档 | 内容 |
|------|------|
| [docs/DESIGN.md](docs/DESIGN.md) | 架构、关键决策（ADR）、渲染管线、模块划分 |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | 性能预算、原则、禁止事项、基准工具 |
| [docs/THEMES.md](docs/THEMES.md) | 主题 JSON 规范、内置主题、自定义主题 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 里程碑 M0–M7 与任务拆分 |
| [docs/research/](docs/research/) | 对标调研：Typora、iA Writer、侧栏设计 |
| [CHANGELOG.md](CHANGELOG.md) | 每个版本改了什么、为什么 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 构建、测试、提交约定 |

## 路线图（摘要）

| 里程碑 | 交付 |
|--------|------|
| ✅ M0 基础设施 | 仓库、文档、SwiftPM 骨架、CI、主题、基准数据 |
| ✅ M1 阅读器 MVP | 原生渲染基础块 + 代码高亮 + 主题 + 目录 + 自动重载 |
| ✅ M2 表格 + Mermaid | 原生表格、Mermaid 离屏渲染 + 缓存 |
| ✅ M3 编辑器 | 源码编辑、分栏同步预览、增量渲染 |
| ✅ M4 性能与打磨 | 基准门禁、启动优化、大文件模式、设置、导出、0.1 发布 |
| ✅ M5 1.0 准备 | 本地化、数学、可访问性、快速打开 / 全局搜索 / 字数 / 剪贴板、沉浸 / Focus、Homebrew cask、更新检查（公证待 Developer ID；Quick Look 扩展被 SwiftPM 打包阻塞） |
| ✅ M6 混合实时预览与就地编辑 | 对标 Typora：spike 验证 → 行内实时预览、表格 / 图片 / 数学就地编辑、扩展语法、CLI（[调研](docs/research/typora.md)） |
| ✅ M7 文本智能与组织 | 对标 iA Writer：词性高亮、文风检查、著作归属、Wikilinks / 标签、内容块、PDF 排版（[调研](docs/research/ia-writer.md)） |

详见 [docs/ROADMAP.md](docs/ROADMAP.md) 与 [GitHub Milestones](https://github.com/chaoyi-ai/Quire/milestones)。

## 架构一瞥

```
Quire (App: NSDocument · 窗口 · 侧栏 · 编辑器 UI)
  └─ QuireRender (AppKit: Block → NSAttributedString · TextKit 2 视图 · 表格附件 · Mermaid · 图片)
       └─ QuireCore (Foundation only: 解析 · 块模型 · 增量 diff · 主题 · 高亮 · 大纲)
            └─ cmark-gfm (C) · CQuireAttr (ObjC 直通，40 行)
```

## 许可证

[MIT](LICENSE)
