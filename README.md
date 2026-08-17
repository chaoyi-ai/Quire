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

## 为什么又一个 Markdown 阅读器？

因为现有的大多数在 WebView 里跑：一个进程起步 100 MB、冷启动半秒、滚动是浏览器的滚动。
Quire 的第一功能是**快和省**，其他功能都在这个前提下做：

| 指标 | 预算 |
|------|------|
| 冷启动到首屏 | < 300 ms |
| 解析 + 渲染 1 MB Markdown | < 200 ms |
| 常驻内存（典型文档） | < 40 MB |
| 空闲 CPU | 0% |
| 进程数（不含 Mermaid） | 1 |

完整预算与测量方法见 [docs/PERFORMANCE.md](docs/PERFORMANCE.md)。

## 特性

- **原生渲染**：AppKit + TextKit 2，选择 / 查找 / 打印 / 辅助功能全是系统级
- **完整 Markdown**：CommonMark + GFM（表格、任务列表、删除线、自动链接、脚注）
- **代码高亮**：自研轻量词法器，30+ 语言，无 JS 运行时
- **Mermaid**：唯一使用 WebKit 的地方——惰性、离屏、渲染完销毁、结果缓存
- **多主题**：10 套内置（GitHub / Paper / Solarized / Nord / Dracula / One Dark / Gruvbox），JSON 自定义主题、热切换、跟随系统明暗
- **阅读器**：目录侧栏、外部修改自动刷新（保持滚动位置）、缩放、查找
- **编辑器**（M3）：源码编辑 + 语法高亮、分栏同步预览、块级增量渲染
- **可视化编辑**（M5）：行内实时预览

## 快速开始

```bash
git clone https://github.com/chaoyi-ai/Quire.git && cd Quire
scripts/build_app.sh          # swift build -c release → dist/Quire.app
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

## 文档

| 文档 | 内容 |
|------|------|
| [docs/DESIGN.md](docs/DESIGN.md) | 架构、关键决策（ADR）、渲染管线、模块划分 |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | 性能预算、原则、禁止事项、基准工具 |
| [docs/THEMES.md](docs/THEMES.md) | 主题 JSON 规范、内置主题、自定义主题 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 里程碑 M0–M5 与任务拆分 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 构建、测试、提交约定 |

## 路线图（摘要）

| 里程碑 | 交付 |
|--------|------|
| M0 基础设施 | 仓库、文档、SwiftPM 骨架、CI、主题、基准数据 |
| M1 阅读器 MVP | 原生渲染基础块 + 代码高亮 + 主题 + 目录 + 自动重载 |
| M2 表格 + Mermaid | 原生表格视图、Mermaid 离屏渲染 + 缓存 |
| M3 编辑器 | 源码编辑、分栏同步预览、增量渲染 |
| M4 性能与打磨 | 基准门禁、大文件模式、导出、0.1 发布 |
| M5 可视化编辑 | 行内实时预览、数学、本地化、1.0 |

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
