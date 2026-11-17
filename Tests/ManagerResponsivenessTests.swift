import Cocoa
import ApplicationServices

@main
struct ManagerResponsivenessTests {
    static func wait(_ condition: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(condition(), "Asynchronous discovery did not settle")
    }

    static func main() {
        // A stalled worker must leave the main queue responsive. A config change
        // during that stall must reject its old window snapshot and reconcile.
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        var calls = 0
        let area = screenRect(NSScreen.screens[0])
        let manager = Manager(config: Configuration(), discover: { _, _, _, _, _, _ in
            calls += 1
            if calls == 1 {
                started.signal()
                precondition(release.wait(timeout: .now() + 2) == .success)
                var old = WindowDiscoveryResult()
                old.livePIDs = [-1001]
                old.windows = [DiscoveredWindow(element: AXUIElementCreateApplication(-1001), pid: -1001,
                    bundleID: nil, windowID: 101, title: "stale", rect: area, isResizable: true)]
                return old
            }
            return WindowDiscoveryResult()
        }, canDiscover: { true })
        var counts: [Int] = []
        manager.statusChanged = { [weak manager] in counts.append(manager?.activeWindowCount ?? 0) }
        let before = Date()
        manager.refresh()
        precondition(Date().timeIntervalSince(before) < 0.05, "refresh blocked the caller")
        precondition(started.wait(timeout: .now() + 1) == .success)
        var mainQueueRan = false
        DispatchQueue.main.async { mainQueueRan = true }
        wait({ mainQueueRan })
        var updated = Configuration()
        updated.outerGap = 12
        manager.apply(config: updated)
        release.signal()
        wait({ !counts.isEmpty })
        precondition(calls == 2, "Expected one replacement scan")
        precondition(counts.allSatisfy { $0 == 0 }, "Stale windows reached the core")

        // Many structural events in one turn create one scan, with no 50 ms wait.
        var completions = 0
        let coalesced = Manager(config: Configuration(), discover: { _, _, _, _, _, _ in
            WindowDiscoveryResult()
        }, canDiscover: { true })
        coalesced.statusChanged = { completions += 1 }
        for _ in 0..<100 { coalesced.scheduleRefresh(pid: -1002) }
        wait({ completions > 0 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(completions == 1, "Structural events caused duplicate scans")

        // An app-scoped scan replaces that app's snapshot and retains others.
        let masterWidth = (area.width * 0.5).rounded()
        let first = DiscoveredWindow(element: AXUIElementCreateApplication(-201), pid: -201,
            bundleID: nil, windowID: 201, title: "first",
            rect: CGRect(x: area.minX, y: area.minY, width: masterWidth, height: area.height), isResizable: true)
        let second = DiscoveredWindow(element: AXUIElementCreateApplication(-202), pid: -202,
            bundleID: nil, windowID: 202, title: "second",
            rect: CGRect(x: area.minX + masterWidth, y: area.minY, width: area.width - masterWidth, height: area.height), isResizable: true)
        let incremental = Manager(config: Configuration(), discover: { _, _, _, _, _, scope in
            var result = WindowDiscoveryResult()
            result.livePIDs = [-201, -202]
            result.visibleWindowIDs = [201, 202]
            result.existingWindowIDs = [201, 202]
            if let scope {
                precondition(scope == [-201], "Unexpected targeted scan scope")
                result.windows = [first]
            } else {
                result.windows = [first, second]
            }
            return result
        }, canDiscover: { true })
        var incrementalCompletions = 0
        incremental.statusChanged = { incrementalCompletions += 1 }
        incremental.refresh()
        wait({ incrementalCompletions == 1 })
        precondition(incremental.activeWindowCount == 2)
        incremental.scheduleRefresh(pid: -201)
        wait({ incrementalCompletions == 2 })
        precondition(incremental.activeWindowCount == 2, "Targeted discovery dropped another app's windows")
        print("Background discovery responsive; stale scans rejected; 100 events coalesced; targeted scans retained other apps")
    }
}
