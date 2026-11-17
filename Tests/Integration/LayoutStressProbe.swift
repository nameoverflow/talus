import Cocoa
import ApplicationServices
import Carbon
import Darwin

let slowPID = pid_t(CommandLine.arguments[1])!
let fastPID = pid_t(CommandLine.arguments[2])!
let clickPID = pid_t(CommandLine.arguments[3])!
let directory = URL(fileURLWithPath: CommandLine.arguments[4])
let area = NSScreen.screens[0].visibleFrame
let screen = NSScreen.screens[0].frame
func get(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
    var out: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key, &out) == .success ? out : nil
}
func rect(_ element: AXUIElement) -> CGRect? {
    guard let p = get(element, kAXPositionAttribute as CFString), let s = get(element, kAXSizeAttribute as CFString),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}
func windows(_ pid: pid_t) -> [String: AXUIElement] {
    guard let list = get(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString) as? [AXUIElement] else { return [:] }
    return Dictionary(uniqueKeysWithValues: list.compactMap { element in
        (get(element, kAXTitleAttribute as CFString) as? String).map { ($0, element) }
    })
}
func wait(_ label: String, timeout: TimeInterval = 4, _ condition: () -> Bool) {
    let until = Date().addingTimeInterval(timeout)
    while Date() < until {
        if condition() { return }
        usleep(2_000)
    }
    fatalError("Timed out: \(label)")
}
func state(_ name: String) -> [String: Any]? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return value
}
func workspace() -> Int? {
    let spaces = state("status.json")?["spaces"] as? [[String: Any]]
    return spaces?.first(where: { $0["isCurrent"] as? Bool == true })?["id"] as? Int
}
func ratio() -> Double? {
    let layouts = state("session.json")?["layouts"] as? [[String: Any]]
    return layouts?.first?["ratio"] as? Double
}
func key(_ code: Int) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = [.maskCommand, .maskControl, .maskAlternate]
        event.post(tap: .cghidEventTap)
        usleep(1_000)
    }
}
func focus(_ element: AXUIElement, pid: pid_t) {
    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
}
func focused(_ element: AXUIElement, pid: pid_t) -> Bool {
    guard let actual = get(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString),
          CFGetTypeID(actual) == AXUIElementGetTypeID() else { return false }
    return CFEqual(actual, element)
}
func parked(_ element: AXUIElement) -> Bool {
    guard let frame = rect(element) else { return false }
    return frame.minX >= screen.maxX - 3 || frame.maxX <= screen.minX + 3
}
var fast: [String: AXUIElement] = [:], slow: [String: AXUIElement] = [:], click: [String: AXUIElement] = [:]
wait("fixture windows") {
    fast = windows(fastPID); slow = windows(slowPID); click = windows(clickPID)
    return fast.count == 3 && slow.count == 3 && !click.isEmpty
}
let a = fast["Talus Test A"]!
let clickWindow = click["Talus External Click Target"]!
let oldPointer = CGEvent(source: nil)?.location
defer {
    kill(slowPID, SIGCONT)
    if let oldPointer { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: oldPointer, mouseButton: .left)?.post(tap: .cghidEventTap) }
}
if CommandLine.arguments.contains("--restored") {
    wait("every parked window restored") { Array(fast.values).allSatisfy { !parked($0) } && Array(slow.values).allSatisfy { !parked($0) } }
    print("Stress exit restored all six managed windows")
    exit(0)
}
wait("seeded workspace") { workspace() == 1 && state("status.json")?["count"] as? Int == 6 }
focus(a, pid: fastPID)
wait("focus fast app") { focused(a, pid: fastPID) }
usleep(50_000)
key(kVK_Return)
wait("fast app is master") { rect(a).map { abs($0.width - area.width * 0.5) < 3 && abs($0.minX - area.minX) < 3 } ?? false }
usleep(60_000)

let resumed = DispatchSemaphore(value: 0)
kill(slowPID, SIGSTOP)
DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { kill(slowPID, SIGCONT); resumed.signal() }
let begin = Date()
for _ in 0..<10 { key(kVK_ANSI_L) }
wait("latest fast-app ratio", timeout: 2) { rect(a).map { abs($0.width - area.width * 0.6) < 3 } ?? false }
let elapsed = Date().timeIntervalSince(begin) * 1000
let finishedWhileOtherAppStopped = resumed.wait(timeout: .now()) == .timedOut
print(String(format: "Ten resize inputs: fast app reached final geometry in %.1f ms; other app held for 400 ms; completed while stopped=%@", elapsed, String(finishedWhileOtherAppStopped)))
let baseline = ProcessInfo.processInfo.environment["TALUS_STRESS_BASELINE"] == "1"
if !baseline { precondition(finishedWhileOtherAppStopped, "A stalled app held up another app") }
wait("every logical resize was retained") { ratio().map { abs($0 - 0.6) < 0.0001 } ?? false }
usleep(450_000)
kill(slowPID, SIGCONT)
let regular = [fast["Talus Test A"]!, fast["Talus Test B"]!, slow["Talus Test A"]!, slow["Talus Test B"]!]
wait("all windows settle after slow app resumes") {
    let frames = regular.compactMap(rect)
    return frames.count == 4 && abs(frames.reduce(0.0) { $0 + $1.width * $1.height } - area.width * area.height) < area.width * 5
}
if baseline { print("Baseline delay measurement complete"); exit(0) }
for _ in 0..<12 { key(kVK_ANSI_2); key(kVK_ANSI_3); key(kVK_ANSI_1) }
wait("last of 36 workspace inputs wins") { workspace() == 1 && regular.allSatisfy { !parked($0) } && focused(a, pid: fastPID) }
wait("resizing survives superseded park/unpark operations") { rect(a).map { abs($0.width - area.width * 0.6) < 3 } ?? false }

kill(slowPID, SIGSTOP)
DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { kill(slowPID, SIGCONT) }
key(kVK_ANSI_2)
wait("fast windows park while another app is stalled") { parked(a) }
guard let target = rect(clickWindow) else { fatalError("Missing external window frame") }
let point = CGPoint(x: target.midX, y: target.midY)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(10_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
wait("external click focused its app") { WindowFocus.frontmostPID() == clickPID }
usleep(650_000)
precondition(WindowFocus.frontmostPID() == clickPID, "Old queued focus stole the user's click")
precondition(workspace() == 2, "A stale focus event bounced the workspace")
key(kVK_ANSI_1)
wait("workspace restores after the external click") { workspace() == 1 && regular.allSatisfy { !parked($0) } && focused(a, pid: fastPID) }
for fixed in [fast["Talus Test Fixed"]!, slow["Talus Test Fixed"]!] {
    precondition(abs(rect(fixed)!.width - 500) < 3, "A fixed-size window was resized")
}
print("36 rapid switches, latest ratio, real click cancellation and fixed-size preservation passed")
