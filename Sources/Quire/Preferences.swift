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

    static let didChange = Notification.Name("com.korako.quire.preferencesDidChange")

    private init() {
        d.register(defaults: [Key.codeCopyButton: true, Key.autoReload: true, Key.editorLineNumbers: true, Key.largeFileMB: 8, Key.wordCount: true, Key.hangingMarkers: true, Key.htmlPaste: true])
        codeLineNumbers = d.bool(forKey: Key.codeLineNumbers)
        codeCopyButton = d.bool(forKey: Key.codeCopyButton)
        linkUnderline = d.bool(forKey: Key.linkUnderline)
        autoReload = d.bool(forKey: Key.autoReload)
        editorLineNumbers = d.bool(forKey: Key.editorLineNumbers)
        largeFileThresholdMB = max(1, d.integer(forKey: Key.largeFileMB))
        showWordCount = d.bool(forKey: Key.wordCount)
        editorHangingMarkers = d.bool(forKey: Key.hangingMarkers)
        convertHTMLOnPaste = d.bool(forKey: Key.htmlPaste)
    }

    var renderOptions: RenderOptions {
        RenderOptions(codeLineNumbers: codeLineNumbers, linkUnderline: linkUnderline, largeFile: false)
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
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 560))
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
                Toggle(L("代码块显示行号"), isOn: $prefs.codeLineNumbers)
                Toggle(L("代码块显示复制按钮"), isOn: $prefs.codeCopyButton)
                Toggle(L("链接显示下划线"), isOn: $prefs.linkUnderline)
                Toggle(L("文件被外部修改时自动重新载入"), isOn: $prefs.autoReload)
                Toggle(L("右下角显示字数统计"), isOn: $prefs.showWordCount)
                Stepper(String(format: L("大文件模式阈值：%d MB"), prefs.largeFileThresholdMB), value: $prefs.largeFileThresholdMB, in: 1...64)
                    .help(L("超过阈值的文件关闭代码高亮与 Mermaid 渲染"))
            }
            Section(L("编辑")) {
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
