# 参与 Quire

## 环境

- macOS 14+，Xcode 16+（Swift 6）
- 无需 Xcode 工程：`open Package.swift` 即可在 Xcode 中开发；或纯命令行。

## 常用命令

```bash
swift build                          # Debug 编译
swift test                           # 单元测试
swift run -c release quire-bench all # 性能基准（JSON）
scripts/build_app.sh                 # 组装 dist/Quire.app（release + ad-hoc 签名 + App Intents 元数据 + 冒烟）
scripts/smoke_app.sh dist/Quire.app  # 隔离 .build 目录启动 App 并导出 PDF：发布包能在别的机器上跑的唯一证据
scripts/fetch_mermaid.sh             # 拉取固定版本 mermaid.min.js（构建 App 前需要一次）
scripts/bench.sh [leniency]          # 跑基准并与 scripts/bench_gate.sh 里的预算比对（参数是宽松系数，不是次数）
scripts/release.sh <ver>             # 查 HEAD 的 CI → test → bench → build → smoke → zip → Cask → tag → GitHub Release
```

## 规矩

1. **先读 [docs/DESIGN.md](docs/DESIGN.md)。** 架构级改动先改文档（加 ADR），再改代码。
2. **性能是功能。** 影响解析 / 渲染 / 启动路径的 PR 附 `quire-bench` 前后数据；退化 > 10% 不合并。
3. **依赖零容忍。** 新增依赖需在 DESIGN.md ADR 表说明为什么自己写不划算。
4. **分层不越界。** `QuireCore` 不 import AppKit；`QuireRender` 不知道窗口/文档。
5. **主线程只装配 UI。** 解析、高亮、图片解码、属性字符串生成都在后台。
6. **测试跟着走。** `QuireCore` 的改动带单元测试；新语言词法器至少一个 token 断言。
7. **主题字段变更**同步更新 [docs/THEMES.md](docs/THEMES.md) 与全部内置主题。
8. **资源一律经 `QuireCore.ResourceBundle.locate`**，不要直接用 `Bundle.module`（SwiftPM 的 accessor 只认编译机的 .build 路径；0.3.0–0.5.8 的发布包因此在别的机器上一启动就崩）。发布前必过 `smoke_app.sh`。
9. **界面字符串走 `L()` / `RL()`**，键 = 中文原文，两套 `Localizable.strings` 都要加；`LocalizationTests` 会因缺键或多余键失败。
10. **TextKit 2 三条硬规矩**见 DESIGN.md ADR-13：已有布局的视图先清空再 `setAttributedString`；定位用 `enumerateTextLayoutFragments(.ensuresLayout)` 而不是 `textLayoutFragment(for:)`；淡化 / 高亮不用渲染属性。

## 提交约定

Conventional Commits：`feat:` `fix:` `perf:` `docs:` `test:` `refactor:` `chore:` `build:` `ci:`
范围可选：`feat(render): table attachment view`。

一个 PR 一件事；PR 描述写清 **动机 / 做法 / 验证**。

## 目录

见 [docs/DESIGN.md §10](docs/DESIGN.md#10-目录结构)。

## 行为准则

友善、直接、就事论事。
