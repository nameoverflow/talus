import AppKit

// Talus's app mark: a master window and two stacked windows, drawn as vectors.
// Coordinates use a 1024-point square so the same drawing can scale cleanly.
let output = CommandLine.arguments[1]
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext
context.clear(CGRect(x: 0, y: 0, width: size, height: size))

func colour(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius)
}
func fillGradient(_ path: NSBezierPath, _ top: UInt32, _ bottom: UInt32, angle: CGFloat = 90) {
    NSGradient(starting: colour(bottom), ending: colour(top))!.draw(in: path, angle: angle)
}

// macOS-style rounded-square silhouette and a restrained midnight-blue depth.
let background = rounded(58, 58, 908, 908, 224)
fillGradient(background, 0x31495C, 0x172631, angle: 66)
context.saveGState()
background.addClip()
let glint = NSBezierPath()
glint.move(to: NSPoint(x: 40, y: 825))
glint.line(to: NSPoint(x: 1000, y: 1030))
glint.line(to: NSPoint(x: 1000, y: 775))
glint.line(to: NSPoint(x: 40, y: 570))
glint.close()
colour(0xFFFFFF, alpha: 0.035).setFill()
glint.fill()
context.restoreGState()
background.lineWidth = 3
colour(0xFFFFFF, alpha: 0.18).setStroke()
background.stroke()

// Dark keyline is part of the mark: it keeps the windows separate at Dock size.
let cluster = rounded(169, 184, 686, 656, 70)
colour(0x0A1924, alpha: 0.38).setFill()
cluster.fill()
let tiles: [(CGFloat, CGFloat, CGFloat, CGFloat, UInt32, UInt32)] = [
    (191, 207, 374, 610, 0xF9F4E8, 0xDEE5DB),
    (587, 523, 246, 294, 0xF0F0E6, 0xCEDBD4),
    (587, 207, 246, 294, 0xD6E6DD, 0xAFCBC2)
]
for (x, y, w, h, top, bottom) in tiles {
    let tile = rounded(x, y, w, h, 40)
    fillGradient(tile, top, bottom)
    tile.lineWidth = 2
    colour(0xFFFFFF, alpha: 0.62).setStroke()
    tile.stroke()
}
// A small terracotta accent marks the active master window.
let indicator = rounded(228, 757, 90, 17, 8.5)
colour(0xD37859).setFill()
indicator.fill()

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to render app icon") }
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
