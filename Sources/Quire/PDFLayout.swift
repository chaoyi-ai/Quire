import AppKit
import SwiftUI
import QuireRender

/// PDF / 打印排版参数（#81）：纸张、页边距、页眉 / 页脚模板、标题编号、标题不孤行。记在 UserDefaults（JSON）。
struct PDFLayout: Codable, Equatable {
    enum Paper: String, Codable, CaseIterable { case system, a4, letter }
    var paper: Paper = .system
    var top: Double = 40, bottom: Double = 40, left: Double = 40, right: Double = 40
    /// 模板占位符：{page} {pages} {title} {file} {date}
    var header = ""
    var footer = "{page} / {pages}"
    var headingNumbers = false
    var keepHeadingWithNext = true

    static let key = "pdf.layout"
    static let placeholders = ["{page}", "{pages}", "{title}", "{file}", "{date}"]

    @MainActor static func load() -> PDFLayout {
        guard let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode(PDFLayout.self, from: d) else {
            var l = PDFLayout(); l.headingNumbers = Preferences.shared.headingNumbers; return l   // 没单独设过就跟阅读视图一致
        }
        return l
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) } }

    func paperSize(default system: NSSize) -> NSSize {
        switch paper { case .system: return system; case .a4: return NSSize(width: 595, height: 842); case .letter: return NSSize(width: 612, height: 792) }
    }

    /// 打印与导出 PDF 共用的 NSPrintInfo 设置。`forPrintPanel`：纸张交给打印面板，这里不改
    func configure(_ info: NSPrintInfo, forPrintPanel: Bool) {
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        if !forPrintPanel { info.paperSize = paperSize(default: info.paperSize) }
        info.topMargin = max(0, top); info.bottomMargin = max(0, bottom); info.leftMargin = max(0, left); info.rightMargin = max(0, right)
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true
    }

    /// 展开模板；全空返回 nil
    static func expand(_ template: String, page: Int, pages: Int, title: String, file: String, date: Date = Date()) -> String? {
        let t = template.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        return t.replacingOccurrences(of: "{page}", with: String(page))
            .replacingOccurrences(of: "{pages}", with: String(pages))
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{file}", with: file)
            .replacingOccurrences(of: "{date}", with: df.string(from: date))
    }

    /// 页眉靠左、页脚居中（模板里用 `|` 分成 左|中|右 三段）
    static func attributed(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment) -> NSAttributedString {
        let ps = NSMutableParagraphStyle(); ps.alignment = alignment; ps.lineBreakMode = .byTruncatingMiddle
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])
    }

    /// 用 tab stop 把 `左|中|右` 排进一行
    static func line(_ text: String, width: CGFloat, font: NSFont, color: NSColor) -> NSAttributedString {
        let parts = text.components(separatedBy: "|")
        guard parts.count > 1 else { return attributed(text, font: font, color: color, alignment: .center) }
        let ps = NSMutableParagraphStyle()
        ps.tabStops = [NSTextTab(textAlignment: .center, location: width / 2), NSTextTab(textAlignment: .right, location: width)]
        ps.lineBreakMode = .byClipping
        let l = parts[0], c = parts.count > 1 ? parts[1] : "", r = parts.count > 2 ? parts[2] : ""
        return NSAttributedString(string: "\(l)\t\(c)\t\(r)", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])
    }
}

/// 存盘面板的附加视图
@MainActor
final class PDFLayoutModel: ObservableObject {
    @Published var layout: PDFLayout
    init(_ l: PDFLayout = .load()) { layout = l }
}

struct PDFLayoutView: View {
    @ObservedObject var model: PDFLayoutModel
    private let labelWidth: CGFloat = 80

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).frame(width: labelWidth, alignment: .trailing)
            content()
        }
    }
    private func margin(_ label: String, _ kp: WritableKeyPath<PDFLayout, Double>) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary).font(.callout)
            TextField("", value: Binding(get: { model.layout[keyPath: kp] }, set: { model.layout[keyPath: kp] = min(200, max(0, $0)) }), format: .number)
                .frame(width: 40).multilineTextAlignment(.trailing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(L("纸张")) {
                Picker("", selection: $model.layout.paper) {
                    Text(L("跟随系统")).tag(PDFLayout.Paper.system)
                    Text("A4").tag(PDFLayout.Paper.a4)
                    Text("Letter").tag(PDFLayout.Paper.letter)
                }.labelsHidden().frame(width: 120)
            }
            row(L("页边距（pt）")) {
                margin(L("上"), \.top); margin(L("下"), \.bottom); margin(L("左"), \.left); margin(L("右"), \.right)
            }
            row(L("页眉")) { TextField("", text: $model.layout.header, prompt: Text(L("例：{title}|  |{date}"))).frame(width: 260) }
            row(L("页脚")) { TextField("", text: $model.layout.footer, prompt: Text("{page} / {pages}")).frame(width: 260) }
            row("") {
                Text(L("占位符：{page} {pages} {title} {file} {date}；用 | 分成 左|中|右"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(width: 300, alignment: .leading)
            }
            row("") { Toggle(L("标题自动编号"), isOn: $model.layout.headingNumbers) }
            row("") { Toggle(L("标题不孤行（标题与下一段同页）"), isOn: $model.layout.keepHeadingWithNext) }
        }
        .padding(.vertical, 10)
        .frame(width: 400)
    }
}
