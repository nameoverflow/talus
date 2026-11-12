import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.regular)
var windows: [NSWindow] = []
let fixtures: [(String, NSWindow.StyleMask)] = [("Talus Test A", [.titled, .closable, .resizable]), ("Talus Test B", [.titled, .closable, .resizable]), ("Talus Test Fixed", [.titled, .closable])]
for (index, pair) in fixtures.enumerated() {
    let window = NSWindow(contentRect: NSRect(x: 100 + index * 90, y: 100, width: 500, height: 300), styleMask: pair.1, backing: .buffered, defer: false)
    window.title = pair.0
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
}
app.activate(ignoringOtherApps: true)
app.run()
