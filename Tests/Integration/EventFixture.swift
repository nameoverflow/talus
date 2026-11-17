import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.regular)
var windows: [NSWindow] = []
func openWindow(_ title: String) {
    let window = NSWindow(contentRect: NSRect(x:100,y:100,width:500,height:300), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
    window.title = title; window.makeKeyAndOrderFront(nil); windows.append(window)
    if let content = window.contentView {
        content.wantsLayer = true
        content.layer?.backgroundColor = (title == "Event First" ? NSColor.systemTeal : NSColor.systemBlue).withAlphaComponent(0.18).cgColor
        let label = NSTextField(labelWithString: title == "Event First" ? "First window" : "New window")
        label.font = .systemFont(ofSize: 30, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: content.centerXAnchor), label.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
    }
}
openWindow("Event First")
app.activate(ignoringOtherApps:true)
let output = CommandLine.arguments[1]
var openedSecond = false
Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
    guard !openedSecond, FileManager.default.fileExists(atPath: output + ".go") else { return }
    openedSecond = true
    timer.invalidate()
    let timestamp = String(Date().timeIntervalSince1970)
    try! timestamp.write(toFile:output,atomically:true,encoding:.utf8)
    openWindow("Event Second")
}
app.run()
