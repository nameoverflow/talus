import CoreGraphics

@main struct ScreenGeometryTests {
    static func main() {
        let primary = accessibilityFrame(visible: CGRect(x: 0, y: 25, width: 1440, height: 852), primaryTop: 900)
        precondition(primary == CGRect(x: 0, y: 23, width: 1440, height: 852))
        let left = accessibilityFrame(visible: CGRect(x: -1920, y: -100, width: 1920, height: 1050), primaryTop: 900)
        precondition(left == CGRect(x: -1920, y: -50, width: 1920, height: 1050))
        let above = accessibilityFrame(visible: CGRect(x: 300, y: 900, width: 1600, height: 900), primaryTop: 900)
        precondition(above == CGRect(x: 300, y: -900, width: 1600, height: 900))
        let below = accessibilityFrame(visible: CGRect(x: 0, y: -1080, width: 1920, height: 1055), primaryTop: 900)
        precondition(below == CGRect(x: 0, y: 925, width: 1920, height: 1055))

        // Single-screen parking defaults to bottom-right 1px corner
        let mainScreen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let winSize = CGSize(width: 900, height: 700)
        let singleOrigin = parkedWindowOrigin(windowSize: winSize, screen: mainScreen, allScreens: [mainScreen])
        precondition(singleOrigin == CGPoint(x: 1709, y: 1106))

        // Clamped vertical position from macOS WindowServer (~maxY - 32) is still detected as parked
        let clampedParked = CGRect(x: 1709, y: 1075, width: 900, height: 700)
        precondition(isParkedWindowFrame(clampedParked, screen: mainScreen))
        precondition(!isParkedWindowFrame(CGRect(x: 0, y: 34, width: 855, height: 1073), screen: mainScreen))

        // Multi-monitor: when a second monitor sits directly to the right, park on bottom-left so it never spills onto rightScreen
        let rightScreen = CGRect(x: 1710, y: 0, width: 1920, height: 1080)
        let dualOrigin = parkedWindowOrigin(windowSize: winSize, screen: mainScreen, allScreens: [mainScreen, rightScreen])
        precondition(dualOrigin == CGPoint(x: -899, y: 1106))
        let leftParked = CGRect(x: -899, y: 1075, width: 900, height: 700)
        precondition(isParkedWindowFrame(leftParked, screen: mainScreen))
        precondition(!rightScreen.intersects(leftParked))

        // CGWindowID match succeeds even when Qt/custom-chrome AX frame differs by >3pt from CGWindowBounds
        let candidates = [
            VisibleWindowCandidate(pid: 29852, windowID: 82740, bounds: CGRect(x: 0, y: 34, width: 1710, height: 1073)),
            VisibleWindowCandidate(pid: 52812, windowID: 83178, bounds: CGRect(x: 0, y: 34, width: 855, height: 1073)),
        ]
        precondition(matchesVisibleWindow(
            pid: 29852,
            axWindowID: 82740,
            axFrame: CGRect(x: 8, y: 42, width: 1694, height: 1057),
            candidates: candidates
        ))
        // Fallback frame match when axWindowID is unavailable
        precondition(matchesVisibleWindow(
            pid: 52812,
            axWindowID: nil,
            axFrame: CGRect(x: 1, y: 35, width: 855, height: 1073),
            candidates: candidates
        ))
        // Rejects minimized / other-Space window whose windowID and frame are absent from on-screen list
        precondition(!matchesVisibleWindow(
            pid: 29852,
            axWindowID: 99999,
            axFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            candidates: candidates
        ))

        // Session lock detection guards virtual workspace state during screen lock / fast user switching
        precondition(!isSessionDictionaryLocked(["kCGSSessionOnConsoleKey": 1], frontmostBundleID: "com.mitchellh.ghostty"))
        precondition(isSessionDictionaryLocked(["CGSSessionScreenIsLocked": 1, "kCGSSessionOnConsoleKey": 1], frontmostBundleID: "com.mitchellh.ghostty"))
        precondition(isSessionDictionaryLocked(["kCGSSessionOnConsoleKey": 0], frontmostBundleID: nil))
        precondition(isSessionDictionaryLocked(nil, frontmostBundleID: "com.apple.loginwindow"))

        print("Screen coordinate conversion and parking geometry tests passed")
    }
}
