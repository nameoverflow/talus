import Foundation
@main struct ConfigurationTests {
 static func main() throws {
    let d = JSONDecoder()
    let empty = try d.decode(Configuration.self, from: Data("{}".utf8)); try empty.validate()
    precondition(empty.modifiers == ["control", "option"] && empty.masterRatio == 0.5 && empty.masterCount == 1)
    let custom = try d.decode(Configuration.self, from: Data("{\"modifiers\":[\"command\"],\"masterRatio\":0.6,\"masterCount\":2,\"ignoreApps\":[\"com.example.app\"]}".utf8)); try custom.validate()
    precondition(custom.modifiers == ["command"] && custom.ignoreApps == ["com.example.app"])
    for json in ["{\"modifiers\":[]}", "{\"modifiers\":[\"shift\"]}", "{\"masterRatio\":0.9}", "{\"masterCount\":0}"] {
        let config = try d.decode(Configuration.self, from: Data(json.utf8))
        do { try config.validate(); fatalError("invalid config was accepted") } catch { }
    }
    print("Configuration tests passed")
 }
}
