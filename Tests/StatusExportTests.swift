import Foundation
@main struct StatusExportTests {
 static func main() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("talus-status-test-\(UUID())",isDirectory:true)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:dir) }
    let file = dir.appendingPathComponent("state.json")
    let first = Data("first".utf8), second = Data("second".utf8)
    try writeStatus(first,to:file); try writeStatus(second,to:file)
    let written = try Data(contentsOf:file)
    precondition(written == second)
    let permissions = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber
    precondition(permissions.intValue & 0o777 == 0o600)
    let custom = dir.appendingPathComponent("custom.txt")
    try "work\n".write(to:custom,atomically:true,encoding:.utf8)
    precondition(readCustomStatus(at:custom.path) == "work\n")
    precondition(readCustomStatus(at:dir.path) == "")
    print("Status export and custom text tests passed")
 }
}
