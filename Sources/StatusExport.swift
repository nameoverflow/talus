import Foundation

struct StatusExport: Encodable {
    let spaces: [SpaceEntry]?
    let layout: String
    let title: String
    let count: Int
    let paused: Bool
}

func writeStatus(_ data: Data, to destination: URL) throws {
    var errPtr: UnsafeMutablePointer<CChar>?
    let ok = data.withUnsafeBytes { rawBuf in
        destination.path.withCString { cPath in
            let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return talus_write_atomic_0600(ptr, data.count, cPath, &errPtr)
        }
    }
    defer { if let errPtr { talus_string_free(errPtr) } }
    guard ok else {
        throw POSIXError(.EIO)
    }
}

func readCustomStatus(at path: String) -> String {
    let resPtr = path.withCString { cPath in
        talus_read_custom_status(cPath)
    }
    defer { if let resPtr { talus_string_free(resPtr) } }
    return resPtr.map { String(cString: $0) } ?? ""
}
