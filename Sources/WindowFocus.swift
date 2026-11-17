import Cocoa
import ApplicationServices
import Carbon
import Darwin

/// NSWorkspace's activation notifications can lag a rapid focus sequence. This
/// read-only query lets us omit AXFrontmost only when the real front process
/// matches. Missing private symbols conservatively keep the AX activation call.
private final class FrontProcess {
    static let shared = FrontProcess()
    typealias GetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    typealias GetPID = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let getFront: GetFront?
    private let getPID: GetPID?

    private init() {
        let library = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY | RTLD_LOCAL)
        self.library = library
        getFront = library.flatMap { dlsym($0, "_SLPSGetFrontProcess") }.map { unsafeBitCast($0, to: GetFront.self) }
        getPID = library.flatMap { dlsym($0, "GetProcessPID") }.map { unsafeBitCast($0, to: GetPID.self) }
    }

    deinit { if let library { dlclose(library) } }

    func isFrontmost(_ pid: pid_t) -> Bool {
        guard let getFront, let getPID else { return false }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0), actual: pid_t = 0
        return getFront(&psn) == 0 && getPID(&psn, &actual) == 0 && actual == pid
    }
}

enum WindowFocus {
    /// AXFrontmost runs the application's activation path. Merely activating
    /// its WindowServer process can leave a different window holding key focus.
    /// Keep the original sequence as a compatibility fallback for AX providers
    /// which cannot make a window main or raise it independently.
    @discardableResult
    static func request(window: AXUIElement, app: AXUIElement, pid: pid_t,
                        legacy: Bool = false) -> Bool {
        if !legacy {
            let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if main == .success && raised == .success {
                if FrontProcess.shared.isFrontmost(pid) { return true }
                if AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success {
                    return true
                }
            }
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return false
    }
}
