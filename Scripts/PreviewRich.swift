import AppKit
@main struct PreviewRich {
 static func main() throws {
    let entries = [SpaceEntry(id:1,isCurrent:false,isFullscreen:false),SpaceEntry(id:2,isCurrent:true,isFullscreen:false),SpaceEntry(id:3,isCurrent:false,isFullscreen:true),SpaceEntry(id:4,isCurrent:false,isFullscreen:false)]
    let canvas = NSImage(size:NSSize(width:820,height:300)); canvas.lockFocus()
    NSColor(srgbRed:0.93,green:0.94,blue:0.94,alpha:1).setFill(); NSBezierPath(rect:NSRect(x:0,y:0,width:820,height:300)).fill()
    func row(y:CGFloat,path:String,label:String) throws {
        let config = try Configuration.load(from:URL(fileURLWithPath:path))
        let values = StatusValues(spaces:entries,layout:"Tall",title:"Editor",count:3,custom:"",paused:false,spaceLabels:config.spaceLabels)
        let parts = templateStatusParts(config:config,values:values) { _ in "12:34" }
        NSColor(srgbRed:0.08,green:0.09,blue:0.12,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:30,y:y,width:760,height:92),xRadius:14,yRadius:14).fill()
        let icon = configuredStatusImage(parts:parts,dark:true)
        icon.draw(in:NSRect(x:55,y:y+28,width:icon.size.width*2,height:36))
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:16,weight:.medium),.foregroundColor:NSColor.white.withAlphaComponent(0.6)]
        (label as NSString).draw(at:NSPoint(x:560,y:y+36),withAttributes:attrs)
    }
    try row(y:172,path:"Examples/status-compact.json",label:"Example configuration A")
    try row(y:42,path:"Examples/status-powerline.json",label:"Example configuration B")
    canvas.unlockFocus()
    let bytes = NSBitmapImageRep(data:canvas.tiffRepresentation!)!.representation(using:.png,properties:[:])!
    try bytes.write(to:URL(fileURLWithPath:CommandLine.arguments[1]),options:.atomic)
 }
}
