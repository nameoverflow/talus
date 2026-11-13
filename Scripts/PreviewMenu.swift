import AppKit
@main struct PreviewMenu {
 static func main() throws {
    let screen = NSScreen.main ?? NSScreen.screens.first
    let values = StatusValues(spaces:NativeSpaces().spaces(for:screen), layout:"Tall", title:"", count:0, custom:"", paused:false)
    let image = NSImage(size:NSSize(width:720,height:96))
    image.lockFocus()
    NSColor(srgbRed:0.12,green:0.14,blue:0.18,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:0,y:0,width:720,height:96),xRadius:12,yRadius:12).fill()
    let icon = makeStatusIcon(); icon.isTemplate = false
    let tinted = NSImage(size:icon.size); tinted.lockFocus()
    icon.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1)
    NSColor.white.setFill(); NSRect(origin:.zero,size:icon.size).fill(using:.sourceAtop)
    tinted.unlockFocus(); tinted.draw(in:NSRect(x:24,y:30,width:36,height:36))
    let text = renderStatus("{spaces}  {layout}",values)
    let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:27,weight:.medium),.foregroundColor:NSColor.white]
    (text as NSString).draw(at:NSPoint(x:78,y:31),withAttributes:attributes)
    let systemAttributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:18,weight:.medium),.foregroundColor:NSColor.white]
    ("Wi-Fi     10:30" as NSString).draw(at:NSPoint(x:540,y:36),withAttributes:systemAttributes)
    image.unlockFocus()
    let data = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
    try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]),options:.atomic)
 }
}
