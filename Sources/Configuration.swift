import Foundation

struct Configuration: Decodable {
    var modifiers: [String] = ["control", "option"]
    var masterRatio: Double = 0.5
    var ratioStep: Double = 0.03
    var masterCount: Int = 1
    var ignoreApps: [String] = []
    var statusFormat: String = "{spaces}  {layout}"
    var statusTemplate: String?
    var statusShowIcon: Bool = true
    var workspaceCurrent: String = "<fc=#10201E,#89CFC2> %label%%fullscreen% </fc>"
    var workspaceOther: String = "%label%%fullscreen%"
    var statusFonts: [String] = []
    var statusFontSize: Double = 11.5
    var statusCommands: [StatusCommand] = []
    var spaceLabels: [String] = []
    var statusTextFile: String?
    var statusStateFile: String?

    private enum CodingKeys: String, CodingKey { case modifiers, masterRatio, ratioStep, masterCount, ignoreApps, statusFormat, statusTextFile, statusStateFile, statusTemplate, statusShowIcon, workspaceCurrent, workspaceOther, statusFonts, statusFontSize, statusCommands, spaceLabels }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modifiers = try values.decodeIfPresent([String].self, forKey: .modifiers) ?? modifiers
        masterRatio = try values.decodeIfPresent(Double.self, forKey: .masterRatio) ?? masterRatio
        ratioStep = try values.decodeIfPresent(Double.self, forKey: .ratioStep) ?? ratioStep
        masterCount = try values.decodeIfPresent(Int.self, forKey: .masterCount) ?? masterCount
        ignoreApps = try values.decodeIfPresent([String].self, forKey: .ignoreApps) ?? ignoreApps
        statusFormat = try values.decodeIfPresent(String.self, forKey: .statusFormat) ?? statusFormat
        statusTemplate = try values.decodeIfPresent(String.self, forKey: .statusTemplate)
        statusShowIcon = try values.decodeIfPresent(Bool.self, forKey: .statusShowIcon) ?? statusShowIcon
        workspaceCurrent = try values.decodeIfPresent(String.self, forKey: .workspaceCurrent) ?? workspaceCurrent
        workspaceOther = try values.decodeIfPresent(String.self, forKey: .workspaceOther) ?? workspaceOther
        statusFonts = try values.decodeIfPresent([String].self, forKey: .statusFonts) ?? statusFonts
        statusFontSize = try values.decodeIfPresent(Double.self, forKey: .statusFontSize) ?? statusFontSize
        statusCommands = try values.decodeIfPresent([StatusCommand].self, forKey: .statusCommands) ?? statusCommands
        spaceLabels = try values.decodeIfPresent([String].self, forKey: .spaceLabels) ?? spaceLabels
        statusTextFile = try values.decodeIfPresent(String.self, forKey: .statusTextFile)
        statusStateFile = try values.decodeIfPresent(String.self, forKey: .statusStateFile)
    }
    func validate() throws {
        let allowed = Set(["control", "option", "command"])
        guard !modifiers.isEmpty, Set(modifiers).count == modifiers.count, Set(modifiers).isSubset(of: allowed) else { throw ConfigError.invalidModifiers }
        guard masterRatio >= 0.2 && masterRatio <= 0.8 else { throw ConfigError.invalidRatio }
        guard ratioStep > 0 && ratioStep <= 0.2 else { throw ConfigError.invalidStep }
        guard spaceLabels.count <= 32, spaceLabels.allSatisfy({ !$0.isEmpty && $0.count <= 16 }),
              (statusTemplate?.count ?? 0) <= 1024, workspaceCurrent.count <= 512, workspaceOther.count <= 512,
              statusFonts.count <= 16, statusFonts.allSatisfy({ !$0.isEmpty && $0.count <= 100 }),
              (8...14).contains(statusFontSize), statusCommands.count <= 16,
              Set(statusCommands.map(\.name)).count == statusCommands.count else { throw ConfigError.invalidStatusFormat }
        for command in statusCommands { try command.validate() }
        guard statusFormat.count <= 160 else { throw ConfigError.invalidStatusFormat }
        if let input = statusTextFile, let output = statusStateFile, !input.isEmpty, !output.isEmpty {
            let a = (input as NSString).expandingTildeInPath as NSString
            let b = (output as NSString).expandingTildeInPath as NSString
            guard a.standardizingPath != b.standardizingPath else { throw ConfigError.conflictingStatusFiles }
        }
        guard (1...20).contains(masterCount) else { throw ConfigError.invalidCount }
    }
    static func load(from url: URL) throws -> Configuration {
        if !FileManager.default.fileExists(atPath: url.path) { return Configuration() }
        let result = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        try result.validate()
        return result
    }
}
enum ConfigError: String, Error, CustomStringConvertible {
    case invalidModifiers = "modifiers must be distinct control, option or command names"
    case invalidRatio = "masterRatio must be between 0.2 and 0.8"
    case invalidStep = "ratioStep must be greater than 0 and at most 0.2"
    case invalidStatusCommand = "invalid status command: check name, executable, arguments, interval and timeout"
    case conflictingStatusFiles = "statusTextFile and statusStateFile must be different files"
    case invalidStatusFormat = "invalid status template, workspace format, labels or fonts"
    case invalidCount = "masterCount must be between 1 and 20"
    var description: String { rawValue }
}
