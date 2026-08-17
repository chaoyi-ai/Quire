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
    }

    @Published var codeLineNumbers: Bool { didSet { d.set(codeLineNumbers, forKey: Key.codeLineNumbers); ThemeManager.shared.refresh() } }
    @Published var codeCopyButton: Bool { didSet { d.set(codeCopyButton, forKey: Key.codeCopyButton); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var linkUnderline: Bool { didSet { d.set(linkUnderline, forKey: Key.linkUnderline); ThemeManager.shared.refresh() } }
    @Published var autoReload: Bool { didSet { d.set(autoReload, forKey: Key.autoReload); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var editorLineNumbers: Bool { didSet { d.set(editorLineNumbers, forKey: Key.editorLineNumbers); NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    @Published var largeFileThresholdMB: Int { didSet { d.set(largeFileThresholdMB, forKey: Key.largeFileMB) } }

    static let didChange = Notification.Name("com.korako.quire.preferencesDidChange")

    private init() {
        d.register(defaults: [Key.codeCopyButton: true, Key.autoReload: true, Key.editorLineNumbers: true, Key.largeFileMB: 8])
        codeLineNumbers = d.bool(forKey: Key.codeLineNumbers)
        codeCopyButton = d.bool(forKey: Key.codeCopyButton)
        linkUnderline = d.bool(forKey: Key.linkUnderline)
        autoReload = d.bool(forKey: Key.autoReload)
        editorLineNumbers = d.bool(forKey: Key.editorLineNumbers)
        largeFileThresholdMB = max(1, d.integer(forKey: Key.largeFileMB))
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
        window.title = "Quire 设置"
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

    var body: some View {
        Form {
            Section("外观") {
                Picker("模式", selection: $mode) {
                    Text("跟随系统").tag(ThemeManager.AppearanceMode.system)
                    Text("浅色").tag(ThemeManager.AppearanceMode.light)
                    Text("深色").tag(ThemeManager.AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, m in ThemeManager.shared.mode = m }
                Picker("浅色主题", selection: $lightTheme) {
                    ForEach(ThemeManager.shared.catalog.themes(for: .light), id: \.id) { Text($0.name).tag($0.id) }
                }
                .onChange(of: lightTheme) { _, id in ThemeManager.shared.lightThemeID = id }
                Picker("深色主题", selection: $darkTheme) {
                    ForEach(ThemeManager.shared.catalog.themes(for: .dark), id: \.id) { Text($0.name).tag($0.id) }
                }
                .onChange(of: darkTheme) { _, id in ThemeManager.shared.darkThemeID = id }
                HStack {
                    Button("打开主题文件夹") {
                        let dir = ThemeStore.userThemesDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    Spacer()
                    if !ThemeManager.shared.loadErrors.isEmpty {
                        Text("\(ThemeManager.shared.loadErrors.count) 个主题加载失败")
                            .foregroundStyle(.red).font(.caption)
                            .help(ThemeManager.shared.loadErrors.map(\.description).joined(separator: "\n"))
                    }
                }
            }
            Section("阅读") {
                Toggle("代码块显示行号", isOn: $prefs.codeLineNumbers)
                Toggle("代码块显示复制按钮", isOn: $prefs.codeCopyButton)
                Toggle("链接显示下划线", isOn: $prefs.linkUnderline)
                Toggle("文件被外部修改时自动重新载入", isOn: $prefs.autoReload)
                Stepper("大文件模式阈值：\(prefs.largeFileThresholdMB) MB", value: $prefs.largeFileThresholdMB, in: 1...64)
                    .help("超过阈值的文件关闭代码高亮与 Mermaid 渲染")
            }
            Section("编辑") {
                Toggle("显示行号", isOn: $prefs.editorLineNumbers)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
