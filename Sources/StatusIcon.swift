import AppKit

/// A monochrome template image; AppKit applies the correct menu-bar tint.
func makeStatusIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setFill()
        func tile(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: 1.25, yRadius: 1.25).fill()
        }
        tile(1.5, 2, 7.75, 14)
        tile(10.5, 9.625, 6, 6.375)
        tile(10.5, 2, 6, 6.375)
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Talus"
    return image
}
