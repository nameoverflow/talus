import Foundation

private struct WireParseMarkupRequest: Encodable {
    let source: String
    let fonts: [String]
    let fontSize: Double
    let initial: StatusSegmentStyle?
    let current: Bool
    let workspaceIndex: Int?
}

private struct WireTemplateStatusRequest: Encodable {
    let config: Configuration
    let values: StatusValues
    let commandOutputs: [String]
}

func parseStatusMarkup(
    _ source: String,
    fonts: [String],
    fontSize: Double,
    initial: StatusSegmentStyle? = nil,
    current: Bool = false,
    workspaceIndex: Int? = nil
) -> [StatusPart] {
    let req = WireParseMarkupRequest(
        source: source,
        fonts: fonts,
        fontSize: fontSize,
        initial: initial,
        current: current,
        workspaceIndex: workspaceIndex
    )
    guard let data = try? JSONEncoder().encode(req),
          let jsonStr = String(data: data, encoding: .utf8)
    else { return [] }
    let resPtr = jsonStr.withCString { cJson in
        talus_parse_status_markup_json(cJson)
    }
    defer { if let resPtr { talus_string_free(resPtr) } }
    guard let resPtr,
          let outData = String(cString: resPtr).data(using: .utf8),
          let parts = try? JSONDecoder().decode([StatusPart].self, from: outData)
    else { return [] }
    return parts
}

func templateStatusParts(
    config: Configuration,
    values: StatusValues,
    commandOutput: (Int) -> String = { _ in "" }
) -> [StatusPart] {
    let outputs = config.statusCommands.indices.map { commandOutput($0) }
    let req = WireTemplateStatusRequest(
        config: config,
        values: values,
        commandOutputs: outputs
    )
    guard let data = try? JSONEncoder().encode(req),
          let jsonStr = String(data: data, encoding: .utf8)
    else { return [] }
    let resPtr = jsonStr.withCString { cJson in
        talus_template_status_parts_json(cJson)
    }
    defer { if let resPtr { talus_string_free(resPtr) } }
    guard let resPtr,
          let outData = String(cString: resPtr).data(using: .utf8),
          let parts = try? JSONDecoder().decode([StatusPart].self, from: outData)
    else { return [] }
    return parts
}
