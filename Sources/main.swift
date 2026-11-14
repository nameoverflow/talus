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

struct Window {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    let screen: NSScreen
    let isResizable: Bool
    var key: AXWindowKey { AXWindowKey(element: element) }
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

func axValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &result) == .success ? result : nil
}

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = axValue(e, kAXPositionAttribute as CFString),
          let s = axValue(e, kAXSizeAttribute as CFString),
          CFGetTypeID(p) == AXValueGetTypeID(),
          CFGetTypeID(s) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
          AXValueGetValue(s as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: point, size: size)
}

func setFrame(_ e: AXUIElement, _ r: CGRect) {
    var p = r.origin; var s = r.size
    if let position = AXValueCreate(.cgPoint, &p), let size = AXValueCreate(.cgSize, &s) {
        AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, size)
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, size)
    }
}

func setPosition(_ e: AXUIElement, _ origin: CGPoint) {
    var p = origin
    if let position = AXValueCreate(.cgPoint, &p) {
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, position)
    }
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

final class Manager {
    var windows: [Window] = []
    var history: [Window] = []
    var floating: Set<AXWindowKey> = []
    var savedFrames: [AXWindowKey: CGRect] = [:]
    var homeScreens: [AXWindowKey: NSScreen] = [:]
    var parkedKeys: Set<AXWindowKey> = []
    var windowByKey: [AXWindowKey: Window] = [:]

    var workspaceMode: String
    let virtualEngine: VirtualWorkspaceEngine<AXWindowKey>
    private var virtualSeeded = false
    var suppressExternalFocusUntil: Date = .distantPast

    private var nativeRatio: Double
    private var nativeMasters: Int
    private var nativeLayoutMode = 0

    var paused = false
    var ignoredApps: Set<String>
    var appWorkspaces: [String: WorkspaceTarget]
    var spaceLabels: [String]
    var ratioStep: Double
    let ownPID = ProcessInfo.processInfo.processIdentifier

    var isVirtualMode: Bool { workspaceMode == "virtual" }

    func isFloating(_ w: Window) -> Bool {
        !w.isResizable || floating.contains(w.key)
    }

    var currentLayoutMode: Int {
        get { isVirtualMode ? virtualEngine.activeLayout.layoutMode : nativeLayoutMode }
        set {
            if isVirtualMode { virtualEngine.activeLayout.layoutMode = newValue }
            else { nativeLayoutMode = newValue }
        }
    }

    var currentRatio: Double {
        get { isVirtualMode ? virtualEngine.activeLayout.ratio : nativeRatio }
        set {
            if isVirtualMode { virtualEngine.activeLayout.ratio = newValue }
            else { nativeRatio = newValue }
        }
    }

    var currentMasters: Int {
        get { isVirtualMode ? virtualEngine.activeLayout.masters : nativeMasters }
        set {
            if isVirtualMode { virtualEngine.activeLayout.masters = newValue }
            else { nativeMasters = newValue }
        }
    }

    init(config: Configuration) {
        workspaceMode = config.workspaceMode
        nativeRatio = config.masterRatio
        nativeMasters = config.masterCount
        ratioStep = config.ratioStep
        ignoredApps = Set(config.ignoreApps)
        appWorkspaces = config.appWorkspaces
        spaceLabels = config.spaceLabels
        virtualEngine = VirtualWorkspaceEngine(
            count: config.workspaceCount,
            defaultRatio: config.masterRatio,
            defaultMasters: config.masterCount
        )
    }

    func assignedWorkspace(for bundleID: String?) -> Int? {
        guard let bundleID, let target = appWorkspaces[bundleID] else { return nil }
        return target.resolve(workspaceCount: virtualEngine.count, spaceLabels: spaceLabels)
    }

    func apply(config: Configuration) {
        let wasVirtual = isVirtualMode
        let willBeVirtual = (config.workspaceMode == "virtual")

        var previousResolved: [String: Int] = [:]
        for (bundle, target) in appWorkspaces {
            if let ws = target.resolve(workspaceCount: virtualEngine.count, spaceLabels: spaceLabels) {
                previousResolved[bundle] = ws
            }
        }

        nativeRatio = config.masterRatio
        nativeMasters = config.masterCount
        ratioStep = config.ratioStep
        ignoredApps = Set(config.ignoreApps)
        appWorkspaces = config.appWorkspaces
        spaceLabels = config.spaceLabels
        virtualEngine.updateDefaults(ratio: config.masterRatio, masters: config.masterCount)
        virtualEngine.resizeCount(to: config.workspaceCount)

        if wasVirtual && !willBeVirtual {
            restoreAllParkedWindows()
            workspaceMode = "native"
            virtualSeeded = false
        } else if !wasVirtual && willBeVirtual {
            workspaceMode = "virtual"
            virtualSeeded = false
        } else {
            workspaceMode = config.workspaceMode
            if willBeVirtual && virtualSeeded {
                var movedAny = false
                for (bundle, target) in appWorkspaces {
                    guard let newWS = target.resolve(workspaceCount: virtualEngine.count, spaceLabels: spaceLabels),
                          previousResolved[bundle] != newWS
                    else { continue }
                    let matchingKeys = virtualEngine.allWindows.filter { windowByKey[$0]?.bundleID == bundle }
                    for key in matchingKeys where virtualEngine.workspace(containing: key) != newWS {
                        if virtualEngine.moveWindow(key, to: newWS).moved {
                            movedAny = true
                        }
                    }
                }
                if movedAny {
                    suppressExternalFocusUntil = Date().addingTimeInterval(0.5)
                    windows = virtualEngine.activeWindows.compactMap { windowByKey[$0] }
                    if AXIsProcessTrusted() {
                        tile()
                        if let nextKey = virtualEngine.activeFocused, let nextWin = windowByKey[nextKey] {
                            focus(nextWin)
                        } else if windows.isEmpty {
                            relinquishFocusForEmptyWorkspace()
                        }
                    }
                }
            }
        }

        if AXIsProcessTrusted() {
            refresh(force: true)
        }
    }

    var observers: [pid_t: AXObserver] = [:]
    var statusChanged: (() -> Void)?
    var onStaleSandboxTCCDetected: (() -> Void)?
    var lastFocused: AXUIElement?
    var scheduled = false

    func scheduleRefresh() {
        if ProcessInfo.processInfo.environment["TALUS_TRACE_EVENTS"] == "1" {
            fputs("event \(Date().timeIntervalSince1970)\n", stderr)
        }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.refresh()
            // AX can announce a window before Core Graphics lists its frame.
            // Retry briefly so we do not wait for the two-second reconciliation.
            for delay in [0.15, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
            }
        }
    }

    func observeApplications() {
        guard AXIsProcessTrusted(), !isSessionScreenLocked() else { return }
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        let live = Set(applications.map(\.processIdentifier))
        for pid in observers.keys where !live.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        for application in applications where observers[application.processIdentifier] == nil {
            let pid = application.processIdentifier
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, notification, context in
                guard let context else { return }
                let manager = Unmanaged<Manager>.fromOpaque(context).takeUnretainedValue()
                if notification as String == kAXFocusedWindowChangedNotification as String {
                    manager.handleAXFocusNotification()
                } else {
                    manager.rememberFocus()
                }
                manager.scheduleRefresh()
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
            let ax = AXUIElementCreateApplication(pid)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = AXObserverAddNotification(observer, ax, kAXWindowCreatedNotification as CFString, context)
            if result == .success {
                observers[pid] = observer
                AXObserverAddNotification(observer, ax, kAXFocusedWindowChangedNotification as CFString, context)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
    }

    private func currentFrontmostAXWindow() -> AXWindowKey? {
        guard AXIsProcessTrusted(), !isSessionScreenLocked(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID,
              let focused = axValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let el = focused as! AXUIElement
        if let role = axValue(el, kAXRoleAttribute as CFString) as? String, role != (kAXWindowRole as String) {
            return nil
        }
        return AXWindowKey(element: el)
    }

    func handleAXFocusNotification() {
        guard isVirtualMode, !paused, AXIsProcessTrusted(), !isSessionScreenLocked(), Date() >= suppressExternalFocusUntil else {
            rememberFocus()
            return
        }
        if let frontKey = currentFrontmostAXWindow(),
           virtualEngine.handleExternalFocus(frontKey) != nil {
            lastFocused = frontKey.element
            windows = virtualEngine.activeWindows.compactMap { windowByKey[$0] }
            tile()
            if let win = windowByKey[frontKey] {
                focus(win)
            }
            statusChanged?()
            return
        }
        rememberFocus()
    }

    func handleApplicationActivated(_ app: NSRunningApplication) {
        guard isVirtualMode, !paused, AXIsProcessTrusted(), !isSessionScreenLocked(),
              app.processIdentifier != ownPID,
              Date() >= suppressExternalFocusUntil
        else { return }

        let targetKey: AXWindowKey?
        if let axFocused = axValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString),
           CFGetTypeID(axFocused) == AXUIElementGetTypeID(),
           (axValue(axFocused as! AXUIElement, kAXRoleAttribute as CFString) as? String ?? (kAXWindowRole as String)) == (kAXWindowRole as String) {
            targetKey = AXWindowKey(element: axFocused as! AXUIElement)
        } else {
            // Fallback: if app has a tracked window on an inactive workspace and none on active
            let appKeys = virtualEngine.allWindows.filter { windowByKey[$0]?.pid == app.processIdentifier }
            if !appKeys.contains(where: { virtualEngine.activeWindows.contains($0) }) {
                targetKey = appKeys.first
            } else {
                targetKey = nil
            }
        }

        if let targetKey, virtualEngine.handleExternalFocus(targetKey) != nil {
            lastFocused = targetKey.element
            windows = virtualEngine.activeWindows.compactMap { windowByKey[$0] }
            tile()
            if let win = windowByKey[targetKey] {
                focus(win)
            }
            statusChanged?()
        }
    }

    private func centeredFrame(size: CGSize, on screen: NSScreen) -> CGRect {
        let area = screenRect(screen)
        let w = min(max(240, size.width), area.width * 0.9)
        let h = min(max(180, size.height), area.height * 0.9)
        return CGRect(
            x: area.minX + ((area.width - w) / 2).rounded(),
            y: area.minY + ((area.height - h) / 2).rounded(),
            width: w,
            height: h
        )
    }

    private func centeredOrigin(windowSize: CGSize, on screen: NSScreen) -> CGPoint {
        let area = screenRect(screen)
        return CGPoint(
            x: max(area.minX, area.minX + ((area.width - windowSize.width) / 2).rounded()),
            y: max(area.minY, area.minY + ((area.height - windowSize.height) / 2).rounded())
        )
    }

    func restoreAllParkedWindows() {
        guard AXIsProcessTrusted() else {
            parkedKeys.removeAll()
            return
        }
        var keysToRestore = parkedKeys
        for (key, win) in windowByKey {
            if let f = frame(win.element), isParkedWindowFrame(f, screen: fullScreenRect(win.screen)) {
                keysToRestore.insert(key)
            }
        }
        for key in keysToRestore {
            let win = windowByKey[key]
            let screen = win?.screen ?? homeScreens[key] ?? NSScreen.main ?? NSScreen.screens.first
            let resizable = win?.isResizable ?? true
            if let saved = savedFrames[key] {
                if resizable {
                    setFrame(key.element, saved)
                } else {
                    setPosition(key.element, saved.origin)
                }
            } else if let screen, let f = frame(key.element) {
                if resizable {
                    setFrame(key.element, centeredFrame(size: f.size, on: screen))
                } else {
                    setPosition(key.element, centeredOrigin(windowSize: f.size, on: screen))
                }
            }
        }
        parkedKeys.removeAll()
    }

    func refresh(force: Bool = false) {
        guard !paused, AXIsProcessTrusted(), !isSessionScreenLocked() else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visible: [VisibleWindowCandidate] = list.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0
                && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
        }.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  rect.width > 100, rect.height > 80
            else { return nil }
            let wid = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            return VisibleWindowCandidate(pid: pid, windowID: wid, bounds: rect)
        }

        var found: [Window] = []
        var nextMap: [AXWindowKey: Window] = [:]
        var sawStaleSandboxAPIDisabled = false
        var eligibleVisibleWindowExists = false

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            if app.processIdentifier == ownPID { continue }
            if let selectedPIDs = ProcessInfo.processInfo.environment["TALUS_TEST_PID"] {
                let allowed = selectedPIDs.split(separator: ",").map(String.init)
                if !allowed.contains(String(app.processIdentifier)) { continue }
            }
            if let bundle = app.bundleIdentifier, ignoredApps.contains(bundle) { continue }
            let appHasVisibleCGWindow = visible.contains { $0.pid == app.processIdentifier }
            if appHasVisibleCGWindow {
                eligibleVisibleWindowExists = true
            }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            var rawWindows: CFTypeRef?
            let winErr = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &rawWindows)
            if winErr == .apiDisabled && appHasVisibleCGWindow {
                sawStaleSandboxAPIDisabled = true
            }
            guard winErr == .success, let elements = rawWindows as? [AXUIElement] else { continue }
            for e in elements {
                if let role = axValue(e, kAXRoleAttribute as CFString) as? String,
                   role != (kAXWindowRole as String) {
                    continue
                }
                var axWid: CGWindowID = 0
                let resolvedWid: UInt32? = (_AXUIElementGetWindow(e, &axWid) == .success && axWid != 0) ? axWid : nil
                guard var f = frame(e), f.width > 100, f.height > 80,
                      matchesVisibleWindow(
                          pid: app.processIdentifier,
                          axWindowID: resolvedWid,
                          axFrame: f,
                          candidates: visible
                      )
                else { continue }

                let key = AXWindowKey(element: e)
                let resolvedScreen: NSScreen?
                if let home = homeScreens[key], screens.contains(home), isParkedWindowFrame(f, screen: fullScreenRect(home)) {
                    resolvedScreen = home
                } else {
                    resolvedScreen = screens.max(by: { fullScreenRect($0).intersection(f).area < fullScreenRect($1).intersection(f).area })
                }
                guard let screen = resolvedScreen, fullScreenRect(screen).intersects(f) else { continue }

                if let sub = axValue(e, kAXSubroleAttribute as CFString) as? String, sub != kAXStandardWindowSubrole as String { continue }
                if (axValue(e, kAXModalAttribute as CFString) as? Bool) == true { continue }
                var canMove = DarwinBoolean(false); var canResize = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(e, kAXPositionAttribute as CFString, &canMove) == .success,
                      canMove.boolValue
                else { continue }
                let isResizable = (AXUIElementIsAttributeSettable(e, kAXSizeAttribute as CFString, &canResize) == .success && canResize.boolValue)
                if !isVirtualMode && !isResizable { continue }

                let parkedNow = isParkedWindowFrame(f, screen: fullScreenRect(screen))
                // Crash-recovery: if a window was stranded at a 1px corner from an earlier session, rescue it
                if parkedNow && !parkedKeys.contains(key) {
                    if isResizable {
                        let rescued = savedFrames[key] ?? centeredFrame(size: f.size, on: screen)
                        setFrame(e, rescued)
                        f = rescued
                    } else {
                        let origin = savedFrames[key]?.origin ?? centeredOrigin(windowSize: f.size, on: screen)
                        setPosition(e, origin)
                        f.origin = origin
                    }
                } else if !parkedNow {
                    homeScreens[key] = screen
                    if savedFrames[key] == nil || floating.contains(key) || !isResizable {
                        savedFrames[key] = f
                    }
                }

                let win = Window(
                    element: e,
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier,
                    screen: screen,
                    isResizable: isResizable
                )
                found.append(win)
                nextMap[key] = win
            }
        }

        if sawStaleSandboxAPIDisabled {
            onStaleSandboxTCCDetected?()
        }

        // If the session just unlocked and CGWindowList shows eligible windows,
        // wait until AX exposes them before wiping an established virtual workspace session.
        if isVirtualMode && found.isEmpty && eligibleVisibleWindowExists && virtualSeeded && !virtualEngine.allWindows.isEmpty {
            return
        }

        windowByKey = nextMap

        for win in found {
            if let observer = observers[win.pid] {
                AXObserverAddNotification(
                    observer,
                    win.element,
                    kAXUIElementDestroyedNotification as CFString,
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
        }

        if isVirtualMode {
            let frontKey = Date() >= suppressExternalFocusUntil ? currentFrontmostAXWindow() : nil
            if !virtualSeeded && (!found.isEmpty || !eligibleVisibleWindowExists) {
                var orderedSeed = orderUsingHistory(found, history: history) { CFEqual($0.element, $1.element) }
                for w in found where !orderedSeed.contains(where: { CFEqual($0.element, w.element) }) {
                    orderedSeed.append(w)
                }
                virtualEngine.seedFromCurrentDesktop(
                    orderedSeed.map(\.key),
                    focused: frontKey,
                    assignedWorkspace: { [nextMap, weak self] key in
                        self?.assignedWorkspace(for: nextMap[key]?.bundleID)
                    }
                )
                virtualSeeded = true
            }

            let switchedExternally = frontKey.flatMap { virtualEngine.handleExternalFocus($0) } != nil
            let rec = virtualEngine.reconcile(
                discovered: found.map(\.key),
                currentlyFocused: frontKey,
                assignedWorkspace: { [nextMap, weak self] key in
                    self?.assignedWorkspace(for: nextMap[key]?.bundleID)
                },
                canInsertBeforeFocus: { [nextMap] newKey, anchorKey in
                    nextMap[newKey]?.screen == nextMap[anchorKey]?.screen
                }
            )
            let stacksChanged = rec.changed
            if !rec.autoShiftedOffActive.isEmpty {
                suppressExternalFocusUntil = Date().addingTimeInterval(0.65)
            }

            let nextActiveWindows = virtualEngine.activeWindows.compactMap { nextMap[$0] }
            let activeChanged = nextActiveWindows.count != windows.count || zip(nextActiveWindows, windows).contains {
                !CFEqual($0.element, $1.element) || $0.screen != $1.screen || $0.isResizable != $1.isResizable
            }

            windows = nextActiveWindows
            if let focused = virtualEngine.activeFocused {
                lastFocused = focused.element
            }
            updateHistory(aliveKeys: Set(nextMap.keys))

            if ProcessInfo.processInfo.environment["TALUS_TRACE_EVENTS"] == "1" {
                fputs("refresh(virtual) ws=\(virtualEngine.active + 1) active=\(windows.count) total=\(found.count) changed=\(stacksChanged || activeChanged)\n", stderr)
            }

            if stacksChanged || activeChanged || switchedExternally || force {
                tile()
            }
            if !rec.autoShiftedOffActive.isEmpty {
                let rawFront = currentFrontmostAXWindow()
                if rawFront == nil || rec.autoShiftedOffActive.contains(rawFront!) {
                    if let activeFocus = virtualEngine.activeFocused, let win = nextMap[activeFocus] {
                        focus(win)
                    } else if windows.isEmpty {
                        relinquishFocusForEmptyWorkspace()
                    }
                }
            }
            statusChanged?()
            return
        }

        // Native Spaces mode: preserve stack order when AX returns windows in a different order.
        var ordered = orderUsingHistory(found, history: history) { CFEqual($0.element, $1.element) }
        for w in found where !history.contains(where: { CFEqual($0.element, w.element) }) {
            ordered.removeAll { CFEqual($0.element, w.element) }
            if let focused = lastFocused,
               let index = ordered.firstIndex(where: { $0.screen == w.screen && CFEqual($0.element, focused) }) {
                ordered.insert(w, at: index)
            } else {
                ordered.append(w)
            }
        }
        let changed = ordered.count != windows.count || zip(ordered, windows).contains { !CFEqual($0.element, $1.element) || $0.screen != $1.screen }
        if ProcessInfo.processInfo.environment["TALUS_TRACE_EVENTS"] == "1" {
            fputs("refresh \(Date().timeIntervalSince1970) windows=\(ordered.count) changed=\(changed)\n", stderr)
        }
        windows = ordered
        rememberFocus()
        updateHistory(aliveKeys: nil)
        if changed || force { tile() }
        statusChanged?()
    }

    func updateHistory(aliveKeys: Set<AXWindowKey>?) {
        history.removeAll { axValue($0.element, kAXRoleAttribute as CFString) == nil }
        history = mergeHistory(history, current: windows) { CFEqual($0.element, $1.element) }
        let knownAlive: Set<AXWindowKey>
        if let aliveKeys {
            knownAlive = aliveKeys.union(history.map(\.key))
        } else {
            knownAlive = Set(history.map(\.key))
        }
        floating = floating.filter { knownAlive.contains($0) }
        savedFrames = savedFrames.filter { knownAlive.contains($0.key) }
        homeScreens = homeScreens.filter { knownAlive.contains($0.key) }
        parkedKeys = parkedKeys.filter { knownAlive.contains($0) }
    }

    func tile() {
        let screens = NSScreen.screens
        let mode = currentLayoutMode
        let ratio = currentRatio
        let masters = currentMasters

        // 1. Unpark any floating (or fixed-size) windows belonging to the active workspace
        if isVirtualMode {
            for w in windows where isFloating(w) {
                let fullAX = fullScreenRect(w.screen)
                if parkedKeys.contains(w.key) || (frame(w.element).map { isParkedWindowFrame($0, screen: fullAX) } ?? false) {
                    if w.isResizable {
                        let restored = savedFrames[w.key] ?? centeredFrame(size: frame(w.element)?.size ?? CGSize(width: 800, height: 600), on: w.screen)
                        setFrame(w.element, restored)
                    } else {
                        let currentSize = frame(w.element)?.size ?? savedFrames[w.key]?.size ?? CGSize(width: 800, height: 600)
                        let origin = savedFrames[w.key]?.origin ?? centeredOrigin(windowSize: currentSize, on: w.screen)
                        setPosition(w.element, origin)
                    }
                    parkedKeys.remove(w.key)
                }
            }
        }

        // 2. Tile resizable non-floating windows on each display
        for screen in screens {
            let group = windows.filter { window in
                window.screen == screen && !isFloating(window)
            }
            guard !group.isEmpty else { continue }
            let area = screenRect(screen)
            let rect = Rect(x: area.minX, y: area.minY, w: area.width, h: area.height)
            let rects: [Rect]?
            switch mode {
            case 1: rects = mirrorTallLayout(rect, group.count, masters, ratio)
            case 2: rects = Array(repeating: rect, count: group.count)
            default: rects = tallLayout(rect, group.count, masters, ratio)
            }
            guard let rects else { continue }
            let current = focusedIndex().map { windows[$0] }
            for (w, r) in zip(group, rects) {
                setFrame(w.element, CGRect(x: r.x, y: r.y, width: r.w, height: r.h))
                parkedKeys.remove(w.key)
            }
            if mode == 2, let current, current.screen == screen { focus(current) }
        }

        // 3. Park windows belonging to inactive virtual workspaces at 1px corner
        if isVirtualMode {
            let allFullRects = screens.map(fullScreenRect)
            for key in virtualEngine.inactiveWindows {
                guard let w = windowByKey[key], let f = frame(w.element) else { continue }
                let fullAX = fullScreenRect(w.screen)
                if !isParkedWindowFrame(f, screen: fullAX) {
                    if !w.isResizable || floating.contains(key) || savedFrames[key] == nil {
                        savedFrames[key] = f
                    }
                    let origin = parkedWindowOrigin(windowSize: f.size, screen: fullAX, allScreens: allFullRects)
                    setPosition(w.element, origin)
                }
                parkedKeys.insert(key)
            }
        }
    }

    func rememberFocus() {
        guard AXIsProcessTrusted(), !isSessionScreenLocked(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID,
              let focused = axValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString),
              let window = windows.first(where: { CFEqual($0.element, focused) })
        else { return }
        lastFocused = window.element
        if isVirtualMode {
            virtualEngine.setActiveFocus(window.key)
        }
    }

    func focusedIndex() -> Int? {
        if AXIsProcessTrusted(), !isSessionScreenLocked(),
           let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ownPID,
           let e = axValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString),
           let idx = windows.firstIndex(where: { CFEqual($0.element, e) }) {
            return idx
        }
        if isVirtualMode, let remembered = virtualEngine.activeFocused {
            return windows.firstIndex { $0.key == remembered }
        }
        return nil
    }

    func focus(_ w: Window) {
        lastFocused = w.element
        if isVirtualMode {
            virtualEngine.setActiveFocus(w.key)
        }
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(w.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func relinquishFocusForEmptyWorkspace() {
        lastFocused = nil
        NSApp.activate(ignoringOtherApps: true)
    }

    func switchWorkspace(_ index: Int) {
        guard isVirtualMode, !paused, AXIsProcessTrusted() else { return }
        guard (0..<virtualEngine.count).contains(index) else { return }
        rememberFocus()
        suppressExternalFocusUntil = Date().addingTimeInterval(0.45)

        let changed = virtualEngine.switchTo(index)
        if changed {
            windows = virtualEngine.activeWindows.compactMap { windowByKey[$0] }
            tile()
        }
        if let targetKey = virtualEngine.activeFocused, let targetWin = windowByKey[targetKey] {
            focus(targetWin)
        } else if windows.isEmpty {
            relinquishFocusForEmptyWorkspace()
        }
        statusChanged?()
    }

    func moveWindowToWorkspace(_ index: Int) {
        guard isVirtualMode, !paused, AXIsProcessTrusted() else { return }
        guard (0..<virtualEngine.count).contains(index) else { return }
        guard let i = focusedIndex() else { return }
        let moving = windows[i]
        suppressExternalFocusUntil = Date().addingTimeInterval(0.45)

        let outcome = virtualEngine.moveWindow(moving.key, to: index)
        guard outcome.moved else { return }

        windows = virtualEngine.activeWindows.compactMap { windowByKey[$0] }
        tile()

        if let nextKey = outcome.nextFocusOnActive, let nextWin = windowByKey[nextKey] {
            focus(nextWin)
        } else {
            relinquishFocusForEmptyWorkspace()
        }
        statusChanged?()
    }

    func virtualSpaceEntries() -> [SpaceEntry] {
        (0..<virtualEngine.count).map { idx in
            let count = virtualEngine.windowCount(in: idx)
            let isFull = virtualEngine.layouts[idx].layoutMode == 2 && count > 0
            return SpaceEntry(
                id: UInt64(idx + 1),
                isCurrent: idx == virtualEngine.active,
                isFullscreen: isFull,
                windowCount: count
            )
        }
    }

    private func syncActiveVirtualStackFromWindows() {
        if isVirtualMode {
            virtualEngine.replaceActiveStack(windows.map(\.key))
        }
    }

    func key(_ code: UInt32, shift: Bool) {
        if code == UInt32(kVK_ANSI_P) {
            paused.toggle()
            if !paused { refresh(force: true) }
            print(paused ? "Paused" : "Resumed")
            return
        }
        guard !paused, AXIsProcessTrusted() else { return }

        if isVirtualMode, let digitIndex = workspaceDigitKeyCodes.firstIndex(of: Int(code)), digitIndex < virtualEngine.count {
            if shift {
                moveWindowToWorkspace(digitIndex)
            } else {
                switchWorkspace(digitIndex)
            }
            return
        }

        switch code {
        case UInt32(kVK_ANSI_T):
            guard let i = focusedIndex(), windows[i].isResizable else { return }
            let win = windows[i]
            if floating.contains(win.key) {
                if let current = frame(win.element), !isParkedWindowFrame(current, screen: fullScreenRect(win.screen)) {
                    savedFrames[win.key] = current
                }
                floating.remove(win.key)
                tile()
            } else {
                floating.insert(win.key)
                tile()
                let restored = savedFrames[win.key] ?? centeredFrame(size: CGSize(width: 860, height: 600), on: win.screen)
                setFrame(win.element, restored)
                focus(win)
            }
        case UInt32(kVK_ANSI_H):
            currentRatio = max(0.2, currentRatio - ratioStep)
            tile()
        case UInt32(kVK_ANSI_L):
            currentRatio = min(0.8, currentRatio + ratioStep)
            tile()
        case UInt32(kVK_ANSI_Comma):
            currentMasters += 1
            tile()
        case UInt32(kVK_ANSI_Period):
            currentMasters = max(1, currentMasters - 1)
            tile()
        case UInt32(kVK_Space):
            currentLayoutMode = (currentLayoutMode + 1) % 3
            tile()
        case UInt32(kVK_ANSI_J), UInt32(kVK_ANSI_K):
            guard let i = focusedIndex(), windows.count > 1 else { return }
            if shift {
                // Swap operates on tiled (resizable, non-floating) windows on the focused display
                let indices = windows.indices.filter {
                    windows[$0].screen == windows[i].screen && !isFloating(windows[$0])
                }
                guard let p = indices.firstIndex(of: i), indices.count > 1 else { return }
                let next = indices[(p + (code == UInt32(kVK_ANSI_J) ? 1 : indices.count - 1)) % indices.count]
                let direction = code == UInt32(kVK_ANSI_J) ? 1 : -1
                if (direction > 0 && p == indices.count - 1) || (direction < 0 && p == 0) {
                    var group = indices.map { windows[$0] }
                    if direction > 0 { group.insert(group.removeLast(), at: 0) }
                    else { group.append(group.removeFirst()) }
                    for (index, window) in zip(indices, group) { windows[index] = window }
                } else {
                    windows.swapAt(i, next)
                }
                syncActiveVirtualStackFromWindows()
                updateHistory(aliveKeys: isVirtualMode ? Set(windowByKey.keys) : nil)
                tile()
            } else {
                let indices = windows.indices.filter { windows[$0].screen == windows[i].screen }
                guard let p = indices.firstIndex(of: i), indices.count > 1 else { return }
                let next = indices[(p + (code == UInt32(kVK_ANSI_J) ? 1 : indices.count - 1)) % indices.count]
                focus(windows[next])
                if currentLayoutMode == 2 { tile() }
            }
        case UInt32(kVK_Return):
            guard let i = focusedIndex(),
                  !isFloating(windows[i]),
                  let first = windows.indices.first(where: {
                      windows[$0].screen == windows[i].screen && !isFloating(windows[$0])
                  }),
                  first != i
            else { return }
            windows.swapAt(i, first)
            syncActiveVirtualStackFromWindows()
            updateHistory(aliveKeys: isVirtualMode ? Set(windowByKey.keys) : nil)
            tile()
        default: break
        }
    }
}

extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

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

    func updateStatus() {
        let trusted = AXIsProcessTrusted()
        axWarningItem.isHidden = trusted
        axSeparator.isHidden = trusted

        let screen = manager.focusedIndex().map { manager.windows[$0].screen } ?? NSScreen.main ?? NSScreen.screens.first
        let locked = isSessionScreenLocked()
        let frontmost = locked ? nil : NSWorkspace.shared.frontmostApplication
        let frontWindow = (trusted && !locked) ? frontmost.flatMap { axValue(AXUIElementCreateApplication($0.processIdentifier), kAXFocusedWindowAttribute as CFString) } : nil
        let title: String
        if let frontWindow, CFGetTypeID(frontWindow) == AXUIElementGetTypeID() {
            title = axValue(frontWindow as! AXUIElement, kAXTitleAttribute as CFString) as? String ?? ""
        } else {
            title = ""
        }
        let names = ["Tall", "Mirror", "Full"]
        let custom = config.statusTextFile.map(readCustomStatus(at:)) ?? ""
        let spaceList = manager.isVirtualMode ? manager.virtualSpaceEntries() : spaces.spaces(for: screen)
        let values = StatusValues(
            spaces: spaceList,
            layout: names[manager.currentLayoutMode],
            title: title,
            count: manager.windows.count,
            custom: custom,
            paused: manager.paused,
            spaceLabels: config.spaceLabels
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
        let spoken = parts.map { $0.isCurrent ? "[\($0.text)]" : $0.text }.joined()
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

        if manager.isVirtualMode {
            let count = manager.virtualEngine.count
            for (idx, wsItem) in workspaceMenuItems.enumerated() {
                if idx < count {
                    let customLabel = idx < config.spaceLabels.count ? " · \(config.spaceLabels[idx])" : ""
                    let winCount = manager.virtualEngine.windowCount(in: idx)
                    let suffix = winCount > 0 ? "  (\(winCount))" : ""
                    wsItem.title = "工作区 \(idx + 1)\(customLabel)\(suffix)"
                    wsItem.state = (idx == manager.virtualEngine.active) ? .on : .off
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

        pauseItem.title = manager.paused ? "恢复平铺" : "暂停平铺"
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

/// Spawns a fresh Talus process (new PID + audit_token, identical binary/CDHash)
/// after releasing `talus.lock`. Sandboxed macOS apps such as WeChat permanently cache
/// negative TCC Accessibility checks per client `audit_token`, so re-execing when
/// Accessibility is newly granted ensures every running app queries `tccd` cleanly.
func relaunchForFreshTCCSession(reason: String, extraEnv: [String: String] = [:]) -> Never {
    fputs("Talus relaunching for fresh Accessibility audit token (\(reason))...\n", stderr)
    settingsController?.viewModel.flushPendingSave()
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
    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
        manager.observeApplications()
        manager.scheduleRefresh()
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
        manager.restoreAllParkedWindows()
        statusMenu.commands.stopAll()
        exit(0)
    }
    source.resume()
    return source
}

app.run()
manager.restoreAllParkedWindows()
statusMenu.commands.stopAll()
