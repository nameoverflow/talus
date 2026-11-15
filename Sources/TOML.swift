import Foundation

enum TOMLValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var arrayValue: [TOMLValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var tableValue: [String: TOMLValue]? {
        if case .table(let t) = self { return t }
        return nil
    }
}

struct TOMLParseError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Thin Swift wrapper delegating TOML parsing to `talus-core` (`toml_edit`).
enum TOMLParser {
    static func parse(_ source: String) throws -> [String: TOMLValue] {
        var errPtr: UnsafeMutablePointer<CChar>?
        let resPtr = source.withCString { cSrc in
            talus_toml_parse_json(cSrc, &errPtr)
        }
        defer {
            if let errPtr { talus_string_free(errPtr) }
            if let resPtr { talus_string_free(resPtr) }
        }
        guard let resPtr else {
            let msg = errPtr.map { String(cString: $0) } ?? "TOML parse error"
            throw TOMLParseError(msg)
        }
        let jsonStr = String(cString: resPtr)
        guard let data = jsonStr.data(using: .utf8),
              let rootObj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              case .table(let dict) = decodeTypedNode(rootObj)
        else {
            throw TOMLParseError("invalid TOML AST payload")
        }
        return dict
    }

    private static func decodeTypedNode(_ raw: [String: Any]) -> TOMLValue {
        let type = raw["type"] as? String ?? ""
        switch type {
        case "string":
            return .string(raw["value"] as? String ?? "")
        case "int":
            return .int((raw["value"] as? NSNumber)?.intValue ?? 0)
        case "double":
            return .double((raw["value"] as? NSNumber)?.doubleValue ?? 0.0)
        case "bool":
            return .bool((raw["value"] as? NSNumber)?.boolValue ?? false)
        case "array":
            let items = (raw["value"] as? [[String: Any]] ?? []).map(decodeTypedNode)
            return .array(items)
        case "table":
            let map = (raw["value"] as? [String: [String: Any]] ?? [:]).mapValues(decodeTypedNode)
            return .table(map)
        default:
            return .string("")
        }
    }
}
