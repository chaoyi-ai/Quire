# Quire 主题规范（schema v1）

主题是**纯数据**（JSON），描述阅读视图 / 编辑器 / 代码高亮 / Mermaid 的颜色、字体和版式。
切换主题不重新解析文档，只重建属性。

## 1. 文件位置

| 类型 | 位置 |
|------|------|
| 内置主题 | 随 App 打包（源码在仓库 `Sources/QuireCore/Themes/*.json`，经 `ResourceBundle.locate` 定位） |
| 用户主题 | `~/Library/Application Support/Quire/Themes/*.json`，目录监听热加载 |

文件名任意，主题 `id` 必须唯一；同 id 时用户主题覆盖内置主题。

## 2. 内置主题清单

| id | 名称 | 明/暗 |
|----|------|-------|
| `github-light` | GitHub Light | light（默认亮色） |
| `github-dark` | GitHub Dark | dark（默认暗色） |
| `paper` | Paper（米色纸张，衬线） | light |
| `solarized-light` | Solarized Light | light |
| `solarized-dark` | Solarized Dark | dark |
| `nord` | Nord | dark |
| `dracula` | Dracula | dark |
| `one-dark` | One Dark | dark |
| `gruvbox-light` | Gruvbox Light | light |
| `gruvbox-dark` | Gruvbox Dark | dark |

外观模式：`亮 / 暗 / 跟随系统`。跟随系统时使用用户分别指定的亮色主题与暗色主题。

**版式覆盖（0.8+）**：主题的 `typography`（字体、baseSize、lineHeight、paragraphSpacing）与 `layout.maxContentWidth` 是**默认值**；用户在工具栏「Aa」/ 设置 → 阅读版式 里设的显式值会覆盖它们（每项可单独"跟随主题"）。主题作者不需要为此改任何东西。

## 3. 文件格式

```jsonc
{
  "schema": 1,
  "id": "github-light",              // 必填，[a-z0-9-]+
  "name": "GitHub Light",            // 必填，显示名
  "appearance": "light",             // 必填，"light" | "dark"
  "author": "Quire",                 // 可选
  "extends": "github-light",         // 可选：继承另一主题，未声明字段沿用父主题（仅一层）

  "colors": {
    "background": "#ffffff",
    "foreground": "#1f2328",
    "muted": "#656d76",              // 次要文字：脚注、图片说明、front matter
    "accent": "#0969da",             // 链接、任务勾选、当前目录项
    "heading": "#1f2328",
    "border": "#d0d7de",             // 分割线、表格边框、标题下划线
    "selection": "#0969da33",        // 支持 8 位 #RRGGBBAA
    "blockquote": { "foreground": "#656d76", "border": "#d0d7de", "background": "#00000000" },
    "code": {
      "background": "#f6f8fa",       // 代码块底色
      "foreground": "#1f2328",
      "inlineBackground": "#afb8c133",
      "inlineForeground": "#1f2328",
      "border": "#00000000",
      "lineNumber": "#8c959f"
    },
    "table": {
      "headerBackground": "#f6f8fa",
      "stripe": "#f6f8fa",           // 偶数行底色
      "border": "#d0d7de",
      "hover": "#0969da0f"     // 预留：表格在片段里静态绘制，目前没有悬停态；写了也不会有效果
    },
    "syntax": {                      // 代码高亮 token 颜色；缺失的 token 回退 foreground
      "keyword": "#cf222e",
      "string": "#0a3069",
      "comment": "#6e7781",
      "number": "#0550ae",
      "type": "#953800",
      "function": "#8250df",
      "variable": "#1f2328",
      "constant": "#0550ae",
      "operator": "#0550ae",
      "punctuation": "#1f2328",
      "attribute": "#0550ae",        // HTML/XML 属性、装饰器
      "tag": "#116329",              // HTML 标签、Markdown 标题标记
      "meta": "#6e7781",             // 预处理指令、shebang
      "regexp": "#0a3069",
      "escape": "#0a3069",
      "invalid": "#82071e"
    },
    "editor": {                      // 源码编辑器（M3）；缺失则从上面推导
      "currentLine": "#0969da0a",
      "gutter": "#8c959f",
      "markdownMarker": "#8c959f",   // `#`、`*`、`>` 等标记
      "markdownHeading": "#0550ae",
      "markdownLink": "#0969da",
      "markdownCode": "#0a3069"
    }
  },

  "typography": {
    "bodyFont": ["system"],          // 家族名列表，取第一个可用；"system" = 系统 UI 字体，"system-serif" = New York，"system-rounded"
    "codeFont": ["SF Mono", "Menlo", "system-mono"],
    "baseSize": 16,                  // pt
    "lineHeight": 1.6,               // 倍数
    "paragraphSpacing": 1.0,         // em
    "headingScale": [2.0, 1.5, 1.25, 1.0, 0.875, 0.85],
    "headingWeight": "semibold",     // regular | medium | semibold | bold | heavy
    "headingSpacingBefore": 1.5,     // em
    "codeSize": 0.875                // 相对 baseSize
  },

  "layout": {
    "maxContentWidth": 760,          // pt；0 = 不限
    "horizontalPadding": 32,
    "verticalPadding": 40,
    "codeBlockRadius": 6,
    "codeBlockPadding": 12,
    "blockquoteBarWidth": 3,
    "tableCellPadding": [6, 12]      // [垂直, 水平]
  },

  "mermaid": {
    "theme": "default"               // default | dark | neutral | forest | base
  }
}
```

### 校验规则

- `schema` 必须为 1；`id`、`name`、`appearance` 必填。
- 颜色：`#RGB` / `#RRGGBB` / `#RRGGBBAA`；非法值 → 该主题加载失败并在偏好设置里显示错误（不静默回退）。
- `extends` 只允许一层；循环引用报错。
- 缺失的可选字段：`extends` 存在时取父主题，否则取同 `appearance` 的默认主题（`github-light` / `github-dark`）。
- 字体：列表内没有一个可用时回退 `system` / `system-mono`。

## 4. 主题与渲染的对应关系

| 元素 | 使用的字段 |
|------|-----------|
| 正文 | `foreground` `background` `bodyFont` `baseSize` `lineHeight` `paragraphSpacing` |
| 标题 h1–h6 | `heading` `headingScale[n]` `headingWeight` `headingSpacingBefore`；h1/h2 底部线 `border` |
| 链接 | `accent`，下划线可在偏好设置关闭 |
| 行内代码 | `code.inlineBackground` `code.inlineForeground` `codeFont` `codeSize` |
| 代码块 | `code.*` `syntax.*` `codeBlockRadius` `codeBlockPadding` |
| 引用 | `blockquote.*` `blockquoteBarWidth` |
| 表格 | `table.*` `tableCellPadding` `border` |
| 分割线 | `border` |
| 任务列表 | `accent`（勾选）`muted`（未勾选） |
| 脚注 / 图片标题 | `muted` |
| Mermaid | `mermaid.theme` + `background`（画布透明叠在正文底色上） |

## 5. 编写自定义主题

最省事的方式：`extends` 一个内置主题，只覆盖颜色。

```json
{
  "schema": 1,
  "id": "my-warm-dark",
  "name": "My Warm Dark",
  "appearance": "dark",
  "extends": "one-dark",
  "colors": { "background": "#1c1917", "accent": "#f59e0b" }
}
```

放到 `~/Library/Application Support/Quire/Themes/` 即可在 `视图 → 主题` 菜单里看到；文件改动实时生效。
