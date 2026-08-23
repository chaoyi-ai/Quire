import AppKit
import QuireCore
import QuireRender

/// 主题状态：目录、当前选择（亮/暗各一）、外观模式、缩放。变化时广播 `didChange`。
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()
    static let didChange = Notification.Name("com.korako.quire.themeDidChange")

    enum AppearanceMode: String { case light, dark, system }

    private(set) var catalog: ThemeCatalog
    private(set) var currentStyle: RenderStyle

    private let defaults = UserDefaults.standard
    private var userThemesWatcher: FileWatcher?
    private var appearanceObserver: NSKeyValueObservation?

    private enum Key {
        static let lightTheme = "theme.light", darkTheme = "theme.dark", mode = "theme.mode", zoom = "view.zoom"
    }

    var lightThemeID: String {
        get { defaults.string(forKey: Key.lightTheme) ?? "github-light" }
        set { defaults.set(newValue, forKey: Key.lightTheme); refresh() }
    }
    var darkThemeID: String {
        get { defaults.string(forKey: Key.darkTheme) ?? "github-dark" }
        set { defaults.set(newValue, forKey: Key.darkTheme); refresh() }
    }
    var mode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.mode); applyAppAppearance(); refresh() }
    }
    var zoom: CGFloat {
        get { let z = defaults.double(forKey: Key.zoom); return z == 0 ? 1 : CGFloat(z) }
        set { defaults.set(Double(newValue), forKey: Key.zoom); refresh() }
    }

    /// 当前有效外观（system 模式看系统）
    var effectiveAppearance: Appearance {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .system:
            let best = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return best == .darkAqua ? .dark : .light
        }
    }

    var currentTheme: Theme { currentStyle.theme }

    /// 用户主题加载错误（偏好设置显示）
    var loadErrors: [ThemeLoadFailure] { catalog.errors }

    private init() {
        catalog = ThemeStore.loadBuiltIn()
        // 先用内置构造，避免启动时读用户目录
        let fallback = catalog.theme(id: "github-light") ?? catalog.themes.first!
        currentStyle = RenderStyle(theme: fallback, scale: 1)
        applyAppAppearance()
        currentStyle = RenderStyle(theme: resolveTheme(), scale: zoom, options: Preferences.shared.renderOptions)
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// 选择主题：按主题外观写入对应槽位；若模式与主题外观不符则切换模式
    func select(themeID: String) {
        guard let t = catalog.theme(id: themeID) else { return }
        if t.appearance == .dark { defaults.set(themeID, forKey: Key.darkTheme) } else { defaults.set(themeID, forKey: Key.lightTheme) }
        // 选了与当前外观相反的主题：切换外观模式，让它立即生效
        if effectiveAppearance != t.appearance {
            defaults.set((t.appearance == .dark ? AppearanceMode.dark : .light).rawValue, forKey: Key.mode)
            applyAppAppearance()
        }
        refresh()
    }

    /// 重新加载全部（内置 + 用户目录）
    func reloadCatalog() {
        catalog = ThemeStore.loadAll()
        refresh()
    }

    func startWatchingUserThemes() {
        let dir = ThemeStore.userThemesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reloadCatalog()
        userThemesWatcher = FileWatcher(url: dir, debounce: 0.3) { [weak self] in
            Task { @MainActor in self?.reloadCatalog() }
        }
    }

    /// 打印 / PDF 用：永远是浅色主题（当前浅色槽位；纸是白的，深色主题的浅字印出来看不见）
    var printTheme: Theme {
        if currentTheme.appearance == .light { return currentTheme }
        if let t = catalog.theme(id: lightThemeID), t.appearance == .light { return t }
        return catalog.themes(for: .light).first ?? currentTheme
    }

    private func resolveTheme() -> Theme {
        let id = effectiveAppearance == .dark ? darkThemeID : lightThemeID
        if let t = catalog.theme(id: id) { return t }
        return catalog.themes(for: effectiveAppearance).first ?? catalog.themes.first!
    }

    func refresh() {
        let t = resolveTheme()
        let z = zoom
        let o = Preferences.shared.renderOptions
        if t == currentStyle.theme, z == currentStyle.scale, o == currentStyle.options { return }
        currentStyle = RenderStyle(theme: t, scale: z, options: o)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func applyAppAppearance() {
        switch mode {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }

    // 缩放步进
    func zoomIn() { zoom = min(3, (zoom + 0.1).rounded(toPlaces: 2)) }
    func zoomOut() { zoom = max(0.5, (zoom - 0.1).rounded(toPlaces: 2)) }
    func zoomReset() { zoom = 1 }
}

extension CGFloat {
    func rounded(toPlaces p: Int) -> CGFloat { let m = pow(10, CGFloat(p)); return (self * m).rounded() / m }
}
