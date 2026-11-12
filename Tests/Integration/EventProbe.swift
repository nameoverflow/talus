import Cocoa
import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!, file = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
let deadline = Date().addingTimeInterval(8)
var start: Double?
while Date() < deadline {
    if start == nil, let text = try? String(contentsOfFile:file,encoding:.utf8) { start = Double(text) }
    if let start {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(app,kAXWindowsAttribute as CFString,&v) == .success,
           let windows = v as? [AXUIElement], windows.count == 2, let screen = NSScreen.screens.first {
            let widths: [CGFloat] = windows.compactMap { w in
                var raw: CFTypeRef?; var size = CGSize.zero
                guard AXUIElementCopyAttributeValue(w,kAXSizeAttribute as CFString,&raw) == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetValue(raw as! AXValue,.cgSize,&size) else { return nil }
                return size.width
            }
            if widths.count == 2 && widths.allSatisfy({ abs($0-screen.visibleFrame.width/2) < 3 }) {
                let millis = (Date().timeIntervalSince1970-start)*1000
                print(String(format:"Window creation to two-window layout: %.0f ms",millis)); exit(0)
            }
        }
    }
    usleep(10_000)
}
fatalError("window creation did not settle within timeout")
