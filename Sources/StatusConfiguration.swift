import Foundation

enum StatusBoxType: String, Equatable {
    case full = "Full"
    case bottom = "Bottom"
    case top = "Top"
    case hBoth = "HBoth"
    case vBoth = "VBoth"
}

struct StatusBoxStyle: Equatable {
    var type: StatusBoxType = .full
    var width: Double = 2
    var color: String?
    var radius: Double?
}

/// Internal rendering style produced by the markup parser.
struct StatusSegmentStyle: Equatable {
    var foreground: String?
    var background: String?
    var font: String?
    var fontSize: Double?
    var dimmed: Bool = false
    var box: StatusBoxStyle?
}

struct StatusCommand: Codable, Equatable {
    var name: String
    var executable: String
    var arguments: [String]?
    var interval: Double?
    var timeout: Double?
    var markup: Bool?
    var onChange: Bool?

    init(
        name: String,
        executable: String,
        arguments: [String]? = nil,
        interval: Double? = nil,
        timeout: Double? = nil,
        markup: Bool? = nil,
        onChange: Bool? = nil
    ) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.interval = interval
        self.timeout = timeout
        self.markup = markup
        self.onChange = onChange
    }

    func validate() throws {
        let reserved = ["spaces", "layout", "title", "count", "custom", "label", "index", "fullscreen", "occupied"]
        guard name.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,31}$", options: .regularExpression) != nil,
              !reserved.contains(name), executable.hasPrefix("/"), executable.count <= 1024,
              (arguments?.count ?? 0) <= 32, (arguments ?? []).allSatisfy({ $0.count <= 1024 }),
              (1...3600).contains(interval ?? 10), (0.1...10).contains(timeout ?? 2)
        else { throw ConfigError.invalidStatusCommand }
    }
}
