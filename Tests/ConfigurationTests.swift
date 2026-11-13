import Foundation
@main struct ConfigurationTests {
 static func main() throws {
    let d = JSONDecoder()
    let empty = try d.decode(Configuration.self, from: Data("{}".utf8)); try empty.validate()
    precondition(empty.modifiers == ["control", "option"] && empty.masterRatio == 0.5 && empty.ratioStep == 0.03 && empty.masterCount == 1)
    precondition(empty.statusFormat == "{spaces}  {layout}" && empty.statusTextFile == nil && empty.statusStateFile == nil)
    let custom = try d.decode(Configuration.self, from: Data("{\"modifiers\":[\"command\"],\"masterRatio\":0.6,\"masterCount\":2,\"ignoreApps\":[\"com.example.app\"]}".utf8)); try custom.validate()
    precondition(custom.modifiers == ["command"] && custom.ignoreApps == ["com.example.app"])
    for json in ["{\"modifiers\":[]}", "{\"modifiers\":[\"shift\"]}", "{\"masterRatio\":0.9}", "{\"masterCount\":0}", "{\"ratioStep\":0}"] {
        let config = try d.decode(Configuration.self, from: Data(json.utf8))
        do { try config.validate(); fatalError("invalid config was accepted") } catch { }
    }
    var collision = Configuration(); collision.statusTextFile = "/tmp/talus/x/../status"; collision.statusStateFile = "/tmp/talus/status"
    do { try collision.validate(); fatalError("same input and output accepted") } catch { }
    var long = Configuration(); long.statusFormat = String(repeating:"x",count:161)
    do { try long.validate(); fatalError("long format accepted") } catch { }
    print("Configuration tests passed")
 }
}
