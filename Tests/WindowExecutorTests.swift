import Foundation
import ApplicationServices

private final class Records {
    private let lock = NSLock()
    private var storage: [(UInt64, CGRect)] = []
    func append(_ key: UInt64, _ rect: CGRect) {
        lock.lock(); defer { lock.unlock() }
        storage.append((key, rect))
    }
    var values: [(UInt64, CGRect)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

@main
struct WindowExecutorTests {
    static func goal(_ key: UInt64, pid: pid_t, x: CGFloat, width: CGFloat = 200) -> WindowGeometry {
        WindowGeometry(key: key, pid: pid, element: AXUIElementCreateApplication(pid),
            target: CGRect(x: x, y: 0, width: width, height: 100), resizable: true)
    }
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        precondition(condition(), "Window execution failed to settle")
    }

    static func main() {
        let records = Records()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let executor = WindowExecutor { geometry, _ in
            precondition(!Thread.isMainThread, "AX execution blocked the UI thread")
            if geometry.key == 1 && geometry.target.minX == 1 {
                started.signal()
                precondition(release.wait(timeout: .now() + 3) == .success)
            }
            records.append(geometry.key, geometry.target)
            return geometry.key == 1 && geometry.target.minX == 1 ? .cannotComplete : .success
        }
        var results: [UInt64] = [], focuses: [Int] = [], settled = 0
        executor.onResult = { key, _ in results.append(key) }
        executor.onSettled = { settled += 1 }
        executor.submit([goal(1, pid: -101, x: 1)], focusKey: 1, focusPID: -101, focusAction: { focuses.append(0) })
        precondition(started.wait(timeout: .now() + 1) == .success)
        executor.submit([goal(2, pid: -102, x: 2)])
        var mainRan = false
        DispatchQueue.main.async { mainRan = true }
        wait({ mainRan && results.contains(2) })
        precondition(focuses.isEmpty, "Focus ran before another app's geometry finished")
        for index in 2...100 {
            executor.submit([goal(1, pid: -101, x: CGFloat(index))], focusKey: 1, focusPID: -101,
                focusAction: { focuses.append(index) })
        }
        // A pending resize can be superseded by a position change. The complete
        // final goal must still include that resize even though it never ran.
        executor.submit([goal(3, pid: -101, x: 10, width: 400)])
        executor.submit([goal(3, pid: -101, x: 20, width: 400)])
        release.signal()
        wait({ settled == 1 })
        precondition(records.values.filter { $0.0 == 1 }.map { $0.1.minX } == [1, 100])
        let third = records.values.filter { $0.0 == 3 }
        precondition(third.count == 1 && third[0].1.minX == 20 && third[0].1.width == 400)
        precondition(results.filter { $0 == 1 }.count == 1, "A superseded result escaped")
        precondition(focuses == [100], "An old focus was submitted")

        // Clicking elsewhere may cancel focus without dropping geometry.
        let cancelStarted = DispatchSemaphore(value: 0), cancelRelease = DispatchSemaphore(value: 0)
        let cancelled = WindowExecutor { _, _ in
            cancelStarted.signal()
            precondition(cancelRelease.wait(timeout: .now() + 2) == .success)
            return .success
        }
        var cancelledSettled = false, stoleFocus = false
        cancelled.onSettled = { cancelledSettled = true }
        cancelled.submit([goal(4, pid: -103, x: 0)], focusKey: 4, focusPID: -103, focusAction: { stoleFocus = true })
        precondition(cancelStarted.wait(timeout: .now() + 1) == .success)
        cancelled.cancelFocus()
        cancelRelease.signal()
        wait({ cancelledSettled })
        precondition(!stoleFocus)

        // A focus-only input must retain an unfinished geometry barrier.
        let barrierStarted = DispatchSemaphore(value: 0), barrierRelease = DispatchSemaphore(value: 0)
        let barrier = WindowExecutor { _, _ in
            barrierStarted.signal()
            precondition(barrierRelease.wait(timeout: .now() + 2) == .success)
            return .success
        }
        var focusedAfterBarrier = false
        barrier.submit([goal(5, pid: -104, x: 0)])
        precondition(barrierStarted.wait(timeout: .now() + 1) == .success)
        barrier.submit([], focusKey: 5, focusPID: -104, focusAction: { focusedAfterBarrier = true })
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(!focusedAfterBarrier)
        barrierRelease.signal()
        wait({ focusedAfterBarrier })

        // Exit waits for the latest writes, without waiting for main callbacks
        // or submitting the focus that belonged to an old input.
        let exitRecords = Records()
        let exiting = WindowExecutor { geometry, _ in
            exitRecords.append(geometry.key, geometry.target)
            return .success
        }
        var exitFocus = false
        exiting.submit([goal(6, pid: -105, x: 42)], focusKey: 6, focusPID: -105, focusAction: { exitFocus = true })
        exiting.finishSynchronously()
        precondition(exitRecords.values.last?.1.minX == 42 && !exitFocus && !exiting.hasPendingGeometry)

        var updates = 0
        let update = MainLoopUpdate { updates += 1 }
        for _ in 0..<100 { update.request() }
        precondition(updates == 0, "Status ran in the input handler")
        wait({ updates == 1 })
        update.request()
        update.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(updates == 2, "A flushed update ran twice")

        var reentrantFocuses: [Int] = []
        let reentrant = WindowExecutor { _, _ in .success }
        reentrant.submit([], focusAction: {
            reentrantFocuses.append(1)
            reentrant.submit([], focusAction: { reentrantFocuses.append(2) })
        })
        wait({ reentrantFocuses.count == 2 })
        precondition(reentrantFocuses == [1, 2], "A new focus was cleared by an older completion")
        print("Parallel apps, latest complete goals, focus barriers/cancellation, shutdown and coalesced UI updates passed")
    }
}
