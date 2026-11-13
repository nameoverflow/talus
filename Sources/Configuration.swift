import Foundation

struct Configuration: Decodable {
    var modifiers: [String] = ["control", "option"]
    var masterRatio: Double = 0.5
    var ratioStep: Double = 0.03
    var masterCount: Int = 1
    var ignoreApps: [String] = []
    var statusFormat: String = "{spaces}  {layout}"
    var statusTextFile: String?
    var statusStateFile: String?

    private enum CodingKeys: String, CodingKey { case modifiers, masterRatio, ratioStep, masterCount, ignoreApps, statusFormat, statusTextFile, statusStateFile }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modifiers = try values.decodeIfPresent([String].self, forKey: .modifiers) ?? modifiers
        masterRatio = try values.decodeIfPresent(Double.self, forKey: .masterRatio) ?? masterRatio
        ratioStep = try values.decodeIfPresent(Double.self, forKey: .ratioStep) ?? ratioStep
        masterCount = try values.decodeIfPresent(Int.self, forKey: .masterCount) ?? masterCount
        ignoreApps = try values.decodeIfPresent([String].self, forKey: .ignoreApps) ?? ignoreApps
        statusFormat = try values.decodeIfPresent(String.self, forKey: .statusFormat) ?? statusFormat
        statusTextFile = try values.decodeIfPresent(String.self, forKey: .statusTextFile)
        statusStateFile = try values.decodeIfPresent(String.self, forKey: .statusStateFile)
    }
    func validate() throws {
        let allowed = Set(["control", "option", "command"])
        guard !modifiers.isEmpty, Set(modifiers).count == modifiers.count, Set(modifiers).isSubset(of: allowed) else { throw ConfigError.invalidModifiers }
        guard masterRatio >= 0.2 && masterRatio <= 0.8 else { throw ConfigError.invalidRatio }
        guard ratioStep > 0 && ratioStep <= 0.2 else { throw ConfigError.invalidStep }
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
    case conflictingStatusFiles = "statusTextFile and statusStateFile must be different files"
    case invalidStatusFormat = "statusFormat must be at most 160 characters"
    case invalidCount = "masterCount must be between 1 and 20"
    var description: String { rawValue }
}
