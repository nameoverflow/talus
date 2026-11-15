import Foundation

struct StatusValues: Codable {
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
    guard let data = try? JSONEncoder().encode(values),
          let jsonStr = String(data: data, encoding: .utf8)
    else { return "" }
    let resPtr = format.withCString { cFmt in
        jsonStr.withCString { cJson in
            talus_render_status_json(cFmt, cJson)
        }
    }
    defer { if let resPtr { talus_string_free(resPtr) } }
    return resPtr.map { String(cString: $0) } ?? ""
}
