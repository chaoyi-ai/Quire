import AppKit
import CryptoKit

/// iA Writer 三款开源字体（IBM Plex 衍生，SIL OFL，保留字体名 "iA Writer"；https://github.com/iaolo/iA-Fonts）。
/// 不随包（App 体积预算 < 10 MB）：首次启用时下载到 ~/Library/Fonts，SHA256 校验后用 CTFontManager 注册。
@MainActor
enum IAFonts {
    struct File { let path: String; let sha256: String }
    static let files: [File] = [
        File(path: "iA Writer Mono/Variable/iAWriterMonoV.ttf", sha256: "ca8b5740d7fd05ffd1a9e985a2fe6b7608101f0583d2cf971317c82b4ce01240"),
        File(path: "iA Writer Mono/Variable/iAWriterMonoV-Italic.ttf", sha256: "9ab3465dd180ff05b6375f22e0197d696697489ddd7860b85f19b213c0d4edf0"),
        File(path: "iA Writer Duo/Variable/iAWriterDuoV.ttf", sha256: "00dba4a19f34191ef7e499a6ca05739e11c56f41567d8a283e7ae9dd504c9b38"),
        File(path: "iA Writer Duo/Variable/iAWriterDuoV-Italic.ttf", sha256: "6a2b3ce4e948097878738301eb08e40337d0d25cad88f83f4740ccc5c83084ed"),
        File(path: "iA Writer Quattro/Variable/iAWriterQuattroV.ttf", sha256: "7e96e359a887bbcaadc71e3ae17e3146fb3a2c901aa5701181f37e9e650462f0"),
        File(path: "iA Writer Quattro/Variable/iAWriterQuattroV-Italic.ttf", sha256: "33c28901b4f0dbfd4be80d7b6c7708c86e75c5d35ac48405c5a168775be9383a"),
    ]
    static let base = "https://raw.githubusercontent.com/iaolo/iA-Fonts/master/"
    static var fontsDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts") }

    static var isInstalled: Bool {
        NSFontManager.shared.availableFontFamilies.contains("iA Writer Mono")
    }

    static func download(completion: @escaping @MainActor (Bool) -> Void) {
        let files = self.files, base = self.base, dir = fontsDir
        Task.detached(priority: .userInitiated) {
            var ok = true
            var urls: [URL] = []
            for f in files {
                guard let url = URL(string: base + f.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) else { ok = false; break }
                do {
                    let (data, resp) = try await URLSession.shared.data(from: url)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200,
                          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == f.sha256 else { ok = false; break }
                    let dest = dir.appendingPathComponent((f.path as NSString).lastPathComponent)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try data.write(to: dest, options: .atomic)
                    urls.append(dest)
                } catch { ok = false; break }
            }
            if ok { CTFontManagerRegisterFontURLs(urls as CFArray, .user, true, nil) }
            await MainActor.run { completion(ok) }
        }
    }
}
