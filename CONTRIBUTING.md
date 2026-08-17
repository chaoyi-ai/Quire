# 参与 Quire

## 环境

- macOS 14+，Xcode 16+（Swift 6）
- 无需 Xcode 工程：`open Package.swift` 即可在 Xcode 中开发；或纯命令行。

## 常用命令

```bash
swift build                          # Debug 编译
swift test                           # 单元测试
swift run -c release quire-bench all # 性能基准（JSON）
scripts/build_app.sh                 # 组装 dist/Quire.app（release + ad-hoc 签名）
scripts/fetch_mermaid.sh             # 拉取固定版本 mermaid.min.js（构建 App 前需要一次）
scripts/bench.sh                     # 跑基准并与 docs/PERFORMANCE.md 预算比对
```

## 规矩

1. **先读 [docs/DESIGN.md](docs/DESIGN.md)。** 架构级改动先改文档（加 ADR），再改代码。
2. **性能是功能。** 影响解析 / 渲染 / 启动路径的 PR 附 `quire-bench` 前后数据；退化 > 10% 不合并。
3. **依赖零容忍。** 新增依赖需在 DESIGN.md ADR 表说明为什么自己写不划算。
4. **分层不越界。** `QuireCore` 不 import AppKit；`QuireRender` 不知道窗口/文档。
5. **主线程只装配 UI。** 解析、高亮、图片解码、属性字符串生成都在后台。
6. **测试跟着走。** `QuireCore` 的改动带单元测试；新语言词法器至少一个 token 断言。
7. **主题字段变更**同步更新 [docs/THEMES.md](docs/THEMES.md) 与全部内置主题。

## 提交约定

Conventional Commits：`feat:` `fix:` `perf:` `docs:` `test:` `refactor:` `chore:` `build:` `ci:`
范围可选：`feat(render): table attachment view`。

一个 PR 一件事；PR 描述写清 **动机 / 做法 / 验证**。

## 目录

见 [docs/DESIGN.md §10](docs/DESIGN.md#10-目录结构)。

## 行为准则

友善、直接、就事论事。
