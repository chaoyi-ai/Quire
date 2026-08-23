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
    /// 钉在具体 commit 上：SHA256 是按这个版本算的，跟 master 走的话上游一改字体就永远"下载失败"
    static let base = "https://raw.githubusercontent.com/iaolo/iA-Fonts/f32c04c3058a75d7ce28919ce70fe8800817491b/"
    static var fontsDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts") }

    /// 三个家族都在才算装好（只装了一半时按钮仍可点、可以补齐）
    static var isInstalled: Bool {
        let fams = Set(NSFontManager.shared.availableFontFamilies)
        return ["iA Writer Mono", "iA Writer Duo", "iA Writer Quattro"].allSatisfy { fams.contains($0) }
    }

    enum Failure: Error { case network(String), mismatch(String), write(String) }

    /// 六个文件先全部下到临时目录并校验，再一起搬进 ~/Library/Fonts（不会装到一半）；失败原因给出来而不是一律"检查网络"
    static func download(completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        let files = self.files, base = self.base, dir = fontsDir
        Task.detached(priority: .userInitiated) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quire-iafonts-\(getpid())")
            var staged: [(URL, URL)] = []
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                for f in files {
                    guard let url = URL(string: base + f.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) else { throw Failure.network(f.path) }
                    let (data, resp): (Data, URLResponse)
                    do { (data, resp) = try await URLSession.shared.data(from: url) } catch { throw Failure.network(error.localizedDescription) }
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.network("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) \(f.path)") }
                    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == f.sha256 else { throw Failure.mismatch(f.path) }
                    let name = (f.path as NSString).lastPathComponent
                    let t = tmp.appendingPathComponent(name)
                    try data.write(to: t, options: .atomic)
                    staged.append((t, dir.appendingPathComponent(name)))
                }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (t, dest) in staged {
                    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                    try FileManager.default.moveItem(at: t, to: dest)
                }
            } catch let e as Failure {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run { completion(.failure(e)) }; return
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run { completion(.failure(.write(error.localizedDescription))) }; return
            }
            try? FileManager.default.removeItem(at: tmp)
            CTFontManagerRegisterFontURLs(staged.map { $0.1 } as CFArray, .user, true, nil)
            await MainActor.run { completion(.success(())) }
        }
    }
}
