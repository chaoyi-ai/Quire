# Changelog

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
