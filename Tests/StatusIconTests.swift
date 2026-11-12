import AppKit
@main struct StatusIconTests {
    static func main() {
        let image = makeStatusIcon()
        precondition(image.isTemplate && image.size == NSSize(width:18,height:18))
        let canvas = NSImage(size:image.size)
        canvas.lockFocus()
        image.isTemplate = false
        image.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1)
        canvas.unlockFocus()
        guard let data = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data:data) else { fatalError("status icon has no image data") }
        var ink = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            if let color = bitmap.colorAt(x:x,y:y), color.alphaComponent > 0.5 { ink += 1 }
        } }
        precondition(ink > 0 && ink < bitmap.pixelsWide * bitmap.pixelsHigh)
        print("Status icon template and transparency tests passed")
    }
}
