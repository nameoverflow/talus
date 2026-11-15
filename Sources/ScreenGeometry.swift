import CoreGraphics
import Foundation

private func toCRect(_ r: CGRect) -> CTalusRect {
    CTalusRect(x: Double(r.origin.x), y: Double(r.origin.y), w: Double(r.size.width), h: Double(r.size.height))
}

func accessibilityFrame(visible: CGRect, primaryTop: CGFloat) -> CGRect {
    let r = talus_accessibility_frame(toCRect(visible), Double(primaryTop))
    return CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
}

func parkedWindowOrigin(windowSize: CGSize, screen: CGRect, allScreens: [CGRect] = []) -> CGPoint {
    let cScreens = allScreens.map(toCRect)
    var outX: Double = 0
    var outY: Double = 0
    cScreens.withUnsafeBufferPointer { buf in
        talus_parked_window_origin(
            Double(windowSize.width),
            Double(windowSize.height),
            toCRect(screen),
            buf.baseAddress,
            buf.count,
            &outX,
            &outY
        )
    }
    return CGPoint(x: outX, y: outY)
}

func isParkedWindowFrame(_ frame: CGRect, screen: CGRect) -> Bool {
    talus_is_parked_window_frame(toCRect(frame), toCRect(screen))
}

struct VisibleWindowCandidate {
    let pid: Int32
    let windowID: UInt32?
    let bounds: CGRect
}

private struct WireVisibleWindowCandidate: Encodable {
    let pid: Int32
    let window_id: UInt32?
    let bounds: WireRect
    struct WireRect: Encodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }
}

func matchesVisibleWindow(
    pid: Int32,
    axWindowID: UInt32?,
    axFrame: CGRect,
    candidates: [VisibleWindowCandidate]
) -> Bool {
    let wire = candidates.map {
        WireVisibleWindowCandidate(
            pid: $0.pid,
            window_id: $0.windowID,
            bounds: .init(
                x: Double($0.bounds.origin.x),
                y: Double($0.bounds.origin.y),
                w: Double($0.bounds.size.width),
                h: Double($0.bounds.size.height)
            )
        )
    }
    guard let jsonData = try? JSONEncoder().encode(wire),
          let jsonStr = String(data: jsonData, encoding: .utf8)
    else { return false }
    return jsonStr.withCString { cJson in
        talus_matches_visible_window(
            pid,
            axWindowID != nil,
            axWindowID ?? 0,
            toCRect(axFrame),
            cJson
        )
    }
}

func isSessionDictionaryLocked(_ session: [String: Any]?, frontmostBundleID: String?) -> Bool {
    let lockedNum = (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue
    let consoleNum = (session?["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue
    if let frontmostBundleID {
        return frontmostBundleID.withCString { cFront in
            talus_is_session_locked(
                lockedNum != nil,
                lockedNum ?? false,
                consoleNum != nil,
                consoleNum ?? true,
                cFront
            )
        }
    }
    return talus_is_session_locked(
        lockedNum != nil,
        lockedNum ?? false,
        consoleNum != nil,
        consoleNum ?? true,
        nil
    )
}
