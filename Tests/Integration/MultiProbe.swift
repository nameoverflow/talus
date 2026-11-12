import Cocoa
import ApplicationServices
func get(_ e: AXUIElement, _ key: CFString) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e,key,&v) == .success ? v : nil }
func rect(_ e: AXUIElement) -> CGRect? {
    guard let p = get(e,kAXPositionAttribute as CFString), let s = get(e,kAXSizeAttribute as CFString), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue,.cgPoint,&origin), AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }
    return CGRect(origin:origin,size:size)
}
var frames: [CGRect] = []
for argument in CommandLine.arguments.dropFirst() {
    let app = AXUIElementCreateApplication(pid_t(argument)!)
    guard let windows = get(app,kAXWindowsAttribute as CFString) as? [AXUIElement] else { fatalError("fixture unavailable") }
    for window in windows {
        guard let title = get(window,kAXTitleAttribute as CFString) as? String, title != "Talus Test Fixed", let frame = rect(window) else { continue }
        frames.append(frame)
    }
}
guard let screen = NSScreen.screens.first, frames.count == 4 else { fatalError("expected four resizable windows: \(frames)") }
let area = screen.visibleFrame
let areaSum = frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
guard abs(areaSum - area.width * area.height) < area.width * 5 else { fatalError("layout area mismatch: \(frames)") }
for i in frames.indices { for j in frames.indices where i < j {
    let intersection = frames[i].intersection(frames[j])
    guard intersection.isNull || intersection.width * intersection.height < 3 else { fatalError("windows overlap: \(frames)") }
} }
print("Four windows from two applications tiled without overlap")
