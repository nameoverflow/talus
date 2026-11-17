import Cocoa
import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!, file = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
let deadline = Date().addingTimeInterval(8)
var start: Double?
var triggered = false
while Date() < deadline {
    if !triggered, let screen = NSScreen.screens.first {
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
           let windows = raw as? [AXUIElement], windows.count == 1 {
            var sizeValue: CFTypeRef?, size = CGSize.zero
            if AXUIElementCopyAttributeValue(windows[0], kAXSizeAttribute as CFString, &sizeValue) == .success,
               let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
               AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
               abs(size.width - screen.visibleFrame.width) < 3,
               abs(size.height - screen.visibleFrame.height) < 3 {
                try! "ready".write(toFile: file + ".ready", atomically: true, encoding: .utf8)
                if let delay = ProcessInfo.processInfo.environment["TALUS_PROBE_TRIGGER_DELAY"].flatMap(Double.init) {
                    usleep(useconds_t(delay * 1_000_000))
                }
                try! "go".write(toFile: file + ".go", atomically: true, encoding: .utf8)
                triggered = true
            }
        }
    }
    if start == nil, let text = try? String(contentsOfFile:file,encoding:.utf8) { start = Double(text) }
    if let start {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(app,kAXWindowsAttribute as CFString,&v) == .success,
           let windows = v as? [AXUIElement], windows.count == 2, let screen = NSScreen.screens.first {
            var frames: [String: CGRect] = [:]
            for window in windows {
                var title: CFTypeRef?, pos: CFTypeRef?, raw: CFTypeRef?
                var point = CGPoint.zero; var size = CGSize.zero
                guard AXUIElementCopyAttributeValue(window,kAXTitleAttribute as CFString,&title) == .success,
                      AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&pos) == .success,
                      AXUIElementCopyAttributeValue(window,kAXSizeAttribute as CFString,&raw) == .success,
                      let name = title as? String, let pos, let raw,
                      CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(raw) == AXValueGetTypeID(),
                      AXValueGetValue(pos as! AXValue,.cgPoint,&point), AXValueGetValue(raw as! AXValue,.cgSize,&size) else { continue }
                frames[name] = CGRect(origin:point,size:size)
            }
            if let first = frames["Event First"], let second = frames["Event Second"],
               abs(first.width-screen.visibleFrame.width/2) < 3,
               abs(second.width-screen.visibleFrame.width/2) < 3,
               second.minX < first.minX {
                let millis = (Date().timeIntervalSince1970-start)*1000
                print(String(format:"Window creation to two-window layout: %.0f ms; new window became master",millis)); exit(0)
            }
        }
    }
    usleep(10_000)
}
fatalError("window creation did not settle within timeout")
