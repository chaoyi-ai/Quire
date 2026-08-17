import Foundation

/// 确定性 Markdown 语料生成器（无随机数：同参数同输出，方便跨机器比对）。
enum FixtureGenerator {
    static let loremZH = ["Quire 的第一功能是快和省。", "原生渲染让选择、查找、打印和辅助功能都是系统级的。", "主题是数据，切换主题不重新解析文档。", "解析永远在后台线程，主线程只负责装配。", "增量渲染按块哈希做 diff，只重建变化的部分。", "Mermaid 是唯一使用 WebKit 的地方，惰性创建、用完销毁。"]
    static let loremEN = ["The quick brown fox jumps over the lazy dog.", "Rendering happens natively with TextKit 2 — no WebView for the body.", "Themes are plain JSON and hot-swappable.", "Parsing runs off the main thread; the main thread only assembles views.", "Large documents stay smooth thanks to viewport-based lazy layout.", "Code blocks are highlighted by a hand-written lexer, no JavaScript runtime."]

    static let codeSwift = """
    import Foundation

    /// 计算文档中所有块的内容哈希
    struct Hasher2 {
        private var state: UInt64 = 0xcbf29ce484222325
        mutating func combine(_ bytes: some Sequence<UInt8>) {
            for b in bytes { state = (state ^ UInt64(b)) &* 0x100000001b3 }
        }
        var value: UInt64 { state }
    }

    func hash(_ blocks: [String]) -> UInt64 {
        var h = Hasher2()
        for (i, b) in blocks.enumerated() where !b.isEmpty {
            h.combine(b.utf8); h.combine([UInt8(i & 0xff)]) // 位置也参与
        }
        return h.value
    }
    """
    static let codeJS = """
    // debounce: 合并高频事件
    export function debounce(fn, wait = 50) {
      let t = null;
      return (...args) => {
        clearTimeout(t);
        t = setTimeout(() => fn(...args), wait);
      };
    }
    const re = /^#{1,6}\\s+(.+)$/gm;
    console.log("headings:", [...src.matchAll(re)].length);
    """
    static let codePy = """
    from dataclasses import dataclass

    @dataclass(frozen=True)
    class Block:
        kind: str
        text: str = ""

        def hash(self) -> int:
            return hash((self.kind, self.text))  # 内容哈希

    blocks = [Block("h1", "Quire"), Block("p", "快 & 省")]
    print(sum(b.hash() for b in blocks) % 1_000_003)
    """
    static let codeBash = """
    #!/bin/bash
    set -euo pipefail
    for f in "$HOME"/notes/*.md; do
      wc -l "$f" | awk '{ print $1 }'   # 行数
    done | sort -n | tail -1
    """
    static let codeJSON = """
    {
      "schema": 1,
      "id": "example",
      "colors": { "accent": "#0969da", "muted": null },
      "sizes": [16, 1.6, -2.5e3],
      "dark": false
    }
    """
    static let mermaidGraph = """
    graph TD
      A[解析] --> B{有变化?}
      B -->|是| C[重建变化块]
      B -->|否| D[跳过]
      C --> E[装配到 TextKit 2]
    """
    static let mermaidSeq = """
    sequenceDiagram
      participant U as 用户
      participant Q as Quire
      U->>Q: 打开 .md
      Q->>Q: 后台解析
      Q-->>U: 首屏 < 300ms
    """

    /// 生成约 `targetBytes` 大小的综合文档，覆盖全部块类型
    static func mixed(targetBytes: Int, seedOffset: Int = 0) -> String {
        var s = "---\ntitle: Benchmark \(targetBytes)\ntags: [bench, quire]\n---\n\n# 基准文档（\(targetBytes / 1024) KB）\n\n"
        var i = seedOffset
        while s.utf8.count < targetBytes {
            let k = i % 23
            switch k {
            case 0: s += "## 第 \(i / 23 + 1) 章：\(loremZH[i % loremZH.count].prefix(8))\n\n"
            case 1, 4, 8, 12, 16, 20:
                s += "\(loremZH[i % loremZH.count]) \(loremEN[(i + 1) % loremEN.count]) **重点** *强调* `code` [链接](https://example.com/\(i)) 见 https://github.com/chaoyi-ai/Quire 。\n\n"
            case 2: s += "### 小节 \(i)\n\n"
            case 3: s += "- 项目一 \(loremEN[i % loremEN.count])\n- 项目二\n  - 嵌套 **粗体**\n  - 嵌套二\n- [x] 完成\n- [ ] 待办\n\n"
            case 5: s += "```swift\n\(codeSwift)\n```\n\n"
            case 6: s += "> \(loremZH[i % loremZH.count])\n> \n> > 嵌套引用 \(loremEN[i % loremEN.count])\n\n"
            case 7: s += "1. 第一步\n2. 第二步 `x`\n3. 第三步\n\n"
            case 9: s += "| 列 A | 列 B | 列 C | 列 D |\n|:-----|:----:|-----:|------|\n| \(i) | **粗** | `码` | \(loremEN[i % loremEN.count].prefix(20)) |\n| a | b | c | d |\n| 长一点的内容 \(loremZH[i % loremZH.count]) | 1.5 | [l](x) | ~~删~~ |\n\n"
            case 10: s += "```javascript\n\(codeJS)\n```\n\n"
            case 11: s += "---\n\n"
            case 13: s += "```python\n\(codePy)\n```\n\n"
            case 14: s += "#### 四级标题 \(i)\n\n"
            case 15: s += "![图 \(i)](https://example.com/img\(i).png \"标题\")\n\n"
            case 17: s += "```bash\n\(codeBash)\n```\n\n"
            case 18: s += "```json\n\(codeJSON)\n```\n\n"
            case 19: s += (i % 46 == 19 ? "```mermaid\n\(mermaidGraph)\n```\n\n" : "```mermaid\n\(mermaidSeq)\n```\n\n")
            case 21: s += "<div align=\"center\">HTML 块 \(i)</div>\n\n"
            default: s += "\(loremEN[i % loremEN.count]) \(loremZH[(i + 2) % loremZH.count])\n\n"
            }
            i += 1
        }
        return s
    }

    static func codeHeavy(targetBytes: Int) -> String {
        var s = "# Code heavy\n\n"
        let langs = [("swift", codeSwift), ("javascript", codeJS), ("python", codePy), ("bash", codeBash), ("json", codeJSON)]
        var i = 0
        while s.utf8.count < targetBytes {
            let (l, c) = langs[i % langs.count]
            s += "段落 \(i)：\(loremEN[i % loremEN.count])\n\n```\(l)\n\(c)\n\(c)\n```\n\n"
            i += 1
        }
        return s
    }

    static func tableHeavy(targetBytes: Int) -> String {
        var s = "# Table heavy\n\n"
        var i = 0
        while s.utf8.count < targetBytes {
            s += "## 表 \(i)\n\n| # | 名称 | 数值 | 说明 | 状态 |\n|--:|:-----|-----:|:-----|:----:|\n"
            for r in 0..<40 {
                s += "| \(r) | 项目 \(r) **重要** | \(Double(r) * 1.25) | \(loremZH[(r + i) % loremZH.count]) | \(r % 2 == 0 ? "✅" : "`待定`") |\n"
            }
            s += "\n"
            i += 1
        }
        return s
    }

    static func mermaidDoc(count: Int) -> String {
        var s = "# Mermaid\n\n"
        for i in 0..<count {
            s += "## 图 \(i + 1)\n\n```mermaid\n\(i % 2 == 0 ? mermaidGraph : mermaidSeq)\n```\n\n"
        }
        return s
    }
}
