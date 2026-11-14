import CoreGraphics
import Foundation

/// Convert Cocoa's bottom-left global coordinates into Accessibility's
/// top-left coordinates. The primary screen's top edge is the AX origin.
func accessibilityFrame(visible: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(x: visible.minX, y: primaryTop - visible.maxY, width: visible.width, height: visible.height)
}

/// Computes an off-screen corner origin in Accessibility coordinates that leaves
/// 1 pixel of the window inside `screen` without spilling onto adjacent displays.
func parkedWindowOrigin(windowSize: CGSize, screen: CGRect, allScreens: [CGRect] = []) -> CGPoint {
    let w = max(1, windowSize.width)
    let h = max(1, windowSize.height)
    let others = allScreens.filter { $0 != screen }

    let candidates: [(origin: CGPoint, spill: CGRect)] = [
        // Bottom-right corner (extends right and down)
        (
            CGPoint(x: screen.maxX - 1, y: screen.maxY - 1),
            CGRect(x: screen.maxX, y: screen.maxY - 40, width: w, height: h + 40)
        ),
        // Bottom-left corner (extends left and down)
        (
            CGPoint(x: screen.minX - w + 1, y: screen.maxY - 1),
            CGRect(x: screen.minX - w, y: screen.maxY - 40, width: w, height: h + 40)
        ),
        // Top-right corner (extends right)
        (
            CGPoint(x: screen.maxX - 1, y: screen.minY + 36),
            CGRect(x: screen.maxX, y: screen.minY, width: w, height: h + 36)
        ),
        // Top-left corner (extends left)
        (
            CGPoint(x: screen.minX - w + 1, y: screen.minY + 36),
            CGRect(x: screen.minX - w, y: screen.minY, width: w, height: h + 36)
        ),
    ]

    for candidate in candidates {
        if !others.contains(where: { $0.intersects(candidate.spill) }) {
            return candidate.origin
        }
    }
    return candidates[0].origin
}

/// Returns true when `frame` is parked at the 1px horizontal outer edge of `screen`.
/// Note: macOS clamps vertical window origins ~32pt above `screen.maxY`, so horizontal
/// overhang (`<= 3pt` visible on `screen`) is the reliable indicator.
func isParkedWindowFrame(_ frame: CGRect, screen: CGRect) -> Bool {
    guard screen.intersects(frame) else { return false }
    return frame.minX >= screen.maxX - 3 || frame.maxX <= screen.minX + 3
}

struct VisibleWindowCandidate {
    let pid: Int32
    let windowID: UInt32?
    let bounds: CGRect
}

/// Matches an Accessibility window against CoreGraphics on-screen layer-0 windows.
/// Prefers exact `CGWindowID` equality (immune to Qt/Electron custom frame discrepancies)
/// and falls back to 3pt frame tolerance when `axWindowID` is unavailable.
func matchesVisibleWindow(
    pid: Int32,
    axWindowID: UInt32?,
    axFrame: CGRect,
    candidates: [VisibleWindowCandidate]
) -> Bool {
    let validWid = (axWindowID != nil && axWindowID != 0) ? axWindowID : nil
    return candidates.contains { c in
        guard c.pid == pid else { return false }
        if let validWid, c.windowID == validWid {
            return true
        }
        return abs(c.bounds.minX - axFrame.minX) < 3
            && abs(c.bounds.minY - axFrame.minY) < 3
            && abs(c.bounds.width - axFrame.width) < 3
            && abs(c.bounds.height - axFrame.height) < 3
    }
}

/// Detects whether the current GUI login session is locked or switched off-console.
/// While locked, macOS hides app windows from `kAXWindowsAttribute`, so Talus must
/// freeze virtual workspace state instead of reconciling an empty window list.
func isSessionDictionaryLocked(_ session: [String: Any]?, frontmostBundleID: String?) -> Bool {
    if frontmostBundleID == "com.apple.loginwindow" {
        return true
    }
    if let locked = (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue, locked {
        return true
    }
    if let onConsole = (session?["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue, !onConsole {
        return true
    }
    return false
}
