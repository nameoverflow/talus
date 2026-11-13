import Foundation

/// Internal rendering style produced by the markup parser.
struct StatusSegmentStyle: Equatable {
    var foreground: String?
    var background: String?
    var font: String?
    var fontSize: Double?
}

struct StatusCommand: Decodable {
    var name: String
    var executable: String
    var arguments: [String]?
    var interval: Double?
    var timeout: Double?
    var markup: Bool?
    var onChange: Bool?

    func validate() throws {
        let reserved = ["spaces","layout","title","count","custom","label","index","fullscreen"]
        guard name.range(of:"^[A-Za-z][A-Za-z0-9_-]{0,31}$",options:.regularExpression) != nil,
              !reserved.contains(name), executable.hasPrefix("/"), executable.count <= 1024,
              (arguments?.count ?? 0) <= 32, (arguments ?? []).allSatisfy({ $0.count <= 1024 }),
              (1...3600).contains(interval ?? 10), (0.1...10).contains(timeout ?? 2) else { throw ConfigError.invalidStatusCommand }
    }
}
