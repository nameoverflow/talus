import AppKit

@main struct PreviewIcons {
    static func main() throws {
        let output = CommandLine.arguments[1]
        let appIcon = NSImage(contentsOfFile: CommandLine.arguments[2])!
        let canvas = NSImage(size: NSSize(width: 960, height: 420))
        canvas.lockFocus()
        NSColor(srgbRed:0.94,green:0.95,blue:0.95,alpha:1).setFill()
        NSBezierPath(rect:NSRect(x:0,y:0,width:960,height:420)).fill()
        appIcon.draw(in:NSRect(x:45,y:50,width:320,height:320))
        let title = [NSAttributedString.Key.font:NSFont.systemFont(ofSize:20,weight:.semibold), .foregroundColor:NSColor(calibratedWhite:0.28,alpha:1)]
        ("App icon" as NSString).draw(at:NSPoint(x:145,y:26),withAttributes:title)
        func bar(_ rect: NSRect, dark: Bool) {
            let background = NSBezierPath(roundedRect:rect,xRadius:14,yRadius:14)
            (dark ? NSColor(srgbRed:0.10,green:0.12,blue:0.16,alpha:1) : NSColor.white).setFill()
            background.fill()
            let textColor = dark ? NSColor.white : NSColor(calibratedWhite:0.18,alpha:1)
            let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:20,weight:.medium), .foregroundColor:textColor]
            ((dark ? "Dark menu bar" : "Light menu bar") as NSString).draw(at:NSPoint(x:rect.minX+25,y:rect.midY-11),withAttributes:attrs)
            let icon = makeStatusIcon()
            // Tint exactly as an AppKit template image on this background.
            let target = NSRect(x:rect.maxX-86,y:rect.midY-27,width:54,height:54)
            icon.isTemplate = false
            if dark {
                let tinted = NSImage(size: icon.size)
                tinted.lockFocus()
                icon.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1)
                NSColor.white.setFill()
                NSRect(origin:.zero,size:icon.size).fill(using:.sourceAtop)
                tinted.unlockFocus()
                tinted.draw(in:target)
            } else {
                icon.draw(in:target)
            }
        }
        bar(NSRect(x:420,y:232,width:480,height:100),dark:false)
        bar(NSRect(x:420,y:88,width:480,height:100),dark:true)
        canvas.unlockFocus()
        let data = NSBitmapImageRep(data:canvas.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        try data.write(to:URL(fileURLWithPath:output),options:.atomic)
    }
}
