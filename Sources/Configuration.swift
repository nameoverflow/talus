import Foundation

struct Configuration: Decodable {
    var modifiers: [String] = ["control", "option"]
    var masterRatio: Double = 0.5
    var masterCount: Int = 1
    var ignoreApps: [String] = []

    private enum CodingKeys: String, CodingKey { case modifiers, masterRatio, masterCount, ignoreApps }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modifiers = try values.decodeIfPresent([String].self, forKey: .modifiers) ?? modifiers
        masterRatio = try values.decodeIfPresent(Double.self, forKey: .masterRatio) ?? masterRatio
        masterCount = try values.decodeIfPresent(Int.self, forKey: .masterCount) ?? masterCount
        ignoreApps = try values.decodeIfPresent([String].self, forKey: .ignoreApps) ?? ignoreApps
    }
    func validate() throws {
        let allowed = Set(["control", "option", "command"])
        guard !modifiers.isEmpty, Set(modifiers).count == modifiers.count, Set(modifiers).isSubset(of: allowed) else { throw ConfigError.invalidModifiers }
        guard masterRatio >= 0.2 && masterRatio <= 0.8 else { throw ConfigError.invalidRatio }
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
    case invalidCount = "masterCount must be between 1 and 20"
    var description: String { rawValue }
}
