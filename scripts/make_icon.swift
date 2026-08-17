// 生成 App 图标：圆角方块 + 渐变 + 衬线 "Q" + 三条"文本行"，输出 AppIcon.iconset
// 用法: swift scripts/make_icon.swift assets/AppIcon.iconset
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // macOS 图标安全区：约 82%
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 阴影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // 渐变背景：暖纸色 → 米白（Quire = 一叠纸）
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [CGColor(red: 0.98, green: 0.96, blue: 0.91, alpha: 1), CGColor(red: 0.93, green: 0.89, blue: 0.80, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // 三条"文本行"（右下），表示 Markdown 内容
    let lineColor = CGColor(red: 0.62, green: 0.55, blue: 0.45, alpha: 0.55)
    ctx.setFillColor(lineColor)
    let lh = rect.height * 0.045
    let lx = rect.minX + rect.width * 0.50
    let widths: [CGFloat] = [0.36, 0.28, 0.32]
    for (i, w) in widths.enumerated() {
        let y = rect.minY + rect.height * (0.20 + CGFloat(i) * 0.09)
        let r = CGRect(x: lx, y: y, width: rect.width * w, height: lh)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: lh / 2, cornerHeight: lh / 2, transform: nil)); ctx.fillPath()
    }
    ctx.restoreGState()

    // 衬线 Q（深墨色）
    let fontSize = rect.height * 0.62
    let font = CTFontCreateWithName("Charter-Bold" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 0.16, green: 0.14, blue: 0.13, alpha: 1)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Q", attributes: attrs as [NSAttributedString.Key: Any]))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let tx = rect.minX + rect.width * 0.14 - bounds.minX
    let ty = rect.minY + rect.height * 0.30 - bounds.minY
    ctx.textPosition = CGPoint(x: tx, y: ty)
    CTLineDraw(line, ctx)

    // 强调色小点（Q 的尾巴旁），呼应 accent
    ctx.setFillColor(CGColor(red: 0.60, green: 0.36, blue: 0.17, alpha: 1))
    let dot = rect.width * 0.06
    ctx.fillEllipse(in: CGRect(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.62, width: dot, height: dot))

    return ctx.makeImage()!
}

func write(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    write(render(size: px), to: "\(outPath)/\(name).png")
}
print("✓ \(outPath)")
