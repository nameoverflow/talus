import Foundation
import ApplicationServices

struct WindowGeometry {
    let key: UInt64
    let pid: pid_t
    let element: AXUIElement
    // Always a complete goal, including when the core only changed position.
    let target: CGRect
    let resizable: Bool
    var parking: Bool = false
}

/// Scheduling and callbacks are main-thread confined. AX writes run serially
/// within each application, independently of the other applications.
final class WindowExecutor {
    typealias Apply = (WindowGeometry, CGRect?) -> AXError
    private struct Request {
        let sequence: UInt64
        let geometry: WindowGeometry
    }

    private final class AppWorker {
        let queue: DispatchQueue
        private let lock = NSLock()
        private var targets: [UInt64: Request] = [:]
        private var order: [UInt64] = []
        private var frames: [UInt64: CGRect] = [:]
        private var forgottenDuringWrite: Set<UInt64> = []
        private var pumping = false
        private var running: UInt64?
        private let apply: Apply
        private let completed: (Request, AXError) -> Void
        private let idle: () -> Void

        init(pid: pid_t, apply: @escaping Apply,
             completed: @escaping (Request, AXError) -> Void, idle: @escaping () -> Void) {
            queue = DispatchQueue(label: "local.talus.windows.\(pid)", qos: .userInitiated)
            self.apply = apply
            self.completed = completed
            self.idle = idle
        }

        var busy: Bool {
            lock.lock(); defer { lock.unlock() }
            return pumping
        }

        func contains(_ key: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return running == key || targets[key] != nil
        }

        func observe(_ key: UInt64, _ frame: CGRect) {
            lock.lock(); defer { lock.unlock() }
            if running != key && targets[key] == nil { frames[key] = frame }
        }

        func enqueue(_ request: Request) {
            lock.lock()
            let key = request.geometry.key
            if targets[key] == nil { order.append(key) }
            targets[key] = request
            let start = !pumping
            pumping = true
            lock.unlock()
            if start { queue.async { self.drain() } }
        }

        func cancel(_ key: UInt64) {
            lock.lock(); defer { lock.unlock() }
            targets.removeValue(forKey: key)
            order.removeAll { $0 == key }
            frames.removeValue(forKey: key)
            if running == key { forgottenDuringWrite.insert(key) }
        }

        func cancelQueued() {
            lock.lock(); defer { lock.unlock() }
            targets.removeAll()
            order.removeAll()
        }

        private func drain() {
            while true {
                lock.lock()
                guard !order.isEmpty else {
                    pumping = false
                    running = nil
                    lock.unlock()
                    DispatchQueue.main.async(execute: idle)
                    return
                }
                let key = order.removeFirst()
                let request = targets.removeValue(forKey: key)!
                let current = frames[key]
                running = key
                lock.unlock()
                let error = apply(request.geometry, current)
                lock.lock()
                if forgottenDuringWrite.remove(key) != nil {
                    frames.removeValue(forKey: key)
                } else if error == .success {
                    frames[key] = request.geometry.target
                } else {
                    frames.removeValue(forKey: key)
                }
                running = nil
                lock.unlock()
                // Enqueue completion before this worker can report itself idle.
                DispatchQueue.main.async { self.completed(request, error) }
            }
        }
    }

    private var workers: [pid_t: AppWorker] = [:]
    private var pending: [UInt64: Request] = [:]
    private var sequence: UInt64 = 0
    private var needsSettlement = false
    private(set) var submittedCount: UInt64 = 0
    private(set) var appliedCount: UInt64 = 0
    private var focus: (() -> Void)?
    private var focusRevision: UInt64 = 0
    private(set) var focusKey: UInt64?
    private(set) var focusPID: pid_t?
    private let apply: Apply
    var onResult: ((UInt64, AXError) -> Void)?
    var onSettled: (() -> Void)?

    init(apply: @escaping Apply) { self.apply = apply }

    var hasPendingGeometry: Bool {
        !pending.isEmpty || workers.values.contains { $0.busy }
    }

    var hasPendingFocus: Bool { focus != nil }

    func isPending(_ key: UInt64) -> Bool {
        pending[key] != nil || workers.values.contains { $0.contains(key) }
    }

    private func worker(_ pid: pid_t) -> AppWorker {
        if let worker = workers[pid] { return worker }
        let worker = AppWorker(pid: pid, apply: apply, completed: { [weak self] request, error in
            guard let self else { return }
            self.appliedCount &+= 1
            guard self.pending[request.geometry.key]?.sequence == request.sequence else { return }
            self.pending.removeValue(forKey: request.geometry.key)
            self.onResult?(request.geometry.key, error)
            self.settleIfIdle()
        }, idle: { [weak self] in self?.settleIfIdle() })
        workers[pid] = worker
        return worker
    }

    func observe(key: UInt64, pid: pid_t, frame: CGRect) {
        worker(pid).observe(key, frame)
    }

    func submit(_ geometries: [WindowGeometry], focusKey: UInt64? = nil,
                focusPID: pid_t? = nil, focusAction: (() -> Void)? = nil) {
        guard !geometries.isEmpty || focusAction != nil else { return }
        needsSettlement = true
        if let focusAction {
            focusRevision &+= 1
            focus = focusAction
            self.focusKey = focusKey
            self.focusPID = focusPID
        }
        for geometry in geometries {
            submittedCount &+= 1
            sequence &+= 1
            let request = Request(sequence: sequence, geometry: geometry)
            pending[geometry.key] = request
            worker(geometry.pid).enqueue(request)
        }
        // Also coalesce multiple focus-only requests arriving in one turn.
        DispatchQueue.main.async { [weak self] in self?.settleIfIdle() }
    }

    func cancelFocus() {
        focusRevision &+= 1
        focus = nil
        focusKey = nil
        focusPID = nil
    }

    func cancelQueued() {
        cancelFocus()
        for worker in workers.values { worker.cancelQueued() }
        pending.removeAll()
    }

    func forget(_ key: UInt64) {
        pending.removeValue(forKey: key)
        for worker in workers.values { worker.cancel(key) }
        if focusKey == key { cancelFocus() }
    }

    func retainApplications(_ live: Set<pid_t>) {
        for (pid, worker) in workers where !live.contains(pid) { worker.cancelQueued() }
        workers = workers.filter { live.contains($0.key) }
        pending = pending.filter { live.contains($0.value.geometry.pid) }
        if let pid = focusPID, !live.contains(pid) { cancelFocus() }
    }

    /// Used only for exit, permission-session relaunch and final restoration.
    /// Workers never wait for main-queue callbacks, so draining cannot deadlock.
    func finishSynchronously() {
        cancelFocus()
        for worker in workers.values { worker.queue.sync {} }
        pending.removeAll()
        needsSettlement = false
    }

    private func settleIfIdle() {
        guard needsSettlement, !hasPendingGeometry else { return }
        needsSettlement = false
        let action = focus
        let revision = focusRevision
        // Keep the expected key observable while focus is being submitted.
        action?()
        if focusRevision == revision { cancelFocus() }
        if !needsSettlement { onSettled?() }
    }
}
