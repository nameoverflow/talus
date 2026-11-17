import AppKit

// Compile with the same sources/core flags as rich-status-test, replacing its test entry point.
@main struct PreviewWorkspaceIndicators {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: preview-workspace-indicators <output-prefix> <revision-label>")
        }
        var config = Configuration()
        config.workspaceMode = "virtual"
        config.workspaceIcons = ["terminal", "globe", "chevron.left.forwardslash.chevron.right", "bubble.left.and.bubble.right", "square.grid.2x2"]
        config.statusTemplate = "%spaces% <fc=#80808066>│</fc>  <fc=#14B8A6>%layout%</fc> · %count%"
        config.workspaceCurrent = "<fc=#FFFFFF,#0F766E> %icon%%fullscreen% </fc>"
        config.workspaceOther = " %icon%%fullscreen% "
        let full: Set<Int> = [0, 1, 2, 4]
        for dark in [true, false] {
            let size = NSSize(width: 350, height: 230)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 700, pixelsHigh: 460,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let ink: NSColor = dark ? .white : .black
            (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 11) {
                (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: ink
                ])
            }
            label("\(CommandLine.arguments[2]) · \(dark ? "Dark" : "Light")", x: 16, y: 204, size: 14)
            label("Same Full states; focus moves across all five workspaces", x: 16, y: 185, size: 10)
            for active in 0..<5 {
                let spaces = (0..<5).map {
                    SpaceEntry(id: UInt64($0 + 1), isCurrent: $0 == active, isFullscreen: full.contains($0), windowCount: 1)
                }
                let values = StatusValues(spaces: spaces, layout: full.contains(active) ? "Full" : "Tall",
                    title: "", count: 1, custom: "", paused: false, spaceIcons: config.workspaceIcons)
                let output = renderConfiguredStatus(parts: templateStatusParts(config: config, values: values), dark: dark)
                let y = CGFloat(150 - active * 29)
                output.image.draw(at: NSPoint(x: 16, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                print("\(dark ? "dark" : "light") active=\(active + 1) widths=\(output.workspaceRegions.map { $0.rect.width })")
            }
            label("Full: 1, 2, 3, 5 · Tall: 4 · native renderer, 2× scale", x: 16, y: 13, size: 10)
            NSGraphicsContext.restoreGraphicsState()
            let path = "\(CommandLine.arguments[1])-\(dark ? "dark" : "light").png"
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
    }
}
