# 调研：Kindle 的阅读视图设置，Quire 能吸收什么

> 2026-09-06。对象：Kindle 电子书阅读器（固件 5.12.4+ 的 Aa 菜单）、Kindle iOS / iPadOS App、Kindle for Web。
> 结论先说：Kindle 最值得学的不是某个滑杆，而是**把"版式"从"配色"里拆出来、就地调、可存成预设**这三件事。

## 1. Kindle 有什么

### 1.1 设备端 Aa 菜单（Paperwhite / Oasis / Basic，固件 5.12.4+）

一个面板四个页签，所有调整**在正文上实时预览**（面板只占屏幕下半，上半就是书）。

| 页签 | 项 | 取值 |
|---|---|---|
| 字体 | 字体族 | Bookerly、Amazon Ember、Baskerville、Caecilia、Caecilia Condensed、Futura、Helvetica、OpenDyslexic、Palatino + 用户侧载字体（OTF/TTF 放进 `fonts/` 目录） |
| | 粗细 | 5 级（对任何字体做"合成加粗"，不是只切 Bold 字重） |
| | 字号 | 14 级滑杆 |
| 版式 | 方向 | 竖 / 横 |
| | 边距 | 3 级 |
| | 对齐 | 两端对齐 / 左对齐 |
| | 行距 | 3 级；新固件把"行、段、词、字"四种间距分开调 |
| 主题 | 预设 | 紧凑（小字、小行距）/ 标准 / 大（字号与行距 +25%）/ 低视力（固定 Amazon Ember Bold + 特大字号） |
| | 自定义 | 「存储当前设置」→ 命名；「管理主题」可改名、删除、隐藏默认预设 |
| 更多 | 阅读进度 | 底部左角轮换：位置 / 本章剩余时间 / 全书剩余时间 / 不显示；按**你自己的阅读速度**估算 |
| | 时钟 | 阅读时显示 / 隐藏 |
| | 热门标注、关于本书、Word Wise 提示密度 | 开关 / 滑杆 |

设备级设置（不在 Aa 里）：深色模式（反色）、暖光、翻页刷新频率。

### 1.2 iOS / iPadOS App

- 字体：iPhone 3 种（Bookerly / Amazon Ember / OpenDyslexic），iPad 8 种（多 Baskerville、Caecilia、Georgia、Helvetica、Palatino）
- 字号、粗细、行距 / 段距 / 词距 / 字距、边距、对齐
- **页面色**：白 / 黑 / 褐（Sepia）/ 淡绿；亮度滑杆（App 内，独立于系统）；跟随系统深色模式
- **连续滚动**：竖向滚动代替翻页（默认翻页）
- 主题：同设备端四个预设 + 自定义；iPad 的自定义主题**连亮度一起存**
- 阅读进度同设备端；Page Flip（预览翻页时原位置保持书签）

### 1.3 Kindle for Web

字体（Bookerly / Amazon Ember / OpenDyslexic 等）、字号、行距、边距、页面色（白 / 褐 / 黑）、翻页 / 连续滚动。是 App 的子集。

## 2. Quire 现状对照

| Kindle 项 | Quire 今天 | 差距 |
|---|---|---|
| 字体族 | 设置 → 阅读：正文字体 / 代码字体（系统全部字体族，跟随主题为默认） | 有，但藏在设置窗口里，改一次要开窗口、关窗口 |
| 字号 | 设置里 10 档；⌘+ / ⌘−（`view.zoom`）整体缩放 | zoom 同时放大版面宽度和标题，不是"只改字号" |
| 粗细 | 无 | 主题里 `headingWeight` 固定 |
| 行距 / 段距 | 主题字段 `lineHeight` / `paragraphSpacing`（用户不可调；编辑器有行距 5 档） | 阅读视图不可调 |
| 词距 / 字距 | 无 | 中文场景价值低，不做 |
| 边距 / 行宽 | 主题字段 `maxContentWidth`（760）/ `horizontalPadding`（用户不可调；编辑器有行宽 4 档） | 阅读视图不可调 |
| 对齐 | 固定左对齐 | 中文长段落两端对齐明显更整齐 |
| 页面色 / 深浅 | 10 套主题 + 亮 / 暗 / 跟随系统 | **主题 = 配色 + 版式绑死**：换 Paper 主题会连字体、字号、行宽一起换 |
| 预设 / 自定义主题 | 无（只能选整套主题） | 无法"我这套字体行距，配任何配色" |
| 就地实时预览 | 无 | 设置是 SwiftUI 窗口，改完切回去看 |
| 阅读进度 | 右下角字数胶囊：全文字数 · 阅读时间；侧栏高亮当前章 | 没有"本章剩余"、没有按读者速度校准 |
| 连续滚动 / 翻页 | 只有滚动 | 翻页模式对长文档阅读有价值，但工程量大 |
| 亮度 | 无（系统管） | 不做 |
| 词典 / 翻译 / Word Wise / X-Ray | macOS 三指点按词典（系统自带） | Word Wise / X-Ray 依赖出版社数据，不适用 |
| 侧载字体 | 系统字体全部可选；iA Writer 字体一键下载 | 已胜出 |

## 3. 吸收什么（按价值 / 成本）

### 3.1 把"版式"从主题里拆出来 → **阅读版式（Reading Layout）**  ★★★

Kindle 的心智模型：**配色主题**（白 / 黑 / 褐）与**版式**（字体、字号、粗细、行距、边距、对齐）是两个正交的维度，版式还能存预设。Quire 的主题 JSON 把两者打包，用户要么整套接受，要么进设置窗口逐项覆盖。

方案：新增 `ReadingLayout`（UserDefaults `reader.layout`，JSON）：

```
字体族 · 字号（13–24）· 粗细（常规 / 中 / 半粗，只影响正文）
行距（1.3–2.0）· 段距（0.5–1.5 em）· 行宽（60 / 72 / 80 字符 / 主题默认 / 不限）· 对齐（左 / 两端）
```

- 每一项都可"跟随主题"（现有三项就是这么做的：`RenderOptions.bodyFontFamily / baseFontSize` 为空即跟随）。扩 `RenderOptions` 即可，`RenderStyle.init` 已经是 theme + options 合成，改动集中在一处。
- 主题 JSON 不变，仍是版式默认值的来源；用户主题作者也不用改。
- 与 `view.zoom` 的关系：zoom 保留为"临时放大镜"（⌘+/−，含标题、行宽一起缩放），字号是持久的版式选择。

### 3.2 就地 Aa 面板，实时预览  ★★★

工具栏加「Aa」（`NSMenuToolbarItem` 或 popover），面板里是 3.1 的滑杆 / 分段控件，拖动即渲染。

- 渲染成本：换版式 = 全量重建属性串（`theme/switch` 基准 117 ms / 1 MB，典型文档 < 10 ms），滑杆连续拖动要 **debounce 60–80 ms**，与主题切换共用 `ThemeManager.refresh()` 路径。
- 面板底部一行：预设胶囊（见 3.3）+「存为预设…」。
- 设置窗口里现有的三个 Picker 保留但改成指向同一份 `ReadingLayout`（避免两处真相）。

### 3.3 版式预设  ★★☆

内置：**紧凑**（15 pt / 1.45 / 80 字符）· **标准**（跟随主题）· **舒适**（17 pt / 1.7 / 72 字符）· **大字**（20 pt / 1.8 / 60 字符，正文半粗）。用户可「存储当前设置」为命名预设、改名、删除（UserDefaults 数组）。
预设只含版式，不含配色——这正是 Kindle 的做法（配色在另一层）。

### 3.4 两端对齐 + 中文断行  ★★☆

`NSParagraphStyle.alignment = .justified` 一行的事，但要一起做两件：

- 中文标点挤压 / 行尾禁则 TextKit 2 已处理，但英文两端对齐要配 **连字符断词**（`hyphenationFactor`，macOS 15+ 可用 `NSParagraphStyle.hyphenationFactor` 或 `usesDefaultHyphenation`），否则词距忽大忽小比左对齐更难看。
- 代码块、表格、标题、列表项**不**两端对齐，只对段落与引用。

### 3.5 「本章剩余」阅读进度  ★★☆

字数胶囊已有全文字数与阅读时间（250 字 / 分固定速率）。加：

- 点击胶囊在「全文」与「本章」之间切换（Kindle 的"轮换"）；本章 = 侧栏当前高亮标题到下一同级标题。
- **按读者实际速度校准**：记录滚动位置随时间的推进（阅读视图已有 `topVisibleBlockIndex` 变化通知），滑动平均得到字 / 分，存 `reader.wpm`；无数据时用 250。这是 Kindle 最有辨识度的小功能，成本很低。

### 3.6 正文粗细  ★☆☆

Kindle 对任何字体做 5 级合成加粗，是为 e-ink 低对比度设计的。桌面 Retina 上只需要"常规 / 中 / 半粗"三档，且只对有对应字重的字体生效（`NSFontManager.convertWeight` 或字体描述符 `.traits[.weight]`），没有的就跳过——不做合成描边。

### 3.7 翻页模式  ★☆☆（长期）

连续滚动 → 翻页（空格 / → 翻一屏，页边对齐到行）。对 Markdown 长文有价值，但要做分页布局（打印管线 `computePageRects` 有一半），且与滚动同步 / 侧栏高亮 / 增量渲染都要适配。放长期想法。

## 4. 不做

- **亮度 / 暖光**：系统管，App 内再做一层是 e-ink 与 iPad 的需求。
- **词距 / 字距**：中文正文调这两项几乎无收益，英文调坏字体设计；Kindle 加它是为了 e-ink 拉开笔画。
- **Word Wise / X-Ray / 热门标注**：依赖出版社与社区数据，本地 Markdown 无来源。
- **OpenDyslexic 内置**：OFL 许可可以带，但 5 MB 体积换一个小众需求不划算；用户装到系统里即可在字体列表选到，文档里提一句下载地址。
- **方向**：桌面无意义。

## 5. 建议顺序

1. 3.1 + 3.2（一起做，否则"拆出来"没有入口）：`RenderOptions` 扩字段 → `ReadingLayout` 存储 → Aa popover → 设置窗口三个 Picker 改指向 → 测试（RenderStyle 合成优先级：显式版式 > 主题）。
2. 3.3 预设（在 3.2 面板底部长出来）。
3. 3.5 本章剩余 + 速度校准（独立小项，可先做）。
4. 3.4 两端对齐（放进版式里作为一项）。
5. 3.6 粗细。3.7 进长期想法。

性能门禁：版式变更走与主题切换同一条路径，`theme/switch-large-1mb` 预算 150 ms 不变；滑杆 debounce 后每次提交一次重建。

## 参考

- [Customize Your Kindle E-Reader Text Display — Amazon Customer Service](https://www.amazon.com/gp/help/customer/display.html?nodeId=T5Y94BzSCGwm0vd75W)
- [Accessible Reading Options for Kindle Reading Apps — Amazon Customer Service](https://www.amazon.com/gp/help/customer/display.html?nodeId=TABlJ4ot69emTO8jJG)
- [Customize Kindle for Web — Amazon Customer Service](https://www.amazon.com/gp/help/customer/display.html?nodeId=TT200NNkr2BE4Jnsy9)
- [How to Customize Text on Your Kindle — How-To Geek](https://www.howtogeek.com/734656/how-to-customize-text-on-your-kindle/)
- [The Amazon Kindle font menu system is now live — Good e-Reader](https://goodereader.com/blog/kindle/the-amazon-kindle-font-menu-system-is-now-live)
- [Kindle app for iPad lets you finally create your own themes — Ebook Friendly](https://ebookfriendly.com/kindle-app-ipad-custom-themes/)
- [How to customize reading options in Kindle for iPhone and iPad — iMore](https://www.imore.com/how-customize-reading-options-kindle-app-ios)
- [Do You Like the New Themes Option on Your Kindle? — The eBook Reader](https://blog.the-ebook-reader.com/2019/01/22/do-you-like-the-new-themes-option-on-your-kindle/)
- [5 Hidden Kindle Features — SlashGear](https://www.slashgear.com/2020365/hidden-kindle-features-you-probably-do-not-know-about/)
