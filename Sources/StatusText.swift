import Foundation

struct StatusValues {
    let spaces: [SpaceEntry]?
    let layout: String
    let title: String
    let count: Int
    let custom: String
    let paused: Bool
    var spaceLabels: [String] = []
    var spaceIcons: [String] = []
}

func renderStatus(_ format: String, _ values: StatusValues) -> String {
    let spaces = values.spaces.map { entries in
        entries.enumerated().map { index, item in
            let label = index < values.spaceLabels.count ? values.spaceLabels[index] : String(index + 1)
            let number = label + (item.isFullscreen ? "•" : "")
            return item.isCurrent ? "[\(number)]" : number
        }.joined(separator: " ")
    } ?? "?"
    func clean(_ text: String, limit: Int) -> String {
        String(text.replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression).prefix(limit))
    }
    let tokens = ["{spaces}":spaces, "{layout}":values.paused ? "Paused" : values.layout,
                  "{title}":clean(values.title,limit:24), "{count}":String(values.count),
                  "{custom}":clean(values.custom,limit:48)]
    let regex = try! NSRegularExpression(pattern: "\\{(?:spaces|layout|title|count|custom)\\}")
    let whole = format as NSString
    let matches = regex.matches(in: format, range: NSRange(location: 0, length: whole.length))
    var result = ""; var cursor = 0
    for match in matches {
        result += whole.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        result += tokens[whole.substring(with: match.range)] ?? ""
        cursor = match.range.location + match.range.length
    }
    result += whole.substring(from: cursor)
    return clean(result, limit:160)
}
