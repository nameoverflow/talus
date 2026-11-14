import CoreGraphics

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
