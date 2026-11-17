import Foundation
import CoreGraphics
import Darwin

/// Bounds are read from WindowServer, without asking a potentially stalled app
/// to service AXPosition/AXSize. This never mutates the server-side geometry.
final class WindowServerFrames {
    static let shared = WindowServerFrames()
    typealias Connection = @convention(c) () -> Int32
    typealias Bounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let bounds: Bounds?

    private init() {
        let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        self.library = library
        connection = library.flatMap { dlsym($0, "SLSMainConnectionID") }.map { unsafeBitCast($0, to: Connection.self) }
        bounds = library.flatMap { dlsym($0, "SLSGetWindowBounds") }.map { unsafeBitCast($0, to: Bounds.self) }
    }

    deinit { if let library { dlclose(library) } }

    func frame(_ windowID: UInt32) -> CGRect? {
        guard windowID != 0, let connection, let bounds else { return nil }
        var rect = CGRect.zero
        guard bounds(connection(), windowID, &rect) == 0,
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }
}
