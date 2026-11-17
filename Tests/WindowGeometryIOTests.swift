import Foundation
import ApplicationServices

@main
struct WindowGeometryIOTests {
    static func main() {
        let element = AXUIElementCreateApplication(-1)
        let target = CGRect(x: 0, y: 34, width: 1710, height: 1073)
        var actual = CGRect(x: 20, y: 54, width: 1690, height: 1053)
        var ready = false
        var settles = 0
        let provider = FrameAccess(read: { actual }, position: { point in
            if ready { actual.origin = point }
            return .success
        }, size: { size in
            if ready { actual.size = size }
            return .success
        }, settle: { settles += 1 })
        precondition(setFrame(element, target, current: actual, access: provider) == .cannotComplete,
            "Successful AX replies hid an unapplied geometry request")
        precondition(actual != target && settles == 1)
        ready = true
        precondition(setFrame(element, target, current: actual, access: provider) == .success)
        precondition(actual == target)

        actual.origin.x = 20
        ready = false
        precondition(setFrame(element, target, current: actual, access: provider) == .cannotComplete,
            "The position-only optimization bypassed confirmation")
        precondition(matchesFrame(CGRect(x: 1709, y: 1075, width: 500, height: 332),
            CGRect(x: 1709, y: 1106, width: 500, height: 332), parking: true))
        precondition(!matchesFrame(CGRect(x: 20, y: 54, width: 1690, height: 1053), target))
        print("Ignored AX writes return retryable errors; position-only and parked frames validate correctly")
    }
}
