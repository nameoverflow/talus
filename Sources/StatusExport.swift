import Foundation
import Darwin

struct StatusExport: Encodable {
    let spaces: [SpaceEntry]?
    let layout: String
    let title: String
    let count: Int
    let paused: Bool
}

/// Write a private file and atomically publish it, so readers never see a partial JSON document.
func writeStatus(_ data: Data, to destination: URL) throws {
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(".talus-status-\(UUID().uuidString)")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd); unlink(temporary.path) }
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let amount = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += amount
        }
    }
    guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

func readCustomStatus(at path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: expanded),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let length = attributes[.size] as? NSNumber, length.uint64Value <= 1_048_576,
          let handle = FileHandle(forReadingAtPath: expanded) else { return "" }
    defer { try? handle.close() }
    return String(data: (try? handle.read(upToCount: 4096)) ?? Data(), encoding: .utf8) ?? ""
}
