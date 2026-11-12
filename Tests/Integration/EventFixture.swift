import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.regular)
var windows: [NSWindow] = []
func openWindow(_ title: String) {
    let window = NSWindow(contentRect: NSRect(x:100,y:100,width:500,height:300), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
    window.title = title; window.makeKeyAndOrderFront(nil); windows.append(window)
}
openWindow("Event First")
app.activate(ignoringOtherApps:true)
let output = CommandLine.arguments[1]
DispatchQueue.main.asyncAfter(deadline:.now()+2) {
    let timestamp = String(Date().timeIntervalSince1970)
    try! timestamp.write(toFile:output,atomically:true,encoding:.utf8)
    openWindow("Event Second")
}
app.run()
