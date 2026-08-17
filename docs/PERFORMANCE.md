# Quire 性能预算与原则

> "性能"和"资源"是 Quire 的第一功能，不是优化项。任何 PR 若使下表指标退化超过 10%，CI 应当拒绝。

## 1. 预算（硬指标）

在 Apple Silicon 基准机（M1 及以上，macOS 14+）上测量：

| 指标 | 预算 | 测量方式 |
|------|------|----------|
| 冷启动到首屏（打开一个 20 KB 文档） | **< 300 ms** | `scripts/bench.sh launch`：从 `open` 到窗口首帧（`os_signpost`） |
| 热启动到首屏 | < 150 ms | 同上，第二次 |
| 解析 1 MB Markdown（`Tests/Fixtures/large-1mb.md`） | **< 60 ms** | `quire-bench parse` |
| 渲染 1 MB 文档为 attributed string（不含布局） | **< 140 ms** | `quire-bench render` |
| 解析 + 渲染合计 | **< 200 ms** | `quire-bench full` |
| 主题热切换（1 MB 文档，不重解析、全量重建属性） | < 150 ms | `quire-bench theme` |
| 编辑回显（击键 → 预览更新，1 MB 文档中段修改一段） | **< 16 ms** 增量路径 | `quire-bench incremental` |
| 代码高亮吞吐 | > 20 MB/s | `quire-bench highlight` |
| 滚动 | 60 fps，无掉帧 | Instruments Animation Hitches |
| 常驻内存（典型 50 KB 文档，打开 1 窗口） | **< 40 MB** | `footprint` / Activity Monitor "内存" |
| 常驻内存（1 MB 文档） | < 120 MB | 同上 |
| 空闲 CPU | **0.0%** | Activity Monitor 采样 60 s |
| App 体积（不含 mermaid） | < 10 MB | `du -sh Quire.app` |
| App 体积（含 mermaid） | < 15 MB | 同上 |
| 无 Mermaid 文档打开时的进程数 | 1 | `pgrep -f Quire` |

## 2. 原则

1. **主线程只做 UI 装配。** 读文件、解析、高亮、生成属性字符串、解码图片全部后台。
2. **不做无用功。** 增量渲染（块哈希 diff）；视口外不布局（TextKit 2 lazy layout）；视口外不解码图片；不可见的 overlay 不创建。
3. **零空闲开销。** 不用 `Timer` 轮询；文件监控用 `DispatchSource`；主题目录监听同理；Mermaid WebView 用完销毁。
4. **内存有上限。** 图片缓存 `NSCache` 64 MB；Mermaid 磁盘缓存 200 MB LRU；渲染块缓存只保留当前文档。
5. **进程数 = 1。** 除 Mermaid 渲染期间的 WebKit 辅助进程外，不启动任何子进程 / XPC。
6. **依赖最小化。** 运行时依赖只有 cmark-gfm。每加一个依赖需要在 DESIGN.md ADR 中说明。
7. **测量而非猜测。** 每个性能相关 PR 附 `quire-bench` 前后对比。

## 3. 禁止事项

- 禁止用 WKWebView 渲染 Markdown 正文。
- 禁止在主线程解析或高亮。
- 禁止在文档打开路径上做同步网络请求。
- 禁止用 SwiftUI 承载正文渲染（偏好设置窗口等低频 UI 可以）。
- 禁止全量重渲染响应击键。
- 禁止把 highlight.js / prism 之类跑在 JavaScriptCore 里做高亮。
- 禁止在已构建的 NSMutableAttributedString 范围上回头 `addAttribute(range:)`（O(runs) 字典合并）；run 属性在创建时一次写全，走 `CQuireAttr`。

## 2.1 当前基线（Apple M-series，2026-08，`quire-bench all`）

| 指标 | 结果 | 预算 |
|------|------|------|
| parse/large-1mb | 42 ms | 60 |
| render/large-1mb | 110 ms | 140 |
| full/large-1mb | 160 ms | 200 |
| theme/switch-large-1mb | 114 ms | 150 |
| incremental/edit-middle-1mb | 1.4 ms | 16 |
| highlight/swift | 61 MB/s | > 20 |

历史：swift-markdown 封装时 parse 136 ms；纯 Swift 属性字符串构建时 render 527 ms。

## 4. 测量工具

```bash
swift run -c release quire-bench all           # 输出 JSON 到 stdout
scripts/bench.sh                                # 跑全部并与 docs/PERFORMANCE.md 预算比对
scripts/bench.sh launch                         # 冷/热启动
```

Instruments 模板：`Time Profiler`、`Allocations`、`Animation Hitches`；关键路径打了 `os_signpost`（子系统 `com.korako.quire`，类别 `perf`）。

## 5. 基准数据集

`Tests/Fixtures/`：

| 文件 | 说明 |
|------|------|
| `small.md` | 20 KB，典型 README |
| `medium.md` | 200 KB，含 30 段代码、10 张表 |
| `large-1mb.md` | 1 MB，由脚本生成，覆盖全部块类型 |
| `code-heavy.md` | 500 KB，90% 代码块 |
| `table-heavy.md` | 200 KB，大表格 |
| `mermaid.md` | 20 张 mermaid 图 |
| `commonmark-spec.md` | CommonMark spec 全文（0.31） |

## 6. 已知取舍

- 原生渲染 + 附件表格意味着表格文本暂不参与全文查找（M4 评估修复）。
- 首次渲染 Mermaid 需要启动 WebKit（约 200–400 ms、+60 MB 瞬时），之后缓存命中免费。
