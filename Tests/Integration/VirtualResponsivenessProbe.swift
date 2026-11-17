import Cocoa
import ApplicationServices
import Carbon

let pid = pid_t(CommandLine.arguments[1])!
let stateURL = URL(fileURLWithPath: CommandLine.arguments[2])
let axApp = AXUIElementCreateApplication(pid)
let screen = NSScreen.screens[0].frame
func value(_ element: AXUIElement, _ attr: CFString) -> CFTypeRef? {
    var out: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attr, &out) == .success ? out : nil
}
func rect(_ element: AXUIElement) -> CGRect? {
    guard let p = value(element, kAXPositionAttribute as CFString),
          let s = value(element, kAXSizeAttribute as CFString),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &position)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: position, size: size)
}
func wait(_ label: String, timeout: TimeInterval = 3, _ condition: () -> Bool) {
    let until = Date().addingTimeInterval(timeout)
    while Date() < until {
        if condition() { return }
        usleep(5_000)
    }
    fatalError("Timed out: \(label)")
}
func currentWorkspace() -> Int? {
    guard let data = try? Data(contentsOf: stateURL),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let spaces = state["spaces"] as? [[String: Any]],
          let current = spaces.first(where: { $0["isCurrent"] as? Bool == true }) else { return nil }
    return current["id"] as? Int
}
func key(_ code: Int, shift: Bool = false) {
    var flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    if shift { flags.insert(.maskShift) }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(5_000)
    }
}
var windows: [String: AXUIElement] = [:]
wait("fixture windows") {
    if let elements = value(axApp, kAXWindowsAttribute as CFString) as? [AXUIElement] {
        for element in elements {
            if let title = value(element, kAXTitleAttribute as CFString) as? String { windows[title] = element }
        }
    }
    return windows["Talus Test A"] != nil && windows["Talus Test B"] != nil && windows["Talus Test Fixed"] != nil
}
let a = windows["Talus Test A"]!, b = windows["Talus Test B"]!, fixed = windows["Talus Test Fixed"]!
func parked(_ element: AXUIElement) -> Bool {
    guard let frame = rect(element) else { return false }
    return frame.minX >= screen.maxX - 3 || frame.maxX <= screen.minX + 3
}
func focus(_ element: AXUIElement) {
    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
}

func isFocused(_ element: AXUIElement) -> Bool {
    guard let focused = value(axApp, kAXFocusedWindowAttribute as CFString),
          CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
    return CFEqual(focused, element)
}
if CommandLine.arguments.contains("--restored") {
    wait("all parked windows restored") { !parked(a) && !parked(b) && !parked(fixed) }
    print("Quit restored every parked fixture window")
    exit(0)
}
wait("initial workspace") { currentWorkspace() == 1 }
focus(a)
usleep(100_000)
key(kVK_ANSI_2, shift: true)
wait("throw A to workspace 2") { parked(a) && currentWorkspace() == 1 }
key(kVK_ANSI_2)
wait("switch to A") { !parked(a) && parked(b) && currentWorkspace() == 2 && isFocused(a) }
usleep(20_000)
let activated = Date()
focus(b)
let focusTimeout = ProcessInfo.processInfo.environment["TALUS_FOCUS_TIMEOUT"].flatMap(Double.init) ?? 0.4
wait("confirmed focus allows immediate external switch", timeout: focusTimeout) { currentWorkspace() == 1 && !parked(b) }
let externalMs = Date().timeIntervalSince(activated) * 1000
var times: [Double] = []
for _ in 0..<10 {
    for (code, workspace) in [(kVK_ANSI_2, 2), (kVK_ANSI_1, 1)] {
        let start = Date()
        key(code)
        wait("workspace \(workspace)") {
            currentWorkspace() == workspace && (workspace == 2
                ? !parked(a) && parked(b) && isFocused(a)
                : parked(a) && !parked(b) && isFocused(b))
        }
        times.append(Date().timeIntervalSince(start) * 1000)
    }
}
let sorted = times.sorted()
print(String(format: "20 actual workspace switches: median %.1f ms; P95 %.1f ms", sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)]))
print(String(format: "External focus accepted %.1f ms after raising another workspace's window (20 ms after target confirmation)", externalMs))
precondition(abs(rect(fixed)!.width - 500) < 3, "Fixed-size window was resized")
print("Virtual throw/switch/focus and fixed-size preservation passed")
