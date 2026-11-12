import Cocoa
import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
func attribute(_ e: AXUIElement, _ name: CFString) -> CFTypeRef? { var out: CFTypeRef?; return AXUIElementCopyAttributeValue(e, name, &out) == .success ? out : nil }
func rect(_ e: AXUIElement) -> CGRect? {
    guard let p = attribute(e, kAXPositionAttribute as CFString), let s = attribute(e, kAXSizeAttribute as CFString), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin:origin,size:size)
}
guard let elements = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else { fatalError("fixture windows unavailable") }
var frames: [String:CGRect] = [:]
for window in elements { if let title = attribute(window, kAXTitleAttribute as CFString) as? String, let frame = rect(window) { frames[title] = frame } }
guard let a = frames["Talus Test A"], let b = frames["Talus Test B"], let fixed = frames["Talus Test Fixed"], let screen = NSScreen.screens.first else { fatalError("missing fixture windows") }
let area = screen.visibleFrame
func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a-b) < 3 }
guard close(a.width, area.width/2), close(b.width, area.width/2), close(a.height, area.height), close(b.height, area.height), close(abs(a.minX-b.minX), area.width/2), close(fixed.width, 500), fixed.height >= 300 && fixed.height <= 360 else { fatalError("unexpected layout: \(frames)") }
print("Two resizable windows tiled; fixed-size window preserved")
