import AppKit
import CoreGraphics
import Darwin

struct SpaceEntry: Equatable, Codable {
    let id: UInt64
    let isCurrent: Bool
    let isFullscreen: Bool
    var windowCount: Int? = nil

    init(id: UInt64, isCurrent: Bool, isFullscreen: Bool, windowCount: Int? = nil) {
        self.id = id
        self.isCurrent = isCurrent
        self.isFullscreen = isFullscreen
        self.windowCount = windowCount
    }
}

/// SkyLight has no public equivalent for enumerating native Mission Control
/// Spaces. Resolve at runtime so unsupported macOS versions can fail safely.
final class NativeSpaces {
    typealias Connection = @convention(c) () -> UInt32
    typealias CopySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private let library: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let copySpaces: CopySpaces?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        library = handle
        if let handle, let symbol = dlsym(handle, "SLSMainConnectionID") {
            connection = unsafeBitCast(symbol, to: Connection.self)
        } else { connection = nil }
        if let handle, let symbol = dlsym(handle, "SLSCopyManagedDisplaySpaces") {
            copySpaces = unsafeBitCast(symbol, to: CopySpaces.self)
        } else { copySpaces = nil }
    }
    deinit { if let library { dlclose(library) } }

    func spaces(for screen: NSScreen?) -> [SpaceEntry]? {
        guard let connection, let copySpaces,
              let raw = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]], !raw.isEmpty else { return nil }
        let identifier: String? = screen.flatMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            return CFUUIDCreateString(nil, uuid) as String
        }
        let display = raw.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(identifier ?? "") == .orderedSame }
            ?? (raw.count == 1 ? raw.first : nil)
        guard let display else { return nil }
        return Self.parse(display)
    }

    static func parse(_ display: [String: Any]) -> [SpaceEntry]? {
        guard let current = display["Current Space"] as? [String: Any],
              let currentID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value,
              let raw = display["Spaces"] as? [[String: Any]] else { return nil }
        let entries = raw.compactMap { item -> SpaceEntry? in
            guard let id = (item["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                  let type = (item["type"] as? NSNumber)?.intValue, type == 0 || type == 4 else { return nil }
            return SpaceEntry(id: id, isCurrent: id == currentID, isFullscreen: type == 4)
        }
        guard !entries.isEmpty, entries.contains(where: \.isCurrent) else { return nil }
        return entries
    }
}
