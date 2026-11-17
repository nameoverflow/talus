import Cocoa
import ApplicationServices
import Carbon
import Darwin

@_silgen_name("_AXUIElementGetWindow")
func windowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<UInt32>) -> AXError
let his = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)!
let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
typealias PSNForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
typealias GetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
let getPSN = unsafeBitCast(dlsym(his, "GetProcessForPID")!, to: PSNForPID.self)
let getFront = unsafeBitCast(dlsym(sky, "_SLPSGetFrontProcess")!, to: GetFront.self)
func get(_ e: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, attribute, &value) == .success ? value : nil
}
struct Target {
    let app: AXUIElement
    let window: AXUIElement
    let pid: pid_t
    let id: UInt32
    var psn: ProcessSerialNumber
}
var groups: [[Target]] = []
for argument in CommandLine.arguments.dropFirst() {
    let pid = pid_t(argument)!, app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.1)
    var targets: [Target] = []
    let deadline = Date().addingTimeInterval(5)
    repeat {
        if let windows = get(app, kAXWindowsAttribute as CFString) as? [AXUIElement] {
            targets = windows.compactMap { element in
                guard let name = get(element, kAXTitleAttribute as CFString) as? String,
                      name == "Talus Test A" || name == "Talus Test B" else { return nil }
                var id: UInt32 = 0, psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
                guard windowID(element, &id) == .success, getPSN(pid, &psn) == 0 else { return nil }
                return Target(app: app, window: element, pid: pid, id: id, psn: psn)
            }
        }
        if targets.count == 2 { break }
        usleep(10_000)
    } while Date() < deadline
    precondition(targets.count == 2, "Fixture unavailable (desktop must be unlocked)")
    groups.append(targets)
    print("fixture \(pid) enhancedUI=\(get(app, "AXEnhancedUserInterface" as CFString) as? Bool ?? false)")
}
func focused(_ target: Target) -> Bool {
    var front = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
    guard getFront(&front) == 0,
          front.highLongOfPSN == target.psn.highLongOfPSN && front.lowLongOfPSN == target.psn.lowLongOfPSN,
          let element = get(target.app, kAXFocusedWindowAttribute as CFString),
          CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
    var id: UInt32 = 0
    return windowID(element as! AXUIElement, &id) == .success && id == target.id
}
func report(_ name: String, _ values: [Double]) {
    let sorted = values.sorted()
    print(String(format: "%@ n=%d median=%.3f ms P95=%.3f ms max=%.3f ms", name, sorted.count,
        sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last!))
}
for scenario in ["same-app", "cross-app"] {
    let targets = scenario == "same-app" ? groups[0] : [groups[0][0], groups[1][0], groups[0][1], groups[1][1]]
    for mode in ["legacy", "optimized"] {
        var total: [Double] = [], submitted: [Double] = []
        var failures = 0
        for i in 0..<40 {
            let target = targets[i % targets.count]
            let begin = DispatchTime.now().uptimeNanoseconds
            WindowFocus.request(window: target.window, app: target.app, pid: target.pid, legacy: mode == "legacy")
            submitted.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
            let deadline = Date().addingTimeInterval(0.5)
            while !focused(target) && Date() < deadline { usleep(1_000) }
            if !focused(target) { failures += 1 }
            total.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
            usleep(5_000)
        }
        report("\(scenario) \(mode) submit", submitted)
        report("\(scenario) \(mode) confirmed", total)
        print("failures=\(failures)")
        precondition(failures == 0, "A requested window did not receive keyboard focus")
    }
}