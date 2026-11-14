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

    /// Resolves to 0-based workspace index `0..<workspaceCount`, or nil if unmatched/out of range.
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
        guard let bundleID, bundleID == app else { return false }
        let normalizedTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exceptTitles, !exceptTitles.isEmpty {
            for ex in exceptTitles {
                let target = ex.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.matchesGlobOrExact(text: normalizedTitle, pattern: target) {
                    return false
                }
            }
        }
        if let titles, !titles.isEmpty {
            return titles.contains { pattern in
                let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                if p.contains("*") {
                    return Self.matchesGlob(text: normalizedTitle, pattern: p)
                }
                return p.isEmpty ? normalizedTitle.isEmpty : normalizedTitle.localizedCaseInsensitiveContains(p)
            }
        }
        return true
    }

    private static func matchesGlobOrExact(text: String, pattern: String) -> Bool {
        if pattern.contains("*") {
            return matchesGlob(text: text, pattern: pattern)
        }
        return text == pattern
    }

    private static func matchesGlob(text: String, pattern: String) -> Bool {
        let lowerText = Array(text.lowercased())
        let lowerPat = Array(pattern.lowercased())
        var ti = 0, pi = 0
        var starIdx = -1, matchIdx = 0
        while ti < lowerText.count {
            if pi < lowerPat.count && lowerPat[pi] == lowerText[ti] {
                pi += 1
                ti += 1
            } else if pi < lowerPat.count && lowerPat[pi] == "*" {
                starIdx = pi
                matchIdx = ti
                pi += 1
            } else if starIdx != -1 {
                pi = starIdx + 1
                matchIdx += 1
                ti = matchIdx
            } else {
                return false
            }
        }
        while pi < lowerPat.count && lowerPat[pi] == "*" {
            pi += 1
        }
        return pi == lowerPat.count
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
        let allowed = Set(["control", "option", "command"])
        guard !modifiers.isEmpty, Set(modifiers).count == modifiers.count, Set(modifiers).isSubset(of: allowed) else {
            throw ConfigError.invalidModifiers
        }
        guard workspaceMode == "native" || workspaceMode == "virtual" else {
            throw ConfigError.invalidWorkspaceMode
        }
        guard (1...9).contains(workspaceCount) else {
            throw ConfigError.invalidWorkspaceCount
        }
        guard appWorkspaces.count <= 64 else {
            throw ConfigError.invalidAppWorkspace
        }
        for (bundle, target) in appWorkspaces {
            let trimmed = bundle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, bundle == trimmed, bundle.count <= 200 else {
                throw ConfigError.invalidAppWorkspace
            }
            switch target {
            case .index(let n):
                guard (1...9).contains(n) else { throw ConfigError.invalidAppWorkspace }
            case .label(let s):
                guard !s.isEmpty, s.count <= 16 else { throw ConfigError.invalidAppWorkspace }
            }
        }
        guard floatWindows.count <= 64 else {
            throw ConfigError.invalidFloatRule
        }
        for rule in floatWindows {
            let trimmedApp = rule.app.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedApp.isEmpty, rule.app == trimmedApp, rule.app.count <= 200 else {
                throw ConfigError.invalidFloatRule
            }
            if let titles = rule.titles {
                guard titles.count <= 32, titles.allSatisfy({ $0.count <= 200 }) else {
                    throw ConfigError.invalidFloatRule
                }
            }
            if let exceptTitles = rule.exceptTitles {
                guard exceptTitles.count <= 32, exceptTitles.allSatisfy({ $0.count <= 200 }) else {
                    throw ConfigError.invalidFloatRule
                }
            }
        }
        guard masterRatio >= 0.2 && masterRatio <= 0.8 else { throw ConfigError.invalidRatio }
        guard ratioStep > 0 && ratioStep <= 0.2 else { throw ConfigError.invalidStep }
        guard spaceLabels.count <= 32, spaceLabels.allSatisfy({ !$0.isEmpty && $0.count <= 16 }),
              workspaceIcons.count <= 32, workspaceIcons.allSatisfy({ !$0.isEmpty && $0.count <= 64 }),
              (statusTemplate?.count ?? 0) <= 1024, workspaceCurrent.count <= 512, workspaceOther.count <= 512,
              statusFonts.count <= 16, statusFonts.allSatisfy({ !$0.isEmpty && $0.count <= 100 }),
              (8...14).contains(statusFontSize), statusCommands.count <= 16,
              Set(statusCommands.map(\.name)).count == statusCommands.count
        else { throw ConfigError.invalidStatusFormat }
        for command in statusCommands { try command.validate() }
        guard statusFormat.count <= 160 else { throw ConfigError.invalidStatusFormat }
        if let input = statusTextFile, let output = statusStateFile, !input.isEmpty, !output.isEmpty {
            let a = (input as NSString).expandingTildeInPath as NSString
            let b = (output as NSString).expandingTildeInPath as NSString
            guard a.standardizingPath != b.standardizingPath else { throw ConfigError.conflictingStatusFiles }
        }
        guard (1...20).contains(masterCount) else { throw ConfigError.invalidCount }
    }

    /// Resolves configuration file location in priority order:
    /// 1. `TALUS_CONFIG` environment variable (when set)
    /// 2. `~/.talus.toml` (primary home dotfile)
    /// 3. `~/.config/talus/config.toml` (XDG dotfile directory)
    /// 4. `~/Library/Application Support/Talus/config.toml`
    /// 5. `~/Library/Application Support/Talus/config.json` (legacy JSON fallback; saving migrates to `~/.talus.toml`)
    static func resolvePaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ConfigResolution {
        if let custom = environment["TALUS_CONFIG"], !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return ConfigResolution(loadURL: url, saveURL: url, migratedFromJSON: false)
        }
        let dotfile = homeDirectory.appendingPathComponent(".talus.toml")
        let xdg = homeDirectory.appendingPathComponent(".config/talus/config.toml")
        let supportTOML = homeDirectory.appendingPathComponent("Library/Application Support/Talus/config.toml")
        let supportJSON = homeDirectory.appendingPathComponent("Library/Application Support/Talus/config.json")

        if fileExists(dotfile.path) {
            return ConfigResolution(loadURL: dotfile, saveURL: dotfile, migratedFromJSON: false)
        }
        if fileExists(xdg.path) {
            return ConfigResolution(loadURL: xdg, saveURL: xdg, migratedFromJSON: false)
        }
        if fileExists(supportTOML.path) {
            return ConfigResolution(loadURL: supportTOML, saveURL: supportTOML, migratedFromJSON: false)
        }
        if fileExists(supportJSON.path) {
            return ConfigResolution(loadURL: supportJSON, saveURL: dotfile, migratedFromJSON: true)
        }
        return ConfigResolution(loadURL: dotfile, saveURL: dotfile, migratedFromJSON: false)
    }

    static func load(from url: URL) throws -> Configuration {
        if !FileManager.default.fileExists(atPath: url.path) { return Configuration() }
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let result: Configuration
        if ext == "json" {
            result = try JSONDecoder().decode(Configuration.self, from: data)
        } else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw ConfigParseError("configuration file is not valid UTF-8")
            }
            result = try decodeTOML(text)
        }
        try result.validate()
        return result
    }

    func save(to url: URL) throws {
        try validate()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if url.pathExtension.lowercased() == "json" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } else {
            let text = toTOML()
            guard let data = text.data(using: .utf8) else {
                throw ConfigParseError("failed to encode TOML as UTF-8")
            }
            try data.write(to: url, options: .atomic)
        }
    }

    static func decodeTOML(_ source: String) throws -> Configuration {
        let root = try TOMLParser.parse(source)
        var config = Configuration()
        var seen: Set<String> = []

        func claim(_ canonical: String, keyLabel: String) throws {
            if seen.contains(canonical) {
                throw ConfigParseError("duplicate setting '\(keyLabel)'")
            }
            seen.insert(canonical)
        }

        func requireString(_ val: TOMLValue, key: String) throws -> String {
            guard let s = val.stringValue else { throw ConfigParseError("'\(key)' must be a string") }
            return s
        }
        func requireBool(_ val: TOMLValue, key: String) throws -> Bool {
            guard let b = val.boolValue else { throw ConfigParseError("'\(key)' must be true or false") }
            return b
        }
        func requireInt(_ val: TOMLValue, key: String) throws -> Int {
            guard let i = val.intValue else { throw ConfigParseError("'\(key)' must be an integer") }
            return i
        }
        func requireDouble(_ val: TOMLValue, key: String) throws -> Double {
            guard let d = val.doubleValue else { throw ConfigParseError("'\(key)' must be a number") }
            return d
        }
        func requireStringArray(_ val: TOMLValue, key: String) throws -> [String] {
            guard let arr = val.arrayValue else { throw ConfigParseError("'\(key)' must be an array of strings") }
            return try arr.map { elem in
                guard let s = elem.stringValue else { throw ConfigParseError("every item in '\(key)' must be a string") }
                return s
            }
        }
        func parseCommand(_ val: TOMLValue, prefix: String) throws -> StatusCommand {
            guard let table = val.tableValue else {
                throw ConfigParseError("'\(prefix)' entry must be a table")
            }
            var name: String?
            var executable: String?
            var arguments: [String]?
            var interval: Double?
            var timeout: Double?
            var markup: Bool?
            var onChange: Bool?
            var cmdSeen: Set<String> = []

            for (k, v) in table {
                switch k {
                case "name":
                    name = try requireString(v, key: "\(prefix).name")
                case "executable":
                    executable = try requireString(v, key: "\(prefix).executable")
                case "arguments", "args":
                    if !cmdSeen.insert("arguments").inserted { throw ConfigParseError("duplicate '\(prefix).\(k)'") }
                    arguments = try requireStringArray(v, key: "\(prefix).\(k)")
                case "interval":
                    interval = try requireDouble(v, key: "\(prefix).interval")
                case "timeout":
                    timeout = try requireDouble(v, key: "\(prefix).timeout")
                case "markup":
                    markup = try requireBool(v, key: "\(prefix).markup")
                case "on_change", "onChange":
                    if !cmdSeen.insert("onChange").inserted { throw ConfigParseError("duplicate '\(prefix).\(k)'") }
                    onChange = try requireBool(v, key: "\(prefix).\(k)")
                default:
                    throw ConfigParseError("unknown command key '\(prefix).\(k)'")
                }
            }
            guard let finalName = name else { throw ConfigParseError("'\(prefix)' is missing 'name'") }
            guard let finalExec = executable else { throw ConfigParseError("'\(prefix)' is missing 'executable'") }
            return StatusCommand(
                name: finalName,
                executable: finalExec,
                arguments: arguments,
                interval: interval,
                timeout: timeout,
                markup: markup,
                onChange: onChange
            )
        }
        func parseCommandList(_ val: TOMLValue, key: String) throws -> [StatusCommand] {
            guard let arr = val.arrayValue else { throw ConfigParseError("'\(key)' must be an array of tables") }
            return try arr.enumerated().map { idx, item in
                try parseCommand(item, prefix: "\(key)[\(idx)]")
            }
        }
        func parseAppWorkspaces(_ val: TOMLValue, key: String) throws -> [String: WorkspaceTarget] {
            guard let table = val.tableValue else {
                throw ConfigParseError("'\(key)' must be a table mapping bundle IDs to workspace number or name")
            }
            var out: [String: WorkspaceTarget] = [:]
            for (bundle, rawTarget) in table {
                if let n = rawTarget.intValue {
                    out[bundle] = .index(n)
                } else if let s = rawTarget.stringValue {
                    out[bundle] = .label(s)
                } else {
                    throw ConfigParseError("'\(key).\(bundle)' must be an integer (1..9) or workspace label string")
                }
            }
            return out
        }
        func parseFloatRule(_ val: TOMLValue, prefix: String) throws -> FloatWindowRule {
            guard let table = val.tableValue else {
                throw ConfigParseError("'\(prefix)' entry must be a table")
            }
            var app: String?
            var titles: [String]?
            var exceptTitles: [String]?
            var ruleSeen: Set<String> = []
            for (k, v) in table {
                switch k {
                case "app", "bundle_id", "bundleId":
                    if !ruleSeen.insert("app").inserted { throw ConfigParseError("duplicate '\(prefix).\(k)'") }
                    app = try requireString(v, key: "\(prefix).\(k)")
                case "titles":
                    if !ruleSeen.insert("titles").inserted { throw ConfigParseError("duplicate '\(prefix).\(k)'") }
                    titles = try requireStringArray(v, key: "\(prefix).\(k)")
                case "except_titles", "exceptTitles":
                    if !ruleSeen.insert("exceptTitles").inserted { throw ConfigParseError("duplicate '\(prefix).\(k)'") }
                    exceptTitles = try requireStringArray(v, key: "\(prefix).\(k)")
                default:
                    throw ConfigParseError("unknown float rule key '\(prefix).\(k)'")
                }
            }
            guard let finalApp = app else { throw ConfigParseError("'\(prefix)' is missing 'app'") }
            return FloatWindowRule(app: finalApp, titles: titles, exceptTitles: exceptTitles)
        }
        func parseFloatRuleList(_ val: TOMLValue, key: String) throws -> [FloatWindowRule] {
            guard let arr = val.arrayValue else { throw ConfigParseError("'\(key)' must be an array of tables") }
            return try arr.enumerated().map { idx, item in
                try parseFloatRule(item, prefix: "\(key)[\(idx)]")
            }
        }

        for (key, value) in root {
            switch key {
            case "modifiers":
                try claim("modifiers", keyLabel: key)
                config.modifiers = try requireStringArray(value, key: key)
            case "workspace_mode", "workspaceMode":
                try claim("workspaceMode", keyLabel: key)
                config.workspaceMode = try requireString(value, key: key)
            case "workspace_count", "workspaceCount":
                try claim("workspaceCount", keyLabel: key)
                config.workspaceCount = try requireInt(value, key: key)
            case "master_ratio", "masterRatio":
                try claim("masterRatio", keyLabel: key)
                config.masterRatio = try requireDouble(value, key: key)
            case "ratio_step", "ratioStep":
                try claim("ratioStep", keyLabel: key)
                config.ratioStep = try requireDouble(value, key: key)
            case "master_count", "masterCount":
                try claim("masterCount", keyLabel: key)
                config.masterCount = try requireInt(value, key: key)
            case "ignore_apps", "ignoreApps":
                try claim("ignoreApps", keyLabel: key)
                config.ignoreApps = try requireStringArray(value, key: key)
            case "app_workspaces", "appWorkspaces":
                try claim("appWorkspaces", keyLabel: key)
                config.appWorkspaces = try parseAppWorkspaces(value, key: key)
            case "float_windows", "floatWindows":
                try claim("floatWindows", keyLabel: key)
                config.floatWindows = try parseFloatRuleList(value, key: key)
            case "status_format", "statusFormat":
                try claim("statusFormat", keyLabel: key)
                config.statusFormat = try requireString(value, key: key)
            case "status_template", "statusTemplate":
                try claim("statusTemplate", keyLabel: key)
                config.statusTemplate = try requireString(value, key: key)
            case "status_show_icon", "statusShowIcon":
                try claim("statusShowIcon", keyLabel: key)
                config.statusShowIcon = try requireBool(value, key: key)
            case "workspace_current", "workspaceCurrent":
                try claim("workspaceCurrent", keyLabel: key)
                config.workspaceCurrent = try requireString(value, key: key)
            case "workspace_other", "workspaceOther":
                try claim("workspaceOther", keyLabel: key)
                config.workspaceOther = try requireString(value, key: key)
            case "status_fonts", "statusFonts":
                try claim("statusFonts", keyLabel: key)
                config.statusFonts = try requireStringArray(value, key: key)
            case "status_font_size", "statusFontSize":
                try claim("statusFontSize", keyLabel: key)
                config.statusFontSize = try requireDouble(value, key: key)
            case "space_labels", "spaceLabels":
                try claim("spaceLabels", keyLabel: key)
                config.spaceLabels = try requireStringArray(value, key: key)
            case "workspace_icons", "workspaceIcons":
                try claim("workspaceIcons", keyLabel: key)
                config.workspaceIcons = try requireStringArray(value, key: key)
            case "status_text_file", "statusTextFile":
                try claim("statusTextFile", keyLabel: key)
                config.statusTextFile = try requireString(value, key: key)
            case "status_state_file", "statusStateFile":
                try claim("statusStateFile", keyLabel: key)
                config.statusStateFile = try requireString(value, key: key)
            case "commands", "status_commands", "statusCommands":
                try claim("statusCommands", keyLabel: key)
                config.statusCommands = try parseCommandList(value, key: key)

            case "shortcuts", "keys":
                guard let sub = value.tableValue else { throw ConfigParseError("'\(key)' must be a table") }
                for (sk, sv) in sub {
                    switch sk {
                    case "modifiers":
                        try claim("modifiers", keyLabel: "\(key).\(sk)")
                        config.modifiers = try requireStringArray(sv, key: "\(key).\(sk)")
                    default:
                        throw ConfigParseError("unknown key '\(key).\(sk)'")
                    }
                }

            case "workspaces":
                guard let sub = value.tableValue else { throw ConfigParseError("'workspaces' must be a table") }
                for (sk, sv) in sub {
                    switch sk {
                    case "mode", "workspace_mode", "workspaceMode":
                        try claim("workspaceMode", keyLabel: "workspaces.\(sk)")
                        config.workspaceMode = try requireString(sv, key: "workspaces.\(sk)")
                    case "count", "workspace_count", "workspaceCount":
                        try claim("workspaceCount", keyLabel: "workspaces.\(sk)")
                        config.workspaceCount = try requireInt(sv, key: "workspaces.\(sk)")
                    case "labels", "space_labels", "spaceLabels":
                        try claim("spaceLabels", keyLabel: "workspaces.\(sk)")
                        config.spaceLabels = try requireStringArray(sv, key: "workspaces.\(sk)")
                    default:
                        throw ConfigParseError("unknown key 'workspaces.\(sk)'")
                    }
                }

            case "layout":
                guard let sub = value.tableValue else { throw ConfigParseError("'layout' must be a table") }
                for (sk, sv) in sub {
                    switch sk {
                    case "master_ratio", "masterRatio":
                        try claim("masterRatio", keyLabel: "layout.\(sk)")
                        config.masterRatio = try requireDouble(sv, key: "layout.\(sk)")
                    case "ratio_step", "ratioStep":
                        try claim("ratioStep", keyLabel: "layout.\(sk)")
                        config.ratioStep = try requireDouble(sv, key: "layout.\(sk)")
                    case "master_count", "masterCount":
                        try claim("masterCount", keyLabel: "layout.\(sk)")
                        config.masterCount = try requireInt(sv, key: "layout.\(sk)")
                    default:
                        throw ConfigParseError("unknown key 'layout.\(sk)'")
                    }
                }

            case "rules":
                guard let sub = value.tableValue else { throw ConfigParseError("'rules' must be a table") }
                for (sk, sv) in sub {
                    switch sk {
                    case "ignore_apps", "ignoreApps":
                        try claim("ignoreApps", keyLabel: "rules.\(sk)")
                        config.ignoreApps = try requireStringArray(sv, key: "rules.\(sk)")
                    case "app_workspaces", "appWorkspaces", "assign", "workspaces":
                        try claim("appWorkspaces", keyLabel: "rules.\(sk)")
                        config.appWorkspaces = try parseAppWorkspaces(sv, key: "rules.\(sk)")
                    case "float_windows", "floatWindows":
                        try claim("floatWindows", keyLabel: "rules.\(sk)")
                        config.floatWindows = try parseFloatRuleList(sv, key: "rules.\(sk)")
                    default:
                        throw ConfigParseError("unknown key 'rules.\(sk)'")
                    }
                }

            case "status":
                guard let sub = value.tableValue else { throw ConfigParseError("'status' must be a table") }
                for (sk, sv) in sub {
                    switch sk {
                    case "show_icon", "statusShowIcon":
                        try claim("statusShowIcon", keyLabel: "status.\(sk)")
                        config.statusShowIcon = try requireBool(sv, key: "status.\(sk)")
                    case "space_labels", "spaceLabels":
                        try claim("spaceLabels", keyLabel: "status.\(sk)")
                        config.spaceLabels = try requireStringArray(sv, key: "status.\(sk)")
                    case "workspace_icons", "workspaceIcons":
                        try claim("workspaceIcons", keyLabel: "status.\(sk)")
                        config.workspaceIcons = try requireStringArray(sv, key: "status.\(sk)")
                    case "template", "statusTemplate":
                        try claim("statusTemplate", keyLabel: "status.\(sk)")
                        config.statusTemplate = try requireString(sv, key: "status.\(sk)")
                    case "format", "statusFormat":
                        try claim("statusFormat", keyLabel: "status.\(sk)")
                        config.statusFormat = try requireString(sv, key: "status.\(sk)")
                    case "workspace_current", "workspaceCurrent":
                        try claim("workspaceCurrent", keyLabel: "status.\(sk)")
                        config.workspaceCurrent = try requireString(sv, key: "status.\(sk)")
                    case "workspace_other", "workspaceOther":
                        try claim("workspaceOther", keyLabel: "status.\(sk)")
                        config.workspaceOther = try requireString(sv, key: "status.\(sk)")
                    case "fonts", "statusFonts":
                        try claim("statusFonts", keyLabel: "status.\(sk)")
                        config.statusFonts = try requireStringArray(sv, key: "status.\(sk)")
                    case "font_size", "statusFontSize":
                        try claim("statusFontSize", keyLabel: "status.\(sk)")
                        config.statusFontSize = try requireDouble(sv, key: "status.\(sk)")
                    case "text_file", "statusTextFile":
                        try claim("statusTextFile", keyLabel: "status.\(sk)")
                        config.statusTextFile = try requireString(sv, key: "status.\(sk)")
                    case "state_file", "statusStateFile":
                        try claim("statusStateFile", keyLabel: "status.\(sk)")
                        config.statusStateFile = try requireString(sv, key: "status.\(sk)")
                    case "commands", "statusCommands":
                        try claim("statusCommands", keyLabel: "status.\(sk)")
                        config.statusCommands = try parseCommandList(sv, key: "status.\(sk)")
                    default:
                        throw ConfigParseError("unknown key 'status.\(sk)'")
                    }
                }

            default:
                throw ConfigParseError("unknown configuration key '\(key)'")
            }
        }
        return config
    }

    func toTOML() -> String {
        let defaults = Configuration()
        var lines: [String] = []
        lines.append("# Talus configuration (~/.talus.toml)")
        lines.append("modifiers = \(TOMLWriter.stringArray(modifiers))")
        let hasWorkspacesSection = workspaceMode != defaults.workspaceMode || workspaceCount != defaults.workspaceCount
        if hasWorkspacesSection {
            lines.append("")
            lines.append("[workspaces]")
            lines.append("mode = \(TOMLWriter.quote(workspaceMode))")
            lines.append("count = \(workspaceCount)")
            if !spaceLabels.isEmpty {
                lines.append("labels = \(TOMLWriter.stringArray(spaceLabels))")
            }
        }
        lines.append("")
        lines.append("[layout]")
        lines.append("master_ratio = \(TOMLWriter.formatFloat(masterRatio))")
        lines.append("ratio_step = \(TOMLWriter.formatFloat(ratioStep))")
        lines.append("master_count = \(masterCount)")

        if !ignoreApps.isEmpty {
            lines.append("")
            lines.append("[rules]")
            lines.append("ignore_apps = \(TOMLWriter.stringArray(ignoreApps))")
        }

        if !appWorkspaces.isEmpty {
            lines.append("")
            lines.append("[rules.app_workspaces]")
            for bundle in appWorkspaces.keys.sorted() {
                guard let target = appWorkspaces[bundle] else { continue }
                switch target {
                case .index(let n):
                    lines.append("\(TOMLWriter.quote(bundle)) = \(n)")
                case .label(let s):
                    lines.append("\(TOMLWriter.quote(bundle)) = \(TOMLWriter.quote(s))")
                }
            }
        }

        for rule in floatWindows {
            lines.append("")
            lines.append("[[rules.float_windows]]")
            lines.append("app = \(TOMLWriter.quote(rule.app))")
            if let titles = rule.titles {
                lines.append("titles = \(TOMLWriter.stringArray(titles))")
            }
            if let exceptTitles = rule.exceptTitles {
                lines.append("except_titles = \(TOMLWriter.stringArray(exceptTitles))")
            }
        }

        lines.append("")
        lines.append("[status]")
        lines.append("show_icon = \(statusShowIcon ? "true" : "false")")
        if !spaceLabels.isEmpty && !hasWorkspacesSection {
            lines.append("space_labels = \(TOMLWriter.stringArray(spaceLabels))")
        }
        if !workspaceIcons.isEmpty {
            lines.append("workspace_icons = \(TOMLWriter.stringArray(workspaceIcons))")
        }
        if let template = statusTemplate {
            lines.append("template = \(TOMLWriter.quote(template))")
        } else if statusFormat != defaults.statusFormat {
            lines.append("format = \(TOMLWriter.quote(statusFormat))")
        }
        if workspaceCurrent != defaults.workspaceCurrent || statusTemplate != nil {
            lines.append("workspace_current = \(TOMLWriter.quote(workspaceCurrent))")
        }
        if workspaceOther != defaults.workspaceOther || statusTemplate != nil {
            lines.append("workspace_other = \(TOMLWriter.quote(workspaceOther))")
        }
        if !statusFonts.isEmpty {
            lines.append("fonts = \(TOMLWriter.stringArray(statusFonts))")
        }
        if abs(statusFontSize - defaults.statusFontSize) > 0.0001 {
            lines.append("font_size = \(TOMLWriter.formatFloat(statusFontSize))")
        }
        if let textFile = statusTextFile {
            lines.append("text_file = \(TOMLWriter.quote(textFile))")
        }
        if let stateFile = statusStateFile {
            lines.append("state_file = \(TOMLWriter.quote(stateFile))")
        }

        for cmd in statusCommands {
            lines.append("")
            lines.append("[[status.commands]]")
            lines.append("name = \(TOMLWriter.quote(cmd.name))")
            lines.append("executable = \(TOMLWriter.quote(cmd.executable))")
            if let args = cmd.arguments {
                lines.append("arguments = \(TOMLWriter.stringArray(args))")
            }
            if let interval = cmd.interval {
                lines.append("interval = \(TOMLWriter.formatFloat(interval))")
            }
            if let timeout = cmd.timeout {
                lines.append("timeout = \(TOMLWriter.formatFloat(timeout))")
            }
            if let markup = cmd.markup {
                lines.append("markup = \(markup ? "true" : "false")")
            }
            if let onChange = cmd.onChange {
                lines.append("on_change = \(onChange ? "true" : "false")")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
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
