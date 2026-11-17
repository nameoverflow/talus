import Cocoa
import ApplicationServices
import Carbon
import Darwin

struct AXWindowKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AXWindowKey, rhs: AXWindowKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

let workspaceDigitKeyCodes: [Int] = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
    kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
    kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
]

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

func isSessionScreenLocked() -> Bool {
    if ProcessInfo.processInfo.environment["TALUS_TEST_PID"] != nil {
        return false
    }
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    return isSessionDictionaryLocked(session, frontmostBundleID: frontBundle)
}

func applyWindowGeometry(_ geometry: WindowGeometry, _ current: CGRect?) -> AXError {
    let result = geometry.resizable ? setFrame(geometry.element, geometry.target, current: current, parking: geometry.parking)
        : setPosition(geometry.element, geometry.target.origin)
    if ProcessInfo.processInfo.environment["TALUS_TRACE_GEOMETRY"] == "1" {
        fputs("geometry key=\(geometry.key) pid=\(geometry.pid) from=\(String(describing: current)) target=\(geometry.target) result=\(result.rawValue) actual=\(String(describing: frame(geometry.element)))\n", stderr)
    }
    return result
}

func screenRect(_ screen: NSScreen) -> CGRect {
    let r = screen.visibleFrame
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    return accessibilityFrame(visible: r, primaryTop: top)
}

func fullScreenRect(_ screen: NSScreen) -> CGRect {
    let r = screen.frame
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    return accessibilityFrame(visible: r, primaryTop: top)
}

// MARK: - Wire payloads for Rust `ManagerCore` FFI

private struct WireRect: Codable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double

    init(_ r: CGRect) {
        self.x = Double(r.origin.x)
        self.y = Double(r.origin.y)
        self.w = Double(r.size.width)
        self.h = Double(r.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }
}

private struct WireScreenSpec: Encodable {
    let id: Int
    let visibleFrame: WireRect
    let fullFrame: WireRect
}

private struct WireCandidateWindow: Encodable {
    let key: UInt64
    let pid: Int32
    let bundleId: String?
    let windowId: UInt32?
    let title: String
    var frame: WireRect
    let isResizable: Bool
}

private struct WireWindowEffect: Decodable {
    let kind: String
    let key: UInt64?
    let rect: WireRect?
    let x: Double?
    let y: Double?
    let pid: Int32?
}

private struct WireManagerActionOutput: Decodable {
    let geometryGeneration: UInt64?
    let windowFrames: [String: WireRect]?
    let effects: [WireWindowEffect]?
    let activeWindowKeys: [UInt64]?
    let observeWindowKeys: [UInt64]?
    let paused: Bool?
    let pausedToggled: Bool?
    let layoutName: String?
    let activeWorkspace: Int?
    let workspaceCount: Int?
    let isVirtualMode: Bool?
    let statusChanged: Bool?
    let traceLog: String?
}

private struct WireManagerStatusSnapshot: Decodable {
    let isVirtualMode: Bool
    let paused: Bool
    let layoutName: String
    let activeWorkspace: Int
    let workspaceCount: Int
    let windowCount: Int
    let focusedWindowKey: UInt64?
    let focusedScreenId: Int?
    let virtualSpaceEntries: [SpaceEntry]
}

// MARK: - Thin macOS AX / Cocoa Shell backed by Rust `ManagerCore`

final class Manager {
    private var coreHandle: OpaquePointer?
    private var handleByKey: [AXWindowKey: UInt64] = [:]
    private var elementByHandle: [UInt64: AXUIElement] = [:]
    private var pidByHandle: [UInt64: pid_t] = [:]
    private var nextHandle: UInt64 = 1
    private var foregroundCreation: (key: UInt64, pid: pid_t, until: Date)?
    private var frameByHandle: [UInt64: CGRect] = [:]
    private var dirtyFrameHandles: Set<UInt64> = []
    private var observedWindowHandles: Set<UInt64> = []
    private var activeWindowHandles: Set<UInt64> = []
    private var candidatesByHandle: [UInt64: WireCandidateWindow] = [:]
    private let discoveryQueue = DispatchQueue(label: "local.talus.discovery", qos: .userInitiated)
    private let discoverSnapshot: WindowDiscoveryFunction
    private let canDiscover: () -> Bool
    private var discoveryRevision: UInt64 = 0
    private var discoveryInFlight = false
    private var pendingDiscovery = false
    private var pendingFullDiscovery = false
    private var pendingDiscoveryPIDs: Set<pid_t> = []
    private var pendingForce = false
    private var scheduledRefresh: DispatchWorkItem?
    private var readinessRetry: DispatchWorkItem?
    private var pendingCreations: [AXWindowKey: (pid: pid_t, until: Date)] = [:]
    private var failedWriteAttempts: [UInt64: Int] = [:]
    private let windowExecutor: WindowExecutor
    private var confirmedFocusKey: UInt64?
    private var focusOriginKey: UInt64?
    private var externalFocusAllowedDuringLayout = false
    private var focusJustDelivered = false
    private var titlesByHandle: [UInt64: String] = [:]
    private var titleReadPending: Set<UInt64> = []
    private var titleReadAt: [UInt64: Date] = [:]
    private var frameReadPending: Set<UInt64> = []
    private var geometryGeneration: UInt64 = 0
    private var lastSubmittedFrames: [UInt64: CGRect] = [:]
    private var fullScreenBounds: [CGRect] = []

    let ownPID = ProcessInfo.processInfo.processIdentifier
    var ignoredApps: Set<String>
    private(set) var isVirtualMode: Bool
    private(set) var activeWorkspace: Int = 0
    private(set) var workspaceCount: Int
    private(set) var activeWindowCount: Int = 0
    private(set) var currentLayoutName: String = "Tall"

    var paused: Bool = false {
        didSet {
            guard oldValue != paused else { return }
            if paused {
                windowExecutor.cancelQueued()
                _ = dispatchJSON(["op": "cancelFocusDelivery"])
            }
            _ = dispatchJSON(["op": "setPaused", "paused": paused])
        }
    }

    var observers: [pid_t: AXObserver] = [:]
    var statusChanged: (() -> Void)?
    var onStaleSandboxTCCDetected: (() -> Void)?

    init(config: Configuration, discover: @escaping WindowDiscoveryFunction = discoverWindows,
         canDiscover: @escaping () -> Bool = { AXIsProcessTrusted() && !isSessionScreenLocked() },
         applyGeometry: @escaping WindowExecutor.Apply = applyWindowGeometry) {
        self.windowExecutor = WindowExecutor(apply: applyGeometry)
        self.discoverSnapshot = discover
        self.canDiscover = canDiscover
        self.ignoredApps = Set(config.ignoreApps)
        self.isVirtualMode = (config.workspaceMode == "virtual")
        self.workspaceCount = config.workspaceCount
        let cfgJSON = (try? String(data: JSONEncoder().encode(config), encoding: .utf8)) ?? "{}"
        let sessionPath = PersistedWorkspaceSession.defaultFileURL()?.path
        self.coreHandle = cfgJSON.withCString { cCfg in
            if let sessionPath {
                return sessionPath.withCString { cSession in
                    talus_manager_new(cCfg, cSession)
                }
            }
            return talus_manager_new(cCfg, nil)
        }
        windowExecutor.onResult = { [weak self] key, error in
            guard let self else { return }
            self.discoveryRevision &+= 1
            if error == .success {
                self.failedWriteAttempts.removeValue(forKey: key)
            } else {
                self.retryFailedWrite(key)
            }
        }
        windowExecutor.onSettled = { [weak self] in
            guard let self else { return }
            if ProcessInfo.processInfo.environment["TALUS_TRACE_EVENTS"] == "1" {
                fputs("execution settled submitted=\(self.windowExecutor.submittedCount) applied=\(self.windowExecutor.appliedCount)\n", stderr)
            }
            if self.focusJustDelivered {
                self.focusJustDelivered = false
                self.rememberFocus()
            }
            if self.pendingDiscovery {
                let scope = self.pendingFullDiscovery ? nil : self.pendingDiscoveryPIDs
                self.refresh(onlyPIDs: scope)
            }
            self.statusChanged?()
        }
        syncSnapshotFromCore()
    }

    deinit {
        if let coreHandle {
            talus_manager_free(coreHandle)
        }
    }

    private func handle(for element: AXUIElement, pid: pid_t? = nil) -> UInt64 {
        let key = AXWindowKey(element: element)
        if let existing = handleByKey[key] {
            if let pid { pidByHandle[existing] = pid }
            return existing
        }
        let id = nextHandle
        nextHandle += 1
        AXUIElementSetMessagingTimeout(element, 0.1)
        handleByKey[key] = id
        elementByHandle[id] = element
        if let pid { pidByHandle[id] = pid }
        return id
    }

    private func collectLiveFrames(readAll: Bool = false) -> [String: Any] {
        let keys = readAll ? Set(elementByHandle.keys) : dirtyFrameHandles.intersection(activeWindowHandles)
        for key in keys where !windowExecutor.isPending(key) {
            guard let element = elementByHandle[key] else { continue }
            let serverFrame = candidatesByHandle[key]?.windowId.flatMap { WindowServerFrames.shared.frame($0) }
            if let rect = serverFrame ?? (readAll ? frame(element) : nil) {
                frameByHandle[key] = rect
                if let pid = pidByHandle[key] { windowExecutor.observe(key: key, pid: pid, frame: rect) }
                dirtyFrameHandles.remove(key)
                if var candidate = candidatesByHandle[key] {
                    candidate.frame = WireRect(rect)
                    candidatesByHandle[key] = candidate
                }
            } else if !readAll, !frameReadPending.contains(key) {
                frameReadPending.insert(key)
                let revision = discoveryRevision
                discoveryQueue.async { [weak self] in
                    let rect = frame(element)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.frameReadPending.remove(key)
                        guard revision == self.discoveryRevision, !self.windowExecutor.isPending(key),
                              self.elementByHandle[key] != nil, let rect else { return }
                        self.cacheFrame(rect, for: key)
                    }
                }
            }
        }
        return Dictionary(uniqueKeysWithValues: frameByHandle.map { key, rect in
            (String(key), ["x": Double(rect.minX), "y": Double(rect.minY),
                           "w": Double(rect.width), "h": Double(rect.height)] as Any)
        })
    }

    private func cacheFrame(_ rect: CGRect, for key: UInt64, observed: Bool = true) {
        frameByHandle[key] = rect
        if observed, lastSubmittedFrames[key] == nil { lastSubmittedFrames[key] = rect }
        if observed, let pid = pidByHandle[key] { windowExecutor.observe(key: key, pid: pid, frame: rect) }
        dirtyFrameHandles.remove(key)
        if var candidate = candidatesByHandle[key] {
            candidate.frame = WireRect(rect)
            candidatesByHandle[key] = candidate
        }
    }

    private func geometryRequest(key: UInt64, pid: pid_t, element: AXUIElement, target: CGRect,
                                 resizable: Bool) -> WindowGeometry {
        WindowGeometry(key: key, pid: pid, element: element, target: target, resizable: resizable,
            parking: fullScreenBounds.contains { isParkedWindowFrame(target, screen: $0) })
    }

    private func retryFailedWrite(_ key: UInt64) {
        dirtyFrameHandles.insert(key)
        let attempts = failedWriteAttempts[key, default: 0]
        guard !paused, attempts < 2, let pid = pidByHandle[key], let element = elementByHandle[key],
              let target = frameByHandle[key], canDiscover() else { return }
        failedWriteAttempts[key] = attempts + 1
        discoveryRevision &+= 1
        // Retry the latest complete goal directly: a core frame cache is
        // optimistic and could otherwise suppress a retry of a failed write.
        windowExecutor.submit([geometryRequest(key: key, pid: pid, element: element,
            target: target, resizable: candidatesByHandle[key]?.isResizable ?? true)])
    }

    @discardableResult
    private func dispatchData(_ data: Data) -> WireManagerActionOutput? {
        guard let coreHandle,
              let jsonStr = String(data: data, encoding: .utf8)
        else { return nil }
        let resPtr = jsonStr.withCString { cReq in
            talus_manager_dispatch(coreHandle, cReq)
        }
        defer { if let resPtr { talus_string_free(resPtr) } }
        guard let resPtr,
              let outData = String(cString: resPtr).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WireManagerActionOutput.self, from: outData)
        else { return nil }

        if let p = decoded.paused { self.paused = p }
        if let vm = decoded.isVirtualMode { self.isVirtualMode = vm }
        if let ln = decoded.layoutName { self.currentLayoutName = ln }
        if let aw = decoded.activeWorkspace { self.activeWorkspace = aw }
        if let wc = decoded.workspaceCount { self.workspaceCount = wc }
        if let keys = decoded.activeWindowKeys {
            self.activeWindowCount = keys.count
            self.activeWindowHandles = Set(keys)
        }
        if let log = decoded.traceLog {
            fputs("\(log)\n", stderr)
        }
        if let obsKeys = decoded.observeWindowKeys {
            for k in obsKeys where !observedWindowHandles.contains(k) {
                if let el = elementByHandle[k], let pid = pidByHandle[k], let observer = observers[pid] {
                    let context = Unmanaged.passUnretained(self).toOpaque()
                    let result = AXObserverAddNotification(observer, el, kAXUIElementDestroyedNotification as CFString, context)
                    if result == .success || result == .notificationAlreadyRegistered {
                        observedWindowHandles.insert(k)
                        AXObserverAddNotification(observer, el, kAXMovedNotification as CFString, context)
                        AXObserverAddNotification(observer, el, kAXResizedNotification as CFString, context)
                    }
                }
            }
        }
        var authoritativeFrames: [UInt64: CGRect]?
        if let generation = decoded.geometryGeneration, generation > geometryGeneration,
           let frames = decoded.windowFrames {
            geometryGeneration = generation
            authoritativeFrames = Dictionary(uniqueKeysWithValues: frames.compactMap { key, rect in
                UInt64(key).map { ($0, rect.cgRect) }
            })
        }
        executeEffects(decoded.effects ?? [], authoritativeFrames: authoritativeFrames)
        return decoded
    }

    @discardableResult
    private func dispatchJSON(_ object: [String: Any]) -> WireManagerActionOutput? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return dispatchData(data)
    }

    private func executeEffects(_ effects: [WireWindowEffect], authoritativeFrames: [UInt64: CGRect]? = nil) {
        var geometries: [WindowGeometry] = []
        var focusAction: (() -> Void)?
        var focusKey: UInt64?
        var focusPID: pid_t?
        for effect in effects {
            switch effect.kind {
            case "setFrame", "setPosition":
                guard let key = effect.key, let pid = pidByHandle[key], let element = elementByHandle[key] else { continue }
                let target: CGRect
                if let rect = effect.rect {
                    target = rect.cgRect
                } else if let x = effect.x, let y = effect.y, let current = frameByHandle[key] {
                    target = CGRect(origin: CGPoint(x: x, y: y), size: current.size)
                } else { continue }
                if authoritativeFrames == nil {
                    discoveryRevision &+= 1
                    geometries.append(geometryRequest(key: key, pid: pid, element: element,
                        target: target, resizable: candidatesByHandle[key]?.isResizable ?? (effect.kind == "setFrame")))
                    lastSubmittedFrames[key] = target
                    cacheFrame(target, for: key, observed: false)
                }
            case "focus":
                guard let key = effect.key, let pid = effect.pid, let element = elementByHandle[key] else { continue }
                focusKey = key
                focusPID = pid
                focusAction = { [weak self] in
                    guard let self, !self.paused, AXIsProcessTrusted(), !isSessionScreenLocked(),
                          self.elementByHandle[key] != nil else { return }
                    _ = self.dispatchJSON(["op": "beginFocusDelivery", "now": Date().timeIntervalSince1970, "key": key])
                    WindowFocus.request(window: element, app: axApplication(pid), pid: pid,
                        legacy: ProcessInfo.processInfo.environment["TALUS_LEGACY_FOCUS"] == "1")
                    self.focusJustDelivered = true
                }
            case "relinquishFocus":
                focusKey = nil
                focusPID = nil
                focusAction = { [weak self] in
                    guard let self, !self.paused, !isSessionScreenLocked() else { return }
                    _ = self.dispatchJSON(["op": "beginFocusDelivery", "now": Date().timeIntervalSince1970])
                    NSApp.activate(ignoringOtherApps: true)
                    self.confirmedFocusKey = nil
                }
            default:
                break
            }
        }
        if let frames = authoritativeFrames {
            let explicit = Set(effects.filter { $0.kind == "setFrame" || $0.kind == "setPosition" }.compactMap(\.key))
            for key in Array(lastSubmittedFrames.keys) where frames[key] == nil {
                windowExecutor.forget(key)
                lastSubmittedFrames.removeValue(forKey: key)
            }
            for (key, target) in frames {
                guard let pid = pidByHandle[key], let element = elementByHandle[key] else { continue }
                if lastSubmittedFrames[key] != target || explicit.contains(key) {
                    discoveryRevision &+= 1
                    geometries.append(geometryRequest(key: key, pid: pid, element: element,
                        target: target, resizable: candidatesByHandle[key]?.isResizable ?? true))
                    lastSubmittedFrames[key] = target
                }
                cacheFrame(target, for: key, observed: false)
            }
        }
        if !geometries.isEmpty || focusAction != nil {
            focusOriginKey = confirmedFocusKey
            externalFocusAllowedDuringLayout = false
        }
        windowExecutor.submit(geometries, focusKey: focusKey, focusPID: focusPID, focusAction: focusAction)
    }

    // A real click supersedes a queued programmatic focus, while geometry still
    // reaches its latest requested position. Subsequent AX events describe that
    // user's intent rather than echoes from the operation we have superseded.
    func notePointerIntent() {
        foregroundCreation = nil
        guard windowExecutor.hasPendingGeometry || windowExecutor.hasPendingFocus else { return }
        cancelPendingFocus()
    }

    private func cancelPendingFocus() {
        windowExecutor.cancelFocus()
        externalFocusAllowedDuringLayout = true
        _ = dispatchJSON(["op": "cancelFocusDelivery"])
    }

    private func deferFocusEvent(key: UInt64?, pid: pid_t?) -> Bool {
        guard windowExecutor.hasPendingGeometry || windowExecutor.hasPendingFocus,
              !externalFocusAllowedDuringLayout else { return false }
        if let key, key == windowExecutor.focusKey { return false }
        if let pid, pid == windowExecutor.focusPID { return true }
        if let key, key == focusOriginKey { return true }
        if key == nil, pid == nil || pid == focusOriginKey.flatMap({ pidByHandle[$0] }) { return true }
        cancelPendingFocus()
        return false
    }

    func statusTitle() -> String {
        guard let key = windowExecutor.focusKey ?? confirmedFocusKey else { return "" }
        let title = titlesByHandle[key] ?? candidatesByHandle[key]?.title ?? ""
        guard !titleReadPending.contains(key),
              Date().timeIntervalSince(titleReadAt[key] ?? .distantPast) > 0.2,
              let element = elementByHandle[key] else { return title }
        titleReadPending.insert(key)
        titleReadAt[key] = Date()
        discoveryQueue.async { [weak self] in
            let value = axValue(element, kAXTitleAttribute as CFString) as? String ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.titleReadPending.remove(key)
                guard self.elementByHandle[key] != nil else { return }
                let changed = self.titlesByHandle[key] != value
                self.titlesByHandle[key] = value
                if changed, (self.windowExecutor.focusKey ?? self.confirmedFocusKey) == key { self.statusChanged?() }
            }
        }
        return title
    }

    func statusSnapshot() -> (
        isVirtualMode: Bool,
        paused: Bool,
        layoutName: String,
        activeWorkspace: Int,
        workspaceCount: Int,
        windowCount: Int,
        focusedScreen: NSScreen?,
        virtualSpaces: [SpaceEntry]
    ) {
        let now = Date().timeIntervalSince1970
        let frontKey = windowExecutor.focusKey ?? confirmedFocusKey
        var req: [String: Any] = ["op": "getStatusSnapshot", "now": now]
        if let frontKey { req["frontmostKey"] = frontKey }
        guard let coreHandle,
              let reqData = try? JSONSerialization.data(withJSONObject: req),
              let reqStr = String(data: reqData, encoding: .utf8)
        else {
            return (isVirtualMode, paused, currentLayoutName, activeWorkspace, workspaceCount, activeWindowCount, NSScreen.main, [])
        }
        let resPtr = reqStr.withCString { talus_manager_dispatch(coreHandle, $0) }
        defer { if let resPtr { talus_string_free(resPtr) } }
        guard let resPtr,
              let outData = String(cString: resPtr).data(using: .utf8),
              let snap = try? JSONDecoder().decode(WireManagerStatusSnapshot.self, from: outData)
        else {
            return (isVirtualMode, paused, currentLayoutName, activeWorkspace, workspaceCount, activeWindowCount, NSScreen.main, [])
        }
        self.isVirtualMode = snap.isVirtualMode
        self.paused = snap.paused
        self.currentLayoutName = snap.layoutName
        self.activeWorkspace = snap.activeWorkspace
        self.workspaceCount = snap.workspaceCount
        self.activeWindowCount = snap.windowCount
        let screens = NSScreen.screens
        let focusedScreen = snap.focusedScreenId.flatMap { screens.indices.contains($0) ? screens[$0] : nil }
            ?? NSScreen.main
            ?? screens.first
        return (
            snap.isVirtualMode,
            snap.paused,
            snap.layoutName,
            snap.activeWorkspace,
            snap.workspaceCount,
            snap.windowCount,
            focusedScreen,
            snap.virtualSpaceEntries
        )
    }

    private func syncSnapshotFromCore() {
        _ = statusSnapshot()
    }

    func recordCurrentSessionState() {
        _ = dispatchJSON(["op": "recordCurrentSessionState"])
    }

    func restoreAllParkedWindows() {
        windowExecutor.finishSynchronously()
        _ = dispatchJSON([
            "op": "restoreAllParkedWindows",
            "trusted": AXIsProcessTrusted(),
            "liveFrames": collectLiveFrames(readAll: true),
        ])
        windowExecutor.finishSynchronously()
    }

    func apply(config: Configuration) {
        if (config.workspaceMode == "virtual") != isVirtualMode { cancelPendingFocus() }
        discoveryRevision &+= 1
        ignoredApps = Set(config.ignoreApps)
        guard let cfgData = try? JSONEncoder().encode(config),
              let cfgObj = try? JSONSerialization.jsonObject(with: cfgData)
        else { return }
        var req: [String: Any] = [
            "op": "applyConfig",
            "config": cfgObj,
            "now": Date().timeIntervalSince1970,
            "trusted": AXIsProcessTrusted(),
            "liveFrames": collectLiveFrames(),
        ]
        if let fk = currentFrontmostWindowHandle() {
            req["frontmostKey"] = fk
        }
        _ = dispatchJSON(req)
        if AXIsProcessTrusted() {
            refresh(force: true)
        }
    }

    func scheduleRefresh(pid: pid_t? = nil, created: AXUIElement? = nil) {
        if ProcessInfo.processInfo.environment["TALUS_TRACE_EVENTS"] == "1" {
            fputs("event \(Date().timeIntervalSince1970)\n", stderr)
        }
        discoveryRevision &+= 1
        readinessRetry?.cancel()
        readinessRetry = nil
        if let created, let pid {
            pendingCreations[AXWindowKey(element: created)] = (pid, Date().addingTimeInterval(0.6))
        }
        if let pid { pendingDiscoveryPIDs.insert(pid) } else { pendingFullDiscovery = true }
        guard scheduledRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledRefresh = nil
            let pids = self.pendingFullDiscovery ? nil : self.pendingDiscoveryPIDs
            self.refresh(onlyPIDs: pids)
        }
        scheduledRefresh = work
        // Coalesce this run-loop turn without adding a fixed input delay.
        DispatchQueue.main.async(execute: work)
    }

    func noteCreatedWindow(_ element: AXUIElement, pid: pid_t) {
        guard WindowFocus.isFrontmost(pid) else { return }
        foregroundCreation = (handle(for: element, pid: pid), pid, Date().addingTimeInterval(1.5))
    }

    func cancelNewWindowFocus() { foregroundCreation = nil }

    func observeApplications() {
        guard AXIsProcessTrusted(), !isSessionScreenLocked() else { return }
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        let live = Set(applications.map(\.processIdentifier))
        windowExecutor.retainApplications(live)
        for pid in observers.keys where !live.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        for application in applications where observers[application.processIdentifier] == nil {
            let pid = application.processIdentifier
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, element, notification, context in
                guard let context else { return }
                let manager = Unmanaged<Manager>.fromOpaque(context).takeUnretainedValue()
                let name = notification as String
                if name == kAXMovedNotification as String || name == kAXResizedNotification as String {
                    if let key = manager.handleByKey[AXWindowKey(element: element)] {
                        manager.dirtyFrameHandles.insert(key)
                    }
                    return
                }
                if name == kAXFocusedWindowChangedNotification as String {
                    manager.handleAXFocusNotification()
                    return
                }
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                if name == kAXWindowCreatedNotification as String, pid != 0 {
                    manager.noteCreatedWindow(element, pid: pid)
                }
                manager.rememberFocus()
                manager.scheduleRefresh(pid: pid == 0 ? nil : pid,
                    created: name == kAXWindowCreatedNotification as String ? element : nil)
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
            let ax = axApplication(pid)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = AXObserverAddNotification(observer, ax, kAXWindowCreatedNotification as CFString, context)
            if result == .success {
                observers[pid] = observer
                AXObserverAddNotification(observer, ax, kAXFocusedWindowChangedNotification as CFString, context)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
    }

    private func currentFrontmostWindowHandle(includePending: Bool = true, cache: Bool = true) -> UInt64? {
        if includePending, let key = windowExecutor.focusKey { return key }
        guard AXIsProcessTrusted(), !isSessionScreenLocked(),
              let pid = WindowFocus.frontmostPID() ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ownPID,
              let focused = axValue(axApplication(pid), kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        if let role = axValue(element, kAXRoleAttribute as CFString) as? String, role != kAXWindowRole as String { return nil }
        let key = handle(for: element, pid: pid)
        if cache { confirmedFocusKey = key }
        return key
    }

    func rememberFocus() {
        var req: [String: Any] = [
            "op": "rememberFocus",
            "now": Date().timeIntervalSince1970,
        ]
        if let fk = currentFrontmostWindowHandle() {
            req["frontmostKey"] = fk
        }
        _ = dispatchJSON(req)
    }

    func handleAXFocusNotification() {
        var req: [String: Any] = [
            "op": "handleAxFocusNotification",
            "now": Date().timeIntervalSince1970,
            "trusted": AXIsProcessTrusted(),
            "locked": isSessionScreenLocked(),
            "liveFrames": [:],
        ]
        let actual = currentFrontmostWindowHandle(includePending: false, cache: false)
        if deferFocusEvent(key: actual, pid: actual.flatMap({ pidByHandle[$0] })) { return }
        confirmedFocusKey = actual
        if let fk = actual {
            req["frontmostKey"] = fk
            if !activeWindowHandles.contains(fk) { req["liveFrames"] = collectLiveFrames() }
            if candidatesByHandle[fk] == nil, let pid = pidByHandle[fk] { scheduleRefresh(pid: pid) }
        }
        if let out = dispatchJSON(req), out.statusChanged == true {
            statusChanged?()
        }
    }

    func handleApplicationActivated(_ app: NSRunningApplication) {
        if app.processIdentifier == ownPID { confirmedFocusKey = nil; return }
        // Activation notifications can arrive after another application became
        // frontmost. Such an old notification must not undo a confirmed switch.
        guard app.processIdentifier != ownPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        var appFocusedKey: UInt64?
        if AXIsProcessTrusted(), !isSessionScreenLocked(),
           let axFocused = axValue(axApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString),
           CFGetTypeID(axFocused) == AXUIElementGetTypeID(),
           (axValue(axFocused as! AXUIElement, kAXRoleAttribute as CFString) as? String ?? (kAXWindowRole as String)) == (kAXWindowRole as String) {
            appFocusedKey = handle(for: axFocused as! AXUIElement, pid: app.processIdentifier)
        }
        if deferFocusEvent(key: appFocusedKey, pid: app.processIdentifier) { return }
        confirmedFocusKey = appFocusedKey
        var req: [String: Any] = [
            "op": "handleApplicationActivated",
            "pid": app.processIdentifier,
            "now": Date().timeIntervalSince1970,
            "trusted": AXIsProcessTrusted(),
            "locked": isSessionScreenLocked(),
            "liveFrames": [:],
        ]
        if let appFocusedKey {
            req["appFocusedKey"] = appFocusedKey
            if !activeWindowHandles.contains(appFocusedKey) { req["liveFrames"] = collectLiveFrames() }
        }
        if let out = dispatchJSON(req), out.statusChanged == true {
            statusChanged?()
        }
    }

    private struct WireRefreshPayload: Encodable {
        let op = "refresh"
        let force: Bool
        let now: Double
        let screens: [WireScreenSpec]
        let candidates: [WireCandidateWindow]
        let busyPids: [Int32]
        let visibleWindowIds: [UInt32]
        let allExistingCgWindowIds: [UInt32]
        let deadHistoryKeys: [UInt64]
        let eligibleVisibleWindowExists: Bool
        let frontmostKey: UInt64?
        let traceEvents: Bool
    }

    func refresh(force: Bool = false, onlyPIDs: Set<pid_t>? = nil) {
        guard !paused, canDiscover() else { return }
        pendingForce = pendingForce || force
        if let onlyPIDs { pendingDiscoveryPIDs.formUnion(onlyPIDs) } else { pendingFullDiscovery = true }
        if discoveryInFlight || windowExecutor.hasPendingGeometry { pendingDiscovery = true; return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        fullScreenBounds = screens.map(fullScreenRect)
        let wireScreens = screens.enumerated().map { idx, scr in
            WireScreenSpec(id: idx, visibleFrame: WireRect(screenRect(scr)), fullFrame: WireRect(fullScreenRect(scr)))
        }
        let scope: Set<pid_t>? = pendingFullDiscovery || candidatesByHandle.isEmpty ? nil : pendingDiscoveryPIDs
        let requestedForce = pendingForce
        pendingFullDiscovery = false
        pendingDiscoveryPIDs.removeAll()
        pendingForce = false
        pendingDiscovery = false
        discoveryInFlight = true
        let revision = discoveryRevision
        let elements = elementByHandle, pids = pidByHandle
        let ignored = ignoredApps, own = ownPID
        let selected = ProcessInfo.processInfo.environment["TALUS_TEST_PID"].map {
            Set($0.split(separator: ",").compactMap { pid_t($0) })
        }
        let discover = discoverSnapshot
        discoveryQueue.async { [weak self] in
            let result = discover(own, ignored, selected, elements, pids, scope)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.discoveryInFlight = false
                guard !self.paused, self.canDiscover() else { return }
                // A key, config change or newer structural event wins over an
                // older scan; never feed stale parked geometry back to the core.
                guard revision == self.discoveryRevision, !self.windowExecutor.hasPendingGeometry else {
                    self.refresh(force: requestedForce, onlyPIDs: scope)
                    return
                }
                self.candidatesByHandle = self.candidatesByHandle.filter { _, candidate in
                    result.livePIDs.contains(candidate.pid)
                        && (result.busyPIDs.contains(candidate.pid) || (scope.map { !$0.contains(candidate.pid) } ?? false))
                }
                for window in result.windows {
                    let key = self.handle(for: window.element, pid: window.pid)
                    self.cacheFrame(window.rect, for: key)
                    self.titlesByHandle[key] = window.title
                    self.candidatesByHandle[key] = WireCandidateWindow(key: key, pid: window.pid,
                        bundleId: window.bundleID, windowId: window.windowID, title: window.title,
                        frame: WireRect(window.rect), isResizable: window.isResizable)
                    self.pendingCreations.removeValue(forKey: AXWindowKey(element: window.element))
                }
                for key in result.deadHandles {
                    if let element = self.elementByHandle.removeValue(forKey: key) {
                        self.handleByKey.removeValue(forKey: AXWindowKey(element: element))
                    }
                    self.pidByHandle.removeValue(forKey: key)
                    self.frameByHandle.removeValue(forKey: key)
                    self.lastSubmittedFrames.removeValue(forKey: key)
                    self.candidatesByHandle.removeValue(forKey: key)
                    self.observedWindowHandles.remove(key)
                    self.dirtyFrameHandles.remove(key)
                    self.failedWriteAttempts.removeValue(forKey: key)
                    self.windowExecutor.forget(key)
                    self.titlesByHandle.removeValue(forKey: key)
                    self.titleReadAt.removeValue(forKey: key)
                    if self.confirmedFocusKey == key { self.confirmedFocusKey = nil }
                }
                if result.staleAPIDisabled { self.onStaleSandboxTCCDetected?() }
                var frontmost = self.currentFrontmostWindowHandle()
                if let created = self.foregroundCreation {
                    if created.until < Date() || !WindowFocus.isFrontmost(created.pid) {
                        self.foregroundCreation = nil
                    } else if self.candidatesByHandle[created.key] != nil {
                        // A queued activation of an older window must not beat
                        // the foreground app's newly created window.
                        _ = self.dispatchJSON(["op": "cancelFocusDelivery"])
                        frontmost = created.key
                        self.foregroundCreation = nil
                    }
                }
                let payload = WireRefreshPayload(force: requestedForce, now: Date().timeIntervalSince1970,
                    screens: wireScreens, candidates: self.candidatesByHandle.values.sorted { $0.key < $1.key },
                    busyPids: Array(result.busyPIDs), visibleWindowIds: result.visibleWindowIDs,
                    allExistingCgWindowIds: result.existingWindowIDs, deadHistoryKeys: result.deadHandles,
                    eligibleVisibleWindowExists: result.eligibleVisibleWindowExists,
                    frontmostKey: frontmost,
                    traceEvents: ProcessInfo.processInfo.environment["TALUS_TRACE_EVENTS"] == "1")
                if let data = try? JSONEncoder().encode(payload) { _ = self.dispatchData(data) }
                self.statusChanged?()
                if self.pendingDiscovery {
                    let next = self.pendingFullDiscovery ? nil : self.pendingDiscoveryPIDs
                    self.refresh(onlyPIDs: next)
                } else {
                    self.pendingCreations = self.pendingCreations.filter { $0.value.until > Date() }
                    if !self.pendingCreations.isEmpty {
                        self.readinessRetry?.cancel()
                        let retry = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            self.readinessRetry = nil
                            self.refresh(onlyPIDs: Set(self.pendingCreations.values.map(\.pid)))
                        }
                        self.readinessRetry = retry
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: retry)
                    }
                }
            }
        }
    }

    func switchWorkspace(_ index: Int) {
        foregroundCreation = nil
        var req: [String: Any] = [
            "op": "switchWorkspace",
            "index": index,
            "now": Date().timeIntervalSince1970,
            "trusted": AXIsProcessTrusted(),
            "liveFrames": collectLiveFrames(),
        ]
        if let fk = currentFrontmostWindowHandle() {
            req["frontmostKey"] = fk
        }
        _ = dispatchJSON(req)
        statusChanged?()
    }

    func moveWindowToWorkspace(_ index: Int) {
        foregroundCreation = nil
        var req: [String: Any] = [
            "op": "moveWindowToWorkspace",
            "index": index,
            "now": Date().timeIntervalSince1970,
            "trusted": AXIsProcessTrusted(),
            "liveFrames": collectLiveFrames(),
        ]
        if let fk = currentFrontmostWindowHandle() {
            req["frontmostKey"] = fk
        }
        _ = dispatchJSON(req)
        statusChanged?()
    }

    func key(_ code: UInt32, shift: Bool) {
        foregroundCreation = nil
        var req: [String: Any] = [
            "op": "handleKey",
            "code": code,
            "shift": shift,
            "now": Date().timeIntervalSince1970,
            "trusted": AXIsProcessTrusted(),
            "liveFrames": (!shift && (code == UInt32(kVK_ANSI_J) || code == UInt32(kVK_ANSI_K))) ? [:] : collectLiveFrames(),
        ]
        if let fk = currentFrontmostWindowHandle() {
            req["frontmostKey"] = fk
        }
        if let out = dispatchJSON(req), let toggled = out.pausedToggled {
            if !toggled {
                refresh(force: true)
            }
            print(toggled ? "Paused" : "Resumed")
        }
    }
}

final class HotkeyRegistry {
    private var refs: [EventHotKeyRef] = []

    func apply(modifiers: [String], workspaceMode: String, workspaceCount: Int) {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        let modifierBits = modifiers.reduce(UInt32(0)) { result, name in
            switch name {
            case "control": return result | UInt32(controlKey)
            case "option": return result | UInt32(optionKey)
            case "command": return result | UInt32(cmdKey)
            default: return result
            }
        }
        let baseCodes = [kVK_ANSI_H, kVK_ANSI_L, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_Space, kVK_Return, kVK_ANSI_P, kVK_ANSI_T]
        for code in baseCodes {
            for shifted in ([kVK_ANSI_J, kVK_ANSI_K].contains(code) ? [false, true] : [false]) {
                registerKey(code: code, modifierBits: modifierBits, shifted: shifted)
            }
        }
        if workspaceMode == "virtual" {
            let clamped = min(9, max(1, workspaceCount))
            for code in workspaceDigitKeyCodes.prefix(clamped) {
                registerKey(code: code, modifierBits: modifierBits, shifted: false)
                registerKey(code: code, modifierBits: modifierBits, shifted: true)
            }
        }
    }

    private func registerKey(code: Int, modifierBits: UInt32, shifted: Bool) {
        var ref: EventHotKeyRef?
        let id = UInt32(code) | (shifted ? 0x10000 : 0)
        let status = RegisterEventHotKey(
            UInt32(code),
            modifierBits | (shifted ? UInt32(shiftKey) : 0),
            EventHotKeyID(signature: 0x4d4f4e44, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr { fputs("Could not register shortcut key \(code): \(status)\n", stderr) }
        if let ref { refs.append(ref) }
    }
}

func reportStartupError(title: String, message: String) -> Never {
    fputs("\(title): \(message)\n", stderr)
    if Bundle.main.bundlePath.hasSuffix(".app") {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        application.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let settingsOnlyMode = args.contains("--settings-only")
let openSettingsOnLaunch = args.contains("--settings") || settingsOnlyMode
let initialTabArg: SettingsTab? = {
    for arg in args where arg.hasPrefix("--tab=") {
        return SettingsTab(rawValue: String(arg.dropFirst("--tab=".count)))
    }
    return nil
}()

var currentResolution = Configuration.resolvePaths()
var currentConfig: Configuration
do {
    currentConfig = try Configuration.load(from: currentResolution.loadURL)
} catch {
    reportStartupError(title: "Talus 配置读取错误", message: "\(currentResolution.loadURL.path)\n\(error)")
}

if settingsOnlyMode {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let controller = SettingsWindowController(config: currentConfig, resolution: currentResolution) { updated, _ in
        currentConfig = updated
    }
    if let tab = initialTabArg {
        controller.viewModel.selectedTab = tab
    }
    controller.onClose = { NSApp.terminate(nil) }
    controller.show()
    app.run()
    exit(0)
}

let supportDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Talus", isDirectory: true)
do { try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true) }
catch { reportStartupError(title: "Talus cannot start", message: "Cannot create \(supportDirectory.path): \(error)") }

let isAutomatedTest = ProcessInfo.processInfo.environment["TALUS_TEST_PID"] != nil
var lockFD: Int32 = -1
if !isAutomatedTest {
    lockFD = open(supportDirectory.appendingPathComponent("talus.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    if lockFD < 0 { reportStartupError(title: "Talus cannot start", message: "Cannot open the application lock file.") }
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        if openSettingsOnLaunch || Bundle.main.bundlePath.hasSuffix(".app") {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("local.talus.openSettings"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            exit(0)
        }
        reportStartupError(title: "Talus is already running", message: "Use the existing Talus menu bar icon to pause, configure, or quit.")
    }
}

let manager = Manager(config: currentConfig)
let hotkeys = HotkeyRegistry()
var settingsController: SettingsWindowController?

func fileModificationDate(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}
var watchedConfigPath = currentResolution.loadURL.path
var watchedConfigMTime = fileModificationDate(currentResolution.loadURL)
var lastReportedReloadMTime: Date?

private final class StatusHoverResponder: NSResponder {
    var onMoved: ((NSEvent) -> Void)?
    var onExited: (() -> Void)?
    override func mouseMoved(with event: NSEvent) { onMoved?(event) }
    override func mouseExited(with event: NSEvent) { onExited?() }
}

final class StatusMenu: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let axWarningItem = NSMenuItem(title: "⚠️ 授予辅助功能权限…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    let axSeparator = NSMenuItem.separator()
    var workspaceMenuItems: [NSMenuItem] = []
    let workspaceSeparator = NSMenuItem.separator()
    let pauseItem = NSMenuItem(title: "暂停平铺", action: #selector(togglePause), keyEquivalent: "")
    let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
    let openFileItem = NSMenuItem(title: "打开配置文件…", action: #selector(openConfigFile), keyEquivalent: "")
    let reloadItem = NSMenuItem(title: "重新加载配置", action: #selector(reloadConfigNow), keyEquivalent: "r")
    let spaces = NativeSpaces()
    var config: Configuration
    var commands: StatusCommands
    var lastExport: Data?
    var lastState: Data?
    var reportedExportError = false
    var cachedParts: [StatusPart]?
    var cachedDark: Bool?
    var cachedHover: Int?
    var lastSpokenStatus = ""
    var workspaceHitRects: [StatusWorkspaceHitRegion] = []
    var hoveredWorkspace: Int?
    private let hoverResponder = StatusHoverResponder()
    private var trackingArea: NSTrackingArea?
    var onOpenSettings: (() -> Void)?
    var onOpenConfigFile: (() -> Void)?
    var onReloadConfig: (() -> Void)?

    init(config: Configuration) {
        self.config = config
        self.commands = StatusCommands(stateFile: config.statusStateFile)
        super.init()
        commands.onChange = { [weak self] in self?.updateStatus() }
        if let button = item.button {
            button.image = makeStatusIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Talus"
            button.target = self
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            installTrackingIfNeeded(on: button)
        }

        menu.delegate = self

        axWarningItem.target = self
        menu.addItem(axWarningItem)
        menu.addItem(axSeparator)

        for idx in 0..<9 {
            let wsItem = NSMenuItem(title: "工作区 \(idx + 1)", action: #selector(selectVirtualWorkspace(_:)), keyEquivalent: "")
            wsItem.tag = idx
            wsItem.target = self
            wsItem.isHidden = true
            workspaceMenuItems.append(wsItem)
            menu.addItem(wsItem)
        }
        workspaceSeparator.isHidden = true
        menu.addItem(workspaceSeparator)

        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        settingsItem.target = self
        menu.addItem(settingsItem)

        openFileItem.target = self
        menu.addItem(openFileItem)

        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Talus", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func installTrackingIfNeeded(on button: NSStatusBarButton) {
        guard trackingArea == nil else { return }
        hoverResponder.onMoved = { [weak self] event in self?.handleMouseMoved(event) }
        hoverResponder.onExited = { [weak self] in self?.setHoveredWorkspace(nil) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hoverResponder,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
    }

    private func workspaceIndex(at event: NSEvent?) -> Int? {
        guard manager.isVirtualMode,
              let button = item.button,
              let event,
              let imageRect = button.cell?.imageRect(forBounds: button.bounds)
        else { return nil }
        let local = button.convert(event.locationInWindow, from: nil)
        guard button.bounds.contains(local) else { return nil }
        let imageX = local.x - imageRect.origin.x
        return workspaceHitRects.first {
            imageX >= $0.rect.minX - 1 && imageX <= $0.rect.maxX + 1
        }?.index
    }

    private func handleMouseMoved(_ event: NSEvent) {
        guard manager.isVirtualMode, !manager.paused, AXIsProcessTrusted() else {
            setHoveredWorkspace(nil)
            return
        }
        setHoveredWorkspace(workspaceIndex(at: event))
    }

    private func setHoveredWorkspace(_ next: Int?) {
        guard hoveredWorkspace != next else { return }
        hoveredWorkspace = next
        updateToolTip()
        renderCurrentImage()
    }

    private func updateToolTip() {
        guard let button = item.button else { return }
        if let ws = hoveredWorkspace, manager.isVirtualMode {
            let label = ws < config.spaceLabels.count ? ":\(config.spaceLabels[ws])" : ""
            button.toolTip = "点击切换到工作区 \(ws + 1)\(label)（右键打开 Talus 菜单）"
        } else if manager.isVirtualMode {
            button.toolTip = "Talus: \(lastSpokenStatus)（点击工作区切换，右键或点图标打开菜单）"
        } else {
            button.toolTip = "Talus: \(lastSpokenStatus)"
        }
    }

    private func renderCurrentImage(force: Bool = false) {
        guard let button = item.button, let parts = cachedParts else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if !force && dark == cachedDark && hoveredWorkspace == cachedHover { return }
        let rendered = renderConfiguredStatus(
            parts: parts,
            dark: dark,
            showIcon: config.statusShowIcon,
            hoveredWorkspace: hoveredWorkspace
        )
        rendered.image.accessibilityDescription = "Talus: \(lastSpokenStatus)"
        button.title = ""; button.image = rendered.image; button.imagePosition = .imageOnly
        workspaceHitRects = rendered.workspaceRegions
        cachedDark = dark
        cachedHover = hoveredWorkspace
    }

    @objc func statusBarClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if !isRightClick,
           manager.isVirtualMode, !manager.paused, AXIsProcessTrusted(),
           let wsIdx = workspaceIndex(at: event) {
            manager.switchWorkspace(wsIdx)
            updateStatus()
            return
        }
        openDropdownMenu()
    }

    private func openDropdownMenu() {
        statusUpdate.flush()
        if hoveredWorkspace != nil {
            hoveredWorkspace = nil
            updateToolTip()
            renderCurrentImage(force: true)
        }
        guard let button = item.button else { return }
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        button.highlight(false)
    }

    func menuDidClose(_ menu: NSMenu) {
        item.button?.highlight(false)
    }

    func apply(config newConfig: Configuration) {
        if newConfig.statusCommands != config.statusCommands || newConfig.statusStateFile != config.statusStateFile {
            commands.stopAll()
            commands = StatusCommands(stateFile: newConfig.statusStateFile)
            commands.onChange = { [weak self] in self?.updateStatus() }
            lastState = nil
        }
        config = newConfig
        cachedParts = nil
        updateStatus()
    }

    private lazy var statusUpdate = MainLoopUpdate { [weak self] in self?.updateStatusNow() }

    func updateStatus() { statusUpdate.request() }

    private func updateStatusNow() {
        let trusted = AXIsProcessTrusted()
        axWarningItem.isHidden = trusted
        axSeparator.isHidden = trusted

        let snap = manager.statusSnapshot()
        let locked = isSessionScreenLocked()
        let needsTitle = (config.statusTemplate ?? "").contains("%title%")
            || config.statusFormat.contains("{title}") || !config.statusCommands.isEmpty
            || !(config.statusStateFile ?? "").isEmpty
        let title = trusted && !locked && needsTitle
            ? (NSApp.isActive ? NSApp.keyWindow?.title ?? "" : manager.statusTitle()) : ""
        let custom = config.statusTextFile.map(readCustomStatus(at:)) ?? ""
        let spaceList = snap.isVirtualMode ? snap.virtualSpaces : spaces.spaces(for: snap.focusedScreen)
        let values = StatusValues(
            spaces: spaceList,
            layout: snap.layoutName,
            title: title,
            count: snap.windowCount,
            custom: custom,
            paused: snap.paused,
            spaceLabels: config.spaceLabels,
            spaceIcons: config.workspaceIcons
        )
        let snapshot = StatusExport(spaces: spaceList, layout: values.layout, title: String(title.prefix(512)), count: values.count, paused: values.paused)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            commands.stateJSON = String(data: data, encoding: .utf8)
            if data != lastState { lastState = data; commands.stateChanged(config.statusCommands) }
            if let path = config.statusStateFile, !path.isEmpty {
                let destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                if data != lastExport || !FileManager.default.fileExists(atPath: destination.path) {
                    do {
                        try writeStatus(data, to: destination)
                        lastExport = data; reportedExportError = false
                    } catch {
                        if !reportedExportError {
                            fputs("Talus status export failed: \(error)\n", stderr)
                            reportedExportError = true
                        }
                    }
                }
            }
        }
        let currentCfg = config
        let parts = templateStatusParts(config: currentCfg, values: values) { [weak self] index in
            guard let self, currentCfg.statusCommands.indices.contains(index) else { return "" }
            return self.commands.value(index: index, block: currentCfg.statusCommands[index])
        }
        let spoken = parts.map { part in
            let token: String
            if let sym = part.symbolName {
                if let ws = part.workspaceIndex, ws < currentCfg.spaceLabels.count {
                    token = currentCfg.spaceLabels[ws]
                } else {
                    token = sym
                }
            } else {
                token = part.text
            }
            return part.isCurrent ? "[\(token)]" : token
        }.joined()
        guard let button = item.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if parts != cachedParts || dark != cachedDark || hoveredWorkspace != cachedHover {
            lastSpokenStatus = spoken
            cachedParts = parts
            renderCurrentImage(force: true)
            updateToolTip()
            if ProcessInfo.processInfo.environment["TALUS_TRACE_STATUS"] == "1" {
                fputs("status: \(spoken)\n", stderr)
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        axWarningItem.isHidden = trusted
        axSeparator.isHidden = trusted

        let snap = manager.statusSnapshot()
        if snap.isVirtualMode {
            let count = snap.workspaceCount
            for (idx, wsItem) in workspaceMenuItems.enumerated() {
                if idx < count {
                    let customLabel = idx < config.spaceLabels.count ? " · \(config.spaceLabels[idx])" : ""
                    let winCount = idx < snap.virtualSpaces.count ? (snap.virtualSpaces[idx].windowCount ?? 0) : 0
                    let suffix = winCount > 0 ? "  (\(winCount))" : ""
                    wsItem.title = "工作区 \(idx + 1)\(customLabel)\(suffix)"
                    wsItem.state = (idx == snap.activeWorkspace) ? .on : .off
                    wsItem.isHidden = false
                } else {
                    wsItem.isHidden = true
                }
            }
            workspaceSeparator.isHidden = false
        } else {
            for wsItem in workspaceMenuItems { wsItem.isHidden = true }
            workspaceSeparator.isHidden = true
        }

        pauseItem.title = snap.paused ? "恢复平铺" : "暂停平铺"
        openFileItem.title = "打开配置文件 (\(abbreviatedPath(currentResolution.saveURL)))"
    }

    @objc func selectVirtualWorkspace(_ sender: NSMenuItem) {
        manager.switchWorkspace(sender.tag)
        updateStatus()
    }
    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func togglePause() { manager.paused.toggle(); if !manager.paused { manager.refresh(force: true) }; updateStatus() }
    @objc func showSettings() { onOpenSettings?() }
    @objc func openConfigFile() { onOpenConfigFile?() }
    @objc func reloadConfigNow() { onReloadConfig?() }
    @objc func quitApp() {
        settingsController?.viewModel.flushPendingSave()
        manager.recordCurrentSessionState()
        manager.restoreAllParkedWindows()
        commands.stopAll()
        NSApp.terminate(nil)
    }
}

let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !isAutomatedTest] as CFDictionary
var wasTrusted = AXIsProcessTrustedWithOptions(opts)
if isAutomatedTest && !wasTrusted {
    reportStartupError(
        title: "Accessibility permission needed",
        message: "Allow Talus in System Settings → Privacy & Security → Accessibility, then reopen Talus."
    )
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusMenu = StatusMenu(config: currentConfig)
manager.statusChanged = { [weak statusMenu] in statusMenu?.updateStatus() }

NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil,
    queue: .main
) { _ in
    settingsController?.viewModel.flushPendingSave()
    manager.recordCurrentSessionState()
    manager.restoreAllParkedWindows()
    statusMenu.commands.stopAll()
}

func applyLiveConfiguration(_ updated: Configuration, resolution: ConfigResolution) {
    let hotkeysNeedUpdate = updated.modifiers != currentConfig.modifiers
        || updated.workspaceMode != currentConfig.workspaceMode
        || updated.workspaceCount != currentConfig.workspaceCount
    currentConfig = updated
    currentResolution = resolution
    manager.apply(config: updated)
    if hotkeysNeedUpdate && (!isAutomatedTest || ProcessInfo.processInfo.environment["TALUS_TEST_HOTKEYS"] == "1") {
        hotkeys.apply(
            modifiers: updated.modifiers,
            workspaceMode: updated.workspaceMode,
            workspaceCount: updated.workspaceCount
        )
    }
    statusMenu.apply(config: updated)
}

func openSettingsWindow() {
    if let existing = settingsController {
        if let tab = initialTabArg { existing.viewModel.selectedTab = tab }
        existing.show()
        return
    }
    let controller = SettingsWindowController(config: currentConfig, resolution: currentResolution) { updated, savedURL in
        let res = ConfigResolution(loadURL: savedURL, saveURL: savedURL, migratedFromJSON: false)
        applyLiveConfiguration(updated, resolution: res)
        watchedConfigPath = savedURL.path
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            watchedConfigMTime = fileModificationDate(savedURL)
        }
    }
    if let tab = initialTabArg { controller.viewModel.selectedTab = tab }
    settingsController = controller
    controller.show()
}

func reloadConfigurationFromDisk(manual: Bool) {
    let nextRes = Configuration.resolvePaths()
    let mtime = fileModificationDate(nextRes.loadURL)
    if !manual {
        if let selfWrite = settingsController?.viewModel.lastWrittenDate,
           Date().timeIntervalSince(selfWrite) < 1.0 {
            watchedConfigPath = nextRes.loadURL.path
            watchedConfigMTime = mtime
            return
        }
        guard nextRes.loadURL.path != watchedConfigPath || mtime != watchedConfigMTime else { return }
    }
    watchedConfigPath = nextRes.loadURL.path
    watchedConfigMTime = mtime
    do {
        let loaded = try Configuration.load(from: nextRes.loadURL)
        if loaded != currentConfig || nextRes != currentResolution || manual {
            applyLiveConfiguration(loaded, resolution: nextRes)
            settingsController?.viewModel.reloadFromExternal(config: loaded, resolution: nextRes)
        }
    } catch {
        if manual || lastReportedReloadMTime != mtime {
            lastReportedReloadMTime = mtime
            fputs("Talus reload failed (\(nextRes.loadURL.path)): \(error)\n", stderr)
        }
    }
}

statusMenu.onOpenSettings = { openSettingsWindow() }
statusMenu.onOpenConfigFile = {
    if !FileManager.default.fileExists(atPath: currentResolution.saveURL.path) {
        try? currentConfig.save(to: currentResolution.saveURL)
        watchedConfigPath = currentResolution.saveURL.path
        watchedConfigMTime = fileModificationDate(currentResolution.saveURL)
    }
    if NSWorkspace.shared.urlForApplication(toOpen: currentResolution.saveURL) != nil {
        NSWorkspace.shared.open(currentResolution.saveURL)
    } else {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-t", currentResolution.saveURL.path]
        try? proc.run()
    }
}
statusMenu.onReloadConfig = { reloadConfigurationFromDisk(manual: true) }

DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("local.talus.openSettings"),
    object: nil,
    queue: .main
) { _ in
    openSettingsWindow()
}

statusMenu.updateStatus()

let handler: EventHandlerUPP = { _, event, _ in
    var hotkey = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
    manager.key(hotkey.id & 0xffff, shift: hotkey.id & 0x10000 != 0)
    statusMenu.updateStatus()
    return noErr
}
var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, nil)
if !isAutomatedTest || ProcessInfo.processInfo.environment["TALUS_TEST_HOTKEYS"] == "1" {
    hotkeys.apply(
        modifiers: currentConfig.modifiers,
        workspaceMode: currentConfig.workspaceMode,
        workspaceCount: currentConfig.workspaceCount
    )
}

func relaunchForFreshTCCSession(reason: String, extraEnv: [String: String] = [:]) -> Never {
    fputs("Talus relaunching for fresh Accessibility audit token (\(reason))...\n", stderr)
    settingsController?.viewModel.flushPendingSave()
    manager.recordCurrentSessionState()
    manager.restoreAllParkedWindows()
    statusMenu.commands.stopAll()
    if lockFD >= 0 {
        _ = flock(lockFD, LOCK_UN)
        _ = close(lockFD)
        lockFD = -1
    }
    let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let proc = Process()
    proc.executableURL = execURL
    proc.arguments = CommandLine.arguments.dropFirst().filter {
        $0 != "--settings" && $0 != "--settings-only" && !$0.hasPrefix("--tab=")
    }
    var env = ProcessInfo.processInfo.environment
    for (k, v) in extraEnv { env[k] = v }
    proc.environment = env
    do {
        try proc.run()
    } catch {
        fputs("Talus relaunch failed: \(error)\n", stderr)
    }
    _exit(0)
}

manager.onStaleSandboxTCCDetected = {
    guard !isAutomatedTest else { return }
    let now = Int(Date().timeIntervalSince1970)
    let lastReexec = ProcessInfo.processInfo.environment["TALUS_API_DISABLED_REEXEC_AT"].flatMap(Int.init) ?? 0
    guard now - lastReexec >= 60 else { return }
    relaunchForFreshTCCSession(
        reason: "per-app kAXErrorAPIDisabled while trusted",
        extraEnv: ["TALUS_API_DISABLED_REEXEC_AT": String(now)]
    )
}

print("Running (\(currentConfig.workspaceMode) mode). \(currentConfig.modifiers.joined(separator: "+"))+P pauses; Control-C quits.")
if wasTrusted {
    manager.observeApplications()
    manager.refresh(force: true)
}

let workspace = NSWorkspace.shared.notificationCenter
let tokens = [
    NSWorkspace.didLaunchApplicationNotification,
    NSWorkspace.didTerminateApplicationNotification,
    NSWorkspace.didHideApplicationNotification,
    NSWorkspace.didUnhideApplicationNotification,
    NSWorkspace.activeSpaceDidChangeNotification,
    NSWorkspace.screensDidWakeNotification,
].map { name in
    workspace.addObserver(forName: name, object: nil, queue: .main) { note in
        manager.observeApplications()
        let changedApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        manager.scheduleRefresh(pid: changedApp?.processIdentifier)
        statusMenu.updateStatus()
        if name == NSWorkspace.activeSpaceDidChangeNotification || name == NSWorkspace.screensDidWakeNotification {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                manager.observeApplications()
                manager.refresh()
                statusMenu.updateStatus()
            }
        }
    }
}
let unlockObserver = DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.apple.screenIsUnlocked"),
    object: nil,
    queue: .main
) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        manager.observeApplications()
        manager.refresh(force: true)
        statusMenu.updateStatus()
    }
}
// Mouse intent cancels a queued focus before AppKit delivers its AX/activation
// notifications. No key logging or additional input-monitoring permission.
let pointerMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
let globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerMask) { _ in
    manager.notePointerIntent()
}
let localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerMask) { event in
    manager.notePointerIntent()
    return event
}

let activationToken = workspace.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { note in
    if let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        manager.handleApplicationActivated(activated)
    }
    statusMenu.updateStatus()
}

// Reconcile windows, Accessibility grant changes, and external dotfile edits.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    let nowTrusted = AXIsProcessTrusted()
    if nowTrusted && !wasTrusted {
        if !isAutomatedTest {
            relaunchForFreshTCCSession(reason: "Accessibility permission granted")
        }
        wasTrusted = true
        manager.observeApplications()
        manager.refresh(force: true)
    } else {
        wasTrusted = nowTrusted
        manager.observeApplications()
        manager.refresh()
    }
    reloadConfigurationFromDisk(manual: false)
    statusMenu.updateStatus()
}

if openSettingsOnLaunch {
    DispatchQueue.main.async { openSettingsWindow() }
}

signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let stopSignals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        settingsController?.viewModel.flushPendingSave()
        manager.recordCurrentSessionState()
        manager.restoreAllParkedWindows()
        statusMenu.commands.stopAll()
        exit(0)
    }
    source.resume()
    return source
}

app.run()
manager.recordCurrentSessionState()
manager.restoreAllParkedWindows()
statusMenu.commands.stopAll()
