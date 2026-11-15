import Foundation

struct ConfigResolution: Equatable {
    let loadURL: URL
    let saveURL: URL
    let migratedFromJSON: Bool
}

enum WorkspaceTarget: Codable, Equatable {
    case index(Int)
    case label(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let n = try? container.decode(Int.self) {
            self = .index(n)
        } else if let s = try? container.decode(String.self) {
            self = .label(s)
        } else {
            throw DecodingError.typeMismatch(
                WorkspaceTarget.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected workspace number (1..9) or label string")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .index(let n): try container.encode(n)
        case .label(let s): try container.encode(s)
        }
    }

    func resolve(workspaceCount: Int, spaceLabels: [String]) -> Int? {
        switch self {
        case .index(let n):
            let idx = n - 1
            return (0..<workspaceCount).contains(idx) ? idx : nil
        case .label(let name):
            if let match = spaceLabels.firstIndex(where: { $0 == name }) {
                return (0..<workspaceCount).contains(match) ? match : nil
            }
            if let n = Int(name), (0..<workspaceCount).contains(n - 1) {
                return n - 1
            }
            return nil
        }
    }
}

struct FloatWindowRule: Codable, Equatable {
    var app: String
    var titles: [String]?
    var exceptTitles: [String]?

    init(app: String, titles: [String]? = nil, exceptTitles: [String]? = nil) {
        self.app = app
        self.titles = titles
        self.exceptTitles = exceptTitles
    }

    func matches(bundleID: String?, windowTitle: String) -> Bool {
        guard let data = try? JSONEncoder().encode(self),
              let ruleJSON = String(data: data, encoding: .utf8)
        else { return false }
        return ruleJSON.withCString { cRule in
            windowTitle.withCString { cTitle in
                if let bundleID {
                    return bundleID.withCString { cBundle in
                        talus_float_rule_matches(cRule, cBundle, cTitle)
                    }
                }
                return talus_float_rule_matches(cRule, nil, cTitle)
            }
        }
    }
}

struct Configuration: Codable, Equatable {
    var modifiers: [String] = ["control", "option"]
    var workspaceMode: String = "native"
    var workspaceCount: Int = 5
    var masterRatio: Double = 0.5
    var ratioStep: Double = 0.03
    var masterCount: Int = 1
    var ignoreApps: [String] = []
    var appWorkspaces: [String: WorkspaceTarget] = [:]
    var floatWindows: [FloatWindowRule] = []
    var statusFormat: String = "{spaces}  {layout}"
    var statusTemplate: String?
    var statusShowIcon: Bool = true
    var workspaceCurrent: String = "<fc=#10201E,#89CFC2> %label%%fullscreen% </fc>"
    var workspaceOther: String = "%label%%fullscreen%"
    var statusFonts: [String] = []
    var statusFontSize: Double = 11.5
    var statusCommands: [StatusCommand] = []
    var spaceLabels: [String] = []
    var workspaceIcons: [String] = []
    var statusTextFile: String?
    var statusStateFile: String?

    private enum CodingKeys: String, CodingKey {
        case modifiers, workspaceMode, workspaceCount
        case masterRatio, ratioStep, masterCount, ignoreApps, appWorkspaces, floatWindows
        case statusFormat, statusTextFile, statusStateFile, statusTemplate
        case statusShowIcon, workspaceCurrent, workspaceOther, statusFonts
        case statusFontSize, statusCommands, spaceLabels, workspaceIcons
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modifiers = try values.decodeIfPresent([String].self, forKey: .modifiers) ?? modifiers
        workspaceMode = try values.decodeIfPresent(String.self, forKey: .workspaceMode) ?? workspaceMode
        workspaceCount = try values.decodeIfPresent(Int.self, forKey: .workspaceCount) ?? workspaceCount
        masterRatio = try values.decodeIfPresent(Double.self, forKey: .masterRatio) ?? masterRatio
        ratioStep = try values.decodeIfPresent(Double.self, forKey: .ratioStep) ?? ratioStep
        masterCount = try values.decodeIfPresent(Int.self, forKey: .masterCount) ?? masterCount
        ignoreApps = try values.decodeIfPresent([String].self, forKey: .ignoreApps) ?? ignoreApps
        appWorkspaces = try values.decodeIfPresent([String: WorkspaceTarget].self, forKey: .appWorkspaces) ?? appWorkspaces
        floatWindows = try values.decodeIfPresent([FloatWindowRule].self, forKey: .floatWindows) ?? floatWindows
        statusFormat = try values.decodeIfPresent(String.self, forKey: .statusFormat) ?? statusFormat
        statusTemplate = try values.decodeIfPresent(String.self, forKey: .statusTemplate)
        statusShowIcon = try values.decodeIfPresent(Bool.self, forKey: .statusShowIcon) ?? statusShowIcon
        workspaceCurrent = try values.decodeIfPresent(String.self, forKey: .workspaceCurrent) ?? workspaceCurrent
        workspaceOther = try values.decodeIfPresent(String.self, forKey: .workspaceOther) ?? workspaceOther
        statusFonts = try values.decodeIfPresent([String].self, forKey: .statusFonts) ?? statusFonts
        statusFontSize = try values.decodeIfPresent(Double.self, forKey: .statusFontSize) ?? statusFontSize
        statusCommands = try values.decodeIfPresent([StatusCommand].self, forKey: .statusCommands) ?? statusCommands
        spaceLabels = try values.decodeIfPresent([String].self, forKey: .spaceLabels) ?? spaceLabels
        workspaceIcons = try values.decodeIfPresent([String].self, forKey: .workspaceIcons) ?? workspaceIcons
        statusTextFile = try values.decodeIfPresent(String.self, forKey: .statusTextFile)
        statusStateFile = try values.decodeIfPresent(String.self, forKey: .statusStateFile)
    }

    func validate() throws {
        let data = try JSONEncoder().encode(self)
        let jsonStr = String(data: data, encoding: .utf8) ?? "{}"
        var errPtr: UnsafeMutablePointer<CChar>?
        let ok = jsonStr.withCString { cJson in
            talus_config_validate_json(cJson, &errPtr)
        }
        defer { if let errPtr { talus_string_free(errPtr) } }
        guard ok else {
            let msg = errPtr.map { String(cString: $0) } ?? "invalid configuration"
            throw ConfigError(rawValue: msg) ?? ConfigParseError(msg)
        }
    }

    private struct WireConfigResolution: Decodable {
        let loadPath: String
        let savePath: String
        let migratedFromJson: Bool
    }

    static func resolvePaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ConfigResolution {
        let candidates = [
            homeDirectory.appendingPathComponent(".talus.toml").path,
            homeDirectory.appendingPathComponent(".config/talus/config.toml").path,
            homeDirectory.appendingPathComponent("Library/Application Support/Talus/config.toml").path,
            homeDirectory.appendingPathComponent("Library/Application Support/Talus/config.json").path,
        ]
        let existing = candidates.filter(fileExists)
        let existingJSON = (try? String(data: JSONEncoder().encode(existing), encoding: .utf8)) ?? "[]"
        let envVal = environment["TALUS_CONFIG"]
        let resPtr: UnsafeMutablePointer<CChar>? = homeDirectory.path.withCString { cHome in
            existingJSON.withCString { cExisting in
                if let envVal {
                    return envVal.withCString { cEnv in
                        talus_resolve_paths_json(cHome, cEnv, cExisting)
                    }
                }
                return talus_resolve_paths_json(cHome, nil, cExisting)
            }
        }
        defer { if let resPtr { talus_string_free(resPtr) } }
        if let resPtr,
           let data = String(cString: resPtr).data(using: .utf8),
           let decoded = try? JSONDecoder().decode(WireConfigResolution.self, from: data) {
            return ConfigResolution(
                loadURL: URL(fileURLWithPath: decoded.loadPath),
                saveURL: URL(fileURLWithPath: decoded.savePath),
                migratedFromJSON: decoded.migratedFromJson
            )
        }
        let fallback = homeDirectory.appendingPathComponent(".talus.toml")
        return ConfigResolution(loadURL: fallback, saveURL: fallback, migratedFromJSON: false)
    }

    static func load(from url: URL) throws -> Configuration {
        var errPtr: UnsafeMutablePointer<CChar>?
        let resPtr = url.path.withCString { cPath in
            talus_config_load_path_json(cPath, &errPtr)
        }
        defer {
            if let errPtr { talus_string_free(errPtr) }
            if let resPtr { talus_string_free(resPtr) }
        }
        guard let resPtr else {
            let msg = errPtr.map { String(cString: $0) } ?? "configuration load failed"
            throw ConfigError(rawValue: msg) ?? ConfigParseError(msg)
        }
        guard let data = String(cString: resPtr).data(using: .utf8) else {
            throw ConfigParseError("invalid UTF-8 from core")
        }
        return try JSONDecoder().decode(Configuration.self, from: data)
    }

    func save(to url: URL) throws {
        try validate()
        let data = try JSONEncoder().encode(self)
        let jsonStr = String(data: data, encoding: .utf8) ?? "{}"
        var errPtr: UnsafeMutablePointer<CChar>?
        let ok = jsonStr.withCString { cJson in
            url.path.withCString { cPath in
                talus_config_save_path_json(cJson, cPath, &errPtr)
            }
        }
        defer { if let errPtr { talus_string_free(errPtr) } }
        guard ok else {
            let msg = errPtr.map { String(cString: $0) } ?? "configuration save failed"
            throw ConfigError(rawValue: msg) ?? ConfigParseError(msg)
        }
    }

    static func decodeTOML(_ source: String) throws -> Configuration {
        var errPtr: UnsafeMutablePointer<CChar>?
        let resPtr = source.withCString { cSrc in
            talus_config_decode_toml_json(cSrc, &errPtr)
        }
        defer {
            if let errPtr { talus_string_free(errPtr) }
            if let resPtr { talus_string_free(resPtr) }
        }
        guard let resPtr else {
            let msg = errPtr.map { String(cString: $0) } ?? "TOML decode error"
            throw ConfigError(rawValue: msg) ?? ConfigParseError(msg)
        }
        guard let data = String(cString: resPtr).data(using: .utf8) else {
            throw ConfigParseError("invalid UTF-8 from core")
        }
        return try JSONDecoder().decode(Configuration.self, from: data)
    }

    func toTOML(existingTOML: String? = nil) -> String {
        guard let data = try? JSONEncoder().encode(self),
              let jsonStr = String(data: data, encoding: .utf8)
        else { return "" }
        var errPtr: UnsafeMutablePointer<CChar>?
        let resPtr: UnsafeMutablePointer<CChar>? = jsonStr.withCString { cJson in
            if let existingTOML {
                return existingTOML.withCString { cExisting in
                    talus_config_to_toml(cJson, cExisting, &errPtr)
                }
            }
            return talus_config_to_toml(cJson, nil, &errPtr)
        }
        defer {
            if let errPtr { talus_string_free(errPtr) }
            if let resPtr { talus_string_free(resPtr) }
        }
        return resPtr.map { String(cString: $0) } ?? ""
    }
}

struct ConfigParseError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum ConfigError: String, Error, CustomStringConvertible {
    case invalidModifiers = "modifiers must be distinct control, option or command names"
    case invalidWorkspaceMode = "workspaceMode must be 'native' or 'virtual'"
    case invalidWorkspaceCount = "workspaceCount must be between 1 and 9"
    case invalidAppWorkspace = "appWorkspaces entries must map non-empty bundle IDs to workspace 1..9 or a valid label"
    case invalidFloatRule = "floatWindows entries must specify a non-empty app bundle ID and at most 32 title patterns"
    case invalidRatio = "masterRatio must be between 0.2 and 0.8"
    case invalidStep = "ratioStep must be greater than 0 and at most 0.2"
    case invalidStatusCommand = "invalid status command: check name, executable, arguments, interval and timeout"
    case conflictingStatusFiles = "statusTextFile and statusStateFile must be different files"
    case invalidStatusFormat = "invalid status template, workspace format, labels or fonts"
    case invalidCount = "masterCount must be between 1 and 20"
    var description: String { rawValue }
}
