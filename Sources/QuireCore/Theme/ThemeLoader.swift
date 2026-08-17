import Foundation

public enum ThemeError: Error, CustomStringConvertible, Sendable {
    case invalidJSON(String)
    case unsupportedSchema(Int?)
    case missingField(String)
    case invalidID(String)
    case unknownParent(String)
    case nestedExtends(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .invalidJSON(let m): "JSON 无法解析：\(m)"
        case .unsupportedSchema(let s): "不支持的 schema \(s.map(String.init) ?? "（缺失）")，需要 1"
        case .missingField(let f): "缺少必填字段 \(f)"
        case .invalidID(let id): "非法 id \"\(id)\"（只允许 a-z 0-9 -）"
        case .unknownParent(let p): "extends 指向不存在的主题 \"\(p)\""
        case .nestedExtends(let p): "extends 只允许一层，\"\(p)\" 自身也 extends 了别的主题"
        case .decoding(let m): m
        }
    }
}

/// 把主题 JSON 解析为完整 `Theme`：缺失字段依次回退 → `extends` 父主题 → 同外观默认主题。
public struct ThemeLoader: Sendable {
    /// 已解析可作为父主题的集合（内置 + 已加载用户主题）
    public var available: [String: Theme]
    /// 各外观默认主题 id
    public var defaults: [Appearance: String] = [.light: "github-light", .dark: "github-dark"]

    public init(available: [String: Theme] = [:]) { self.available = available }

    public func load(data: Data, sourcePath: String? = nil) throws -> Theme {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data) } catch { throw ThemeError.invalidJSON(error.localizedDescription) }
        guard var dict = any as? [String: Any] else { throw ThemeError.invalidJSON("顶层不是对象") }

        guard let schema = dict["schema"] as? Int, schema == 1 else { throw ThemeError.unsupportedSchema(dict["schema"] as? Int) }
        guard let id = dict["id"] as? String else { throw ThemeError.missingField("id") }
        guard id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { throw ThemeError.invalidID(id) }
        guard dict["name"] is String else { throw ThemeError.missingField("name") }
        guard let appStr = dict["appearance"] as? String, let appearance = Appearance(rawValue: appStr) else {
            throw ThemeError.missingField("appearance (light|dark)")
        }

        // 基底：extends 父主题，否则同外观默认；默认主题自身不需要基底
        var base: [String: Any] = [:]
        if let parentID = dict["extends"] as? String {
            guard let parent = available[parentID] else { throw ThemeError.unknownParent(parentID) }
            if let parentSource = parent.extendsID { throw ThemeError.nestedExtends(parentSource) }
            base = try Self.dictionary(of: parent)
        } else if let defID = defaults[appearance], defID != id, let def = available[defID] {
            base = try Self.dictionary(of: def)
        }
        base.removeValue(forKey: "extends")
        base.removeValue(forKey: "sourcePath")
        base.removeValue(forKey: "extendsID")

        let extendsID = dict["extends"] as? String
        dict.removeValue(forKey: "extends")
        dict.removeValue(forKey: "schema")
        var merged = Self.deepMerge(base: base, overlay: dict)
        if let sourcePath { merged["sourcePath"] = sourcePath }
        if let extendsID { merged["extendsID"] = extendsID }

        do {
            let json = try JSONSerialization.data(withJSONObject: merged)
            return try JSONDecoder().decode(Theme.self, from: json)
        } catch let e as DecodingError {
            throw ThemeError.decoding(Self.describe(e))
        }
    }

    public func load(url: URL) throws -> Theme {
        try load(data: Data(contentsOf: url), sourcePath: url.path)
    }

    // MARK: helpers

    static func dictionary(of theme: Theme) throws -> [String: Any] {
        let data = try JSONEncoder().encode(theme)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func deepMerge(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in overlay {
            if let vd = v as? [String: Any], let bd = out[k] as? [String: Any] {
                out[k] = deepMerge(base: bd, overlay: vd)
            } else {
                out[k] = v
            }
        }
        return out
    }

    static func describe(_ e: DecodingError) -> String {
        func path(_ c: [CodingKey]) -> String { c.map(\.stringValue).joined(separator: ".") }
        switch e {
        case .keyNotFound(let k, let ctx): return "缺少字段 \(path(ctx.codingPath + [k]))"
        case .typeMismatch(_, let ctx): return "字段类型错误 \(path(ctx.codingPath))：\(ctx.debugDescription)"
        case .valueNotFound(_, let ctx): return "字段为空 \(path(ctx.codingPath))"
        case .dataCorrupted(let ctx): return "\(path(ctx.codingPath))：\(ctx.debugDescription)"
        @unknown default: return "\(e)"
        }
    }
}
