import CoreGraphics

/// Convert Cocoa's bottom-left global coordinates into Accessibility's
/// top-left coordinates. The primary screen's top edge is the AX origin.
func accessibilityFrame(visible: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(x: visible.minX, y: primaryTop - visible.maxY, width: visible.width, height: visible.height)
}
