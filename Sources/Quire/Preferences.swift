import AppKit
import SwiftUI
import QuireCore
import QuireRender

/// 用户偏好（UserDefaults）。变化时通过 ThemeManager.refresh 触发重渲染。
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    private enum Key {
        static let codeLineNumbers = "reader.codeLineNumbers"
        static let codeCopyButton = "reader.codeCopyButton"
        static let linkUnderline = "reader.linkUnderline"
        static let autoReload = "reader.autoReload"
        static let editorLineNumbers = "editor.lineNumbers"
        static let largeFileMB = "render.largeFileThresholdMB"
        static let wordCount = "reader.wordCount"
        static let hangingMarkers = "editor.hangingMarkers"
        static let htmlPaste = "editor.convertHTMLOnPaste"
        static let editorFont = "editor.fontFamily"
        static let editorFontSize = "editor.fontSize"
        static let editorLineHeight = "editor.lineHeight"
        static let editorColumn = "editor.columnChars"
        static let readerBodyFont = "reader.bodyFontFamily"
        static let readerCodeFont = "reader.codeFontFamily"
        static let readerFontSize = "reader.baseFontSize"
        static let math = "parser.math"
        static let toc = "parser.toc"
        static let smart = "parser.smartPunctuation"
        static let headingNumbers = "render.headingNumbers"
        static let updates = "update.check"
        static let sidebarHidden = "sidebar.showHidden"
        static let sidebarOthers = "sidebar.showOtherFiles"
        static let sidebarExts = "sidebar.extraExtensions"
    }

    @Published var codeLineNumbers: Bool { didSet { d.set(codeLineNumbers, forKey: Key.codeLineNumbers); ThemeManager.shared.refresh() } }
    @Published var codeCopyButton: Bool { didSet { d.set(codeCopyButton, forKey: Key.codeCopyButton); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var linkUnderline: Bool { didSet { d.set(linkUnderline, forKey: Key.linkUnderline); ThemeManager.shared.refresh() } }
    @Published var autoReload: Bool { didSet { d.set(autoReload, forKey: Key.autoReload); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var editorLineNumbers: Bool { didSet { d.set(editorLineNumbers, forKey: Key.editorLineNumbers); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var largeFileThresholdMB: Int { didSet { d.set(largeFileThresholdMB, forKey: Key.largeFileMB) } }
    @Published var showWordCount: Bool { didSet { d.set(showWordCount, forKey: Key.wordCount); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var editorHangingMarkers: Bool { didSet { d.set(editorHangingMarkers, forKey: Key.hangingMarkers); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var convertHTMLOnPaste: Bool { didSet { d.set(convertHTMLOnPaste, forKey: Key.htmlPaste); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var editorFontFamily: String { didSet { d.set(editorFontFamily, forKey: Key.editorFont); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var editorFontSize: Int { didSet { d.set(editorFontSize, forKey: Key.editorFontSize); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var editorLineHeight: Double { didSet { d.set(editorLineHeight, forKey: Key.editorLineHeight); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var editorColumnChars: Int { didSet { d.set(editorColumnChars, forKey: Key.editorColumn); NotificationCenter.default.post(name: Self.didChange, object: nil) } }

    @Published var readerBodyFontFamily: String { didSet { d.set(readerBodyFontFamily, forKey: Key.readerBodyFont); ThemeManager.shared.refresh() } }
    @Published var readerCodeFontFamily: String { didSet { d.set(readerCodeFontFamily, forKey: Key.readerCodeFont); ThemeManager.shared.refresh() } }
    @Published var readerBaseFontSize: Int { didSet { d.set(readerBaseFontSize, forKey: Key.readerFontSize); ThemeManager.shared.refresh() } }

    @Published var mathEnabled: Bool { didSet { d.set(mathEnabled, forKey: Key.math); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var tocEnabled: Bool { didSet { d.set(tocEnabled, forKey: Key.toc); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var smartPunctuation: Bool { didSet { d.set(smartPunctuation, forKey: Key.smart); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var headingNumbers: Bool { didSet { d.set(headingNumbers, forKey: Key.headingNumbers); ThemeManager.shared.refresh() } }
    @Published var checkForUpdates: Bool { didSet { d.set(checkForUpdates, forKey: Key.updates) } }
    @Published var sidebarShowHidden: Bool { didSet { d.set(sidebarShowHidden, forKey: Key.sidebarHidden); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var sidebarShowOtherFiles: Bool { didSet { d.set(sidebarShowOtherFiles, forKey: Key.sidebarOthers); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    /// 额外当作 Markdown 显示 / 打开的扩展名（空格分隔，如 "mdx rmd qmd"）
    @Published var sidebarExtraExtensions: String { didSet { d.set(sidebarExtraExtensions, forKey: Key.sidebarExts); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    var extraExtensionSet: Set<String> { Set(sidebarExtraExtensions.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }) }
    /// 侧栏过滤规则快照（给后台目录扫描用）
    struct SidebarRules: Sendable, Equatable { var showHidden: Bool; var showOthers: Bool; var extraExtensions: Set<String> }
    var sidebarRules: SidebarRules { SidebarRules(showHidden: sidebarShowHidden, showOthers: sidebarShowOtherFiles, extraExtensions: extraExtensionSet) }
    var parserOptions: MarkdownParser.Options { var o = MarkdownParser.Options(); o.math = mathEnabled; o.toc = tocEnabled; o.smartPunctuation = smartPunctuation; return o }

    var editorTypography: EditorTypography {
        EditorTypography(fontFamily: editorFontFamily.isEmpty ? nil : editorFontFamily, fontSize: CGFloat(editorFontSize), lineHeight: CGFloat(editorLineHeight), columnChars: editorColumnChars)
    }

    static let didChange = Notification.Name("com.korako.quire.preferencesDidChange")

    private init() {
        d.register(defaults: [Key.codeCopyButton: true, Key.autoReload: true, Key.editorLineNumbers: true, Key.largeFileMB: 8, Key.wordCount: true, Key.hangingMarkers: true, Key.htmlPaste: true, Key.editorLineHeight: 1.35, Key.math: true, Key.updates: true, Key.toc: true])
        codeLineNumbers = d.bool(forKey: Key.codeLineNumbers)
        codeCopyButton = d.bool(forKey: Key.codeCopyButton)
        linkUnderline = d.bool(forKey: Key.linkUnderline)
        autoReload = d.bool(forKey: Key.autoReload)
        editorLineNumbers = d.bool(forKey: Key.editorLineNumbers)
        largeFileThresholdMB = max(1, d.integer(forKey: Key.largeFileMB))
        showWordCount = d.bool(forKey: Key.wordCount)
        editorHangingMarkers = d.bool(forKey: Key.hangingMarkers)
        convertHTMLOnPaste = d.bool(forKey: Key.htmlPaste)
        editorFontFamily = d.string(forKey: Key.editorFont) ?? ""
        editorFontSize = d.integer(forKey: Key.editorFontSize)
        editorLineHeight = d.double(forKey: Key.editorLineHeight)
        editorColumnChars = d.integer(forKey: Key.editorColumn)
        readerBodyFontFamily = d.string(forKey: Key.readerBodyFont) ?? ""
        readerCodeFontFamily = d.string(forKey: Key.readerCodeFont) ?? ""
        readerBaseFontSize = d.integer(forKey: Key.readerFontSize)
        mathEnabled = d.bool(forKey: Key.math)
        tocEnabled = d.bool(forKey: Key.toc)
        smartPunctuation = d.bool(forKey: Key.smart)
        headingNumbers = d.bool(forKey: Key.headingNumbers)
        checkForUpdates = d.bool(forKey: Key.updates)
        sidebarShowHidden = d.bool(forKey: Key.sidebarHidden)
        sidebarShowOtherFiles = d.bool(forKey: Key.sidebarOthers)
        sidebarExtraExtensions = d.string(forKey: Key.sidebarExts) ?? ""
    }

    var renderOptions: RenderOptions {
        RenderOptions(codeLineNumbers: codeLineNumbers, linkUnderline: linkUnderline, largeFile: false,
                      bodyFontFamily: readerBodyFontFamily, codeFontFamily: readerCodeFontFamily, baseFontSize: readerBaseFontSize, headingNumbers: headingNumbers)
    }
    var largeFileThresholdBytes: Int { largeFileThresholdMB * 1024 * 1024 }
}

// MARK: - 偏好设置窗口（SwiftUI；低频 UI）

@MainActor
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private init() {
        let host = NSHostingController(rootView: PreferencesView())
        let window = NSWindow(contentViewController: host)
        window.title = L("Quire 设置")
        window.styleMask = [.titled, .closable, .resizable]
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) - 80
        window.setContentSize(NSSize(width: 460, height: min(800, maxH)))
        window.minSize = NSSize(width: 460, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PreferencesView: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var lightTheme = ThemeManager.shared.lightThemeID
    @State private var darkTheme = ThemeManager.shared.darkThemeID
    @State private var mode = ThemeManager.shared.mode
    @State private var language = AppLanguage.current
    @State private var languageChanged = false
    @State private var fontMessage = ""
    @State private var cliMessage = ""
    @State private var cliInstalled = CLIInstaller.isInstalled
    private var allFamilies: [String] {
        var out = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
        if !prefs.readerBodyFontFamily.isEmpty, !out.contains(prefs.readerBodyFontFamily) { out.insert(prefs.readerBodyFontFamily, at: 0) }
        return out
    }
    private var fontFamilies: [String] {
        // 等宽 + 已装的 iA Writer 三款（Duo / Quattro 不是严格等宽）
        let fm = NSFontManager.shared
        var out = fm.availableFontFamilies.filter { fam in
            fam.hasPrefix("iA Writer") || (fm.font(withFamily: fam, traits: [], weight: 5, size: 12)?.isFixedPitch ?? false)
        }
        out.sort()
        if !prefs.editorFontFamily.isEmpty, !out.contains(prefs.editorFontFamily) { out.insert(prefs.editorFontFamily, at: 0) }
        return out
    }

    var body: some View {
        Form {
            Section(L("语言")) {
                Picker(L("界面语言"), selection: $language) {
                    Text(L("跟随系统")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.zhHans)
                    Text("English").tag(AppLanguage.en)
                }
                .onChange(of: language) { _, l in AppLanguage.current = l; languageChanged = true }
                if languageChanged {
                    Text(L("重新打开 Quire 后生效")).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L("每天自动检查更新（只读 GitHub Releases，不上传信息）"), isOn: $prefs.checkForUpdates)
                HStack {
                    Button(cliInstalled ? L("重新安装命令行工具") : L("安装命令行工具 quire…")) {
                        if let err = CLIInstaller.install() { cliMessage = err } else { cliMessage = L("已安装：终端里 quire 文件.md / quire ."); cliInstalled = true }
                    }
                    Text(cliMessage.isEmpty ? (cliInstalled ? L("已安装到 /usr/local/bin/quire") : L("quire README.md · quire .")) : cliMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("外观")) {
                Picker(L("模式"), selection: $mode) {
                    Text(L("跟随系统")).tag(ThemeManager.AppearanceMode.system)
                    Text(L("浅色")).tag(ThemeManager.AppearanceMode.light)
                    Text(L("深色")).tag(ThemeManager.AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, m in ThemeManager.shared.mode = m }
                Picker(L("浅色主题"), selection: $lightTheme) {
                    ForEach(ThemeManager.shared.catalog.themes(for: .light), id: \.id) { Text($0.name).tag($0.id) }
                }
                .onChange(of: lightTheme) { _, id in ThemeManager.shared.lightThemeID = id }
                Picker(L("深色主题"), selection: $darkTheme) {
                    ForEach(ThemeManager.shared.catalog.themes(for: .dark), id: \.id) { Text($0.name).tag($0.id) }
                }
                .onChange(of: darkTheme) { _, id in ThemeManager.shared.darkThemeID = id }
                HStack {
                    Button(L("打开主题文件夹")) {
                        let dir = ThemeStore.userThemesDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    Spacer()
                    if !ThemeManager.shared.loadErrors.isEmpty {
                        Text(String(format: L("%d 个主题加载失败"), ThemeManager.shared.loadErrors.count))
                            .foregroundStyle(.red).font(.caption)
                            .help(ThemeManager.shared.loadErrors.map(\.description).joined(separator: "\n"))
                    }
                }
            }
            Section(L("阅读")) {
                Picker(L("正文字体"), selection: $prefs.readerBodyFontFamily) {
                    Text(L("跟随主题")).tag("")
                    ForEach(allFamilies, id: \.self) { Text($0).tag($0) }
                }
                Picker(L("代码字体"), selection: $prefs.readerCodeFontFamily) {
                    Text(L("跟随主题")).tag("")
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                Picker(L("基础字号"), selection: $prefs.readerBaseFontSize) {
                    Text(L("跟随主题")).tag(0)
                    ForEach([13, 14, 15, 16, 17, 18, 19, 20, 22, 24], id: \.self) { Text("\($0) pt").tag($0) }
                }
                Toggle(L("数学公式（$$…$$ 块与 $…$ 行内，LaTeX）"), isOn: $prefs.mathEnabled)
                Toggle(L("[TOC] 展开为目录"), isOn: $prefs.tocEnabled)
                Toggle(L("标题自动编号（1 / 1.1 / 1.1.1）"), isOn: $prefs.headingNumbers)
                Toggle(L("智能标点（弯引号、破折号、省略号）"), isOn: $prefs.smartPunctuation)
                Toggle(L("代码块显示行号"), isOn: $prefs.codeLineNumbers)
                Toggle(L("代码块显示复制按钮"), isOn: $prefs.codeCopyButton)
                Toggle(L("链接显示下划线"), isOn: $prefs.linkUnderline)
                Toggle(L("文件被外部修改时自动重新载入"), isOn: $prefs.autoReload)
                Toggle(L("右下角显示字数统计"), isOn: $prefs.showWordCount)
                Stepper(String(format: L("大文件模式阈值：%d MB"), prefs.largeFileThresholdMB), value: $prefs.largeFileThresholdMB, in: 1...64)
                    .help(L("超过阈值的文件关闭代码高亮与 Mermaid 渲染"))
            }
            Section(L("侧栏")) {
                Toggle(L("显示隐藏文件与文件夹"), isOn: $prefs.sidebarShowHidden)
                Toggle(L("显示非 Markdown 文件（双击用默认 App 打开）"), isOn: $prefs.sidebarShowOtherFiles)
                TextField(L("额外按 Markdown 处理的扩展名（空格分隔）"), text: $prefs.sidebarExtraExtensions, prompt: Text("mdx rmd qmd"))
            }
            Section(L("编辑")) {
                Picker(L("字体"), selection: $prefs.editorFontFamily) {
                    Text(L("跟随主题（代码字体）")).tag("")
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                Picker(L("字号"), selection: $prefs.editorFontSize) {
                    Text(L("跟随主题")).tag(0)
                    ForEach([11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24], id: \.self) { Text("\($0) pt").tag($0) }
                }
                Picker(L("行距"), selection: $prefs.editorLineHeight) {
                    ForEach([1.2, 1.35, 1.5, 1.7, 2.0], id: \.self) { Text(String(format: "%.2f", $0)).tag($0) }
                }
                Picker(L("行宽"), selection: $prefs.editorColumnChars) {
                    Text(L("不限")).tag(0)
                    ForEach([60, 72, 80, 100], id: \.self) { Text(String(format: L("%d 字符"), $0)).tag($0) }
                }
                HStack {
                    Button(L("下载 iA Writer 字体…")) { IAFonts.download { installed in fontMessage = installed ? L("已安装到 ~/Library/Fonts，可在上面选择 iA Writer Mono / Duo / Quattro") : L("下载失败，请检查网络") } }
                        .disabled(IAFonts.isInstalled)
                    Text(IAFonts.isInstalled ? L("iA Writer Mono / Duo / Quattro 已安装") : fontMessage).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L("显示行号"), isOn: $prefs.editorLineNumbers)
                Toggle(L("标记出挑（# - > 1. 悬挂到左边距，正文左缘对齐）"), isOn: $prefs.editorHangingMarkers)
                Toggle(L("粘贴网页 / 富文本时自动转成 Markdown（⇧⌘V 粘纯文本）"), isOn: $prefs.convertHTMLOnPaste)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

/// 界面语言覆盖：写 App 自己的 `AppleLanguages`（标准做法，重启后 Bundle 按此选语言）；跟随系统 = 删除覆盖。
enum AppLanguage: String, CaseIterable {
    case system, zhHans = "zh-Hans", en

    static var current: AppLanguage {
        get {
            guard let langs = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
                  UserDefaults.standard.objectIsForced(forKey: "AppleLanguages") == false,
                  let first = langs.first else { return .system }
            // 只有显式写入 App 域的才算覆盖（全局域的值由系统提供）
            guard UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil else { return .system }
            return first.hasPrefix("zh") ? .zhHans : (first.hasPrefix("en") ? .en : .system)
        }
        set {
            switch newValue {
            case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .zhHans: UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
            case .en: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            }
        }
    }
}
