import Cocoa
import ApplicationServices

// Only immutable snapshots cross this queue. ManagerCore, its handles and UI
// remain confined to the main thread.
struct DiscoveredWindow {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    let windowID: UInt32?
    let title: String
    let rect: CGRect
    let isResizable: Bool
}

struct WindowDiscoveryResult {
    var windows: [DiscoveredWindow] = []
    var busyPIDs: Set<pid_t> = []
    var visibleWindowIDs: [UInt32] = []
    var existingWindowIDs: [UInt32] = []
    var deadHandles: [UInt64] = []
    var livePIDs: Set<pid_t> = []
    var eligibleVisibleWindowExists = false
    var staleAPIDisabled = false
}

typealias WindowDiscoveryFunction = (pid_t, Set<String>, Set<pid_t>?,
    [UInt64: AXUIElement], [UInt64: pid_t], Set<pid_t>?) -> WindowDiscoveryResult

func axApplication(_ pid: pid_t) -> AXUIElement {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.1)
    return element
}

func discoverWindows(ownPID: pid_t, ignoredApps: Set<String>, selectedPIDs: Set<pid_t>?,
                     knownElements: [UInt64: AXUIElement], knownPIDs: [UInt64: pid_t],
                     onlyPIDs: Set<pid_t>?) -> WindowDiscoveryResult {
    var result = WindowDiscoveryResult()
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let visible: [VisibleWindowCandidate] = list.filter {
        ($0[kCGWindowLayer as String] as? Int) == 0
            && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
    }.compactMap { row in
        guard let pid = row[kCGWindowOwnerPID as String] as? pid_t,
              let dict = row[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
              rect.width > 100, rect.height > 80 else { return nil }
        return VisibleWindowCandidate(pid: pid, windowID: (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value, bounds: rect)
    }
    result.visibleWindowIDs = visible.compactMap(\.windowID)
    let all = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    result.existingWindowIDs = all.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    let visibleByPID = Dictionary(grouping: visible, by: \.pid)
    var seen: Set<AXWindowKey> = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
        let pid = app.processIdentifier
        guard pid != ownPID, selectedPIDs?.contains(pid) ?? true else { continue }
        let bundle = app.bundleIdentifier
        if let bundle, ignoredApps.contains(bundle) { continue }
        result.livePIDs.insert(pid)
        let appVisible = visibleByPID[pid] ?? []
        result.eligibleVisibleWindowExists = result.eligibleVisibleWindowExists || !appVisible.isEmpty
        guard onlyPIDs?.contains(pid) ?? true else { continue }
        let ax = axApplication(pid)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw)
        if error == .apiDisabled && !appVisible.isEmpty { result.staleAPIDisabled = true }
        if error != .success && error != .apiDisabled && !appVisible.isEmpty {
            result.busyPIDs.insert(pid)
        }
        guard error == .success, let elements = raw as? [AXUIElement] else { continue }
        for element in elements {
            AXUIElementSetMessagingTimeout(element, 0.1)
            var role: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if roleError == .cannotComplete { result.busyPIDs.insert(pid); continue }
            if let role = role as? String, role != kAXWindowRole as String { continue }
            if (axValue(element, kAXMinimizedAttribute as CFString) as? Bool) == true { continue }
            var wid: CGWindowID = 0
            let windowID: UInt32? = (_AXUIElementGetWindow(element, &wid) == .success && wid != 0) ? wid : nil
            guard let rect = frame(element) else { result.busyPIDs.insert(pid); continue }
            guard rect.width > 100, rect.height > 80,
                  matchesVisibleWindow(pid: pid, axWindowID: windowID, axFrame: rect, candidates: appVisible) else { continue }
            if let subrole = axValue(element, kAXSubroleAttribute as CFString) as? String, subrole != kAXStandardWindowSubrole as String { continue }
            if (axValue(element, kAXModalAttribute as CFString) as? Bool) == true { continue }
            var canMove = DarwinBoolean(false), canResize = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &canMove) == .success, canMove.boolValue else { continue }
            let resizable = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &canResize) == .success && canResize.boolValue
            seen.insert(AXWindowKey(element: element))
            result.windows.append(DiscoveredWindow(element: element, pid: pid, bundleID: bundle,
                windowID: windowID, title: axValue(element, kAXTitleAttribute as CFString) as? String ?? "",
                rect: rect, isResizable: resizable))
        }
    }
    for (handle, element) in knownElements where !seen.contains(AXWindowKey(element: element)) {
        if let pid = knownPIDs[handle], let onlyPIDs, !onlyPIDs.contains(pid), result.livePIDs.contains(pid) { continue }
        var role: CFTypeRef?
        // A busy app is not a destroyed window. Reconciliation retries it.
        let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if error == .invalidUIElement { result.deadHandles.append(handle) }
    }
    return result
}
