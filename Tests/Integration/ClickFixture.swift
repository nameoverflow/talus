import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSScreen.screens[0].visibleFrame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Talus External Click Target"
let content = window.contentView!
content.wantsLayer = true
content.layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.92, blue: 0.96, alpha: 1).cgColor
let label = NSTextField(labelWithString: "External app — keep keyboard focus")
label.font = .systemFont(ofSize: 28, weight: .semibold)
label.translatesAutoresizingMaskIntoConstraints = false
content.addSubview(label)
NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: content.centerXAnchor), label.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
