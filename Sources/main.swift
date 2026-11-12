import Cocoa
import ApplicationServices
import Carbon



struct Window { let element: AXUIElement; let pid: pid_t; let screen: NSScreen }
func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &result) == .success ? result : nil
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = value(e, kAXPositionAttribute as CFString), let s = value(e, kAXSizeAttribute as CFString), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
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
func screenRect(_ screen: NSScreen) -> CGRect {
    let r = screen.visibleFrame
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
}
final class Manager {
    var windows: [Window] = []; var history: [Window] = []; var floating: [AXUIElement] = []; var ratio = 0.5; var masters = 1; var paused = false; var layoutMode = 0
    let ignoredApps: Set<String>
    init(config: Configuration) { ratio = config.masterRatio; masters = config.masterCount; ignoredApps = Set(config.ignoreApps) }
    var observers: [pid_t: AXObserver] = [:]
    var scheduled = false
    func scheduleRefresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.refresh()
        }
    }
    func observeApplications() {
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let live = Set(applications.map(\.processIdentifier))
        for pid in observers.keys where !live.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        }
        for application in applications where observers[application.processIdentifier] == nil {
            let pid = application.processIdentifier
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                Unmanaged<Manager>.fromOpaque(context).takeUnretainedValue().scheduleRefresh()
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
            let ax = AXUIElementCreateApplication(pid)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = AXObserverAddNotification(observer, ax, kAXWindowCreatedNotification as CFString, context)
            if result == .success {
                observers[pid] = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
    }
    func refresh(force: Bool = false) {
        guard !paused else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visible = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }.compactMap { row -> (pid_t, CGRect)? in
            guard let pid = row[kCGWindowOwnerPID as String] as? pid_t, let dict = row[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: dict as CFDictionary), rect.width > 100, rect.height > 80 else { return nil }
            return (pid, rect)
        }
        var found: [Window] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            if let testPID = ProcessInfo.processInfo.environment["TALUS_TEST_PID"], String(app.processIdentifier) != testPID { continue }
            if let bundle = app.bundleIdentifier, ignoredApps.contains(bundle) { continue }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            guard let elements = value(ax, kAXWindowsAttribute as CFString) as? [AXUIElement] else { continue }
            for e in elements {
                guard let f = frame(e), f.width > 100, f.height > 80,
                      visible.contains(where: { $0.0 == app.processIdentifier && abs($0.1.minX-f.minX) < 3 && abs($0.1.minY-f.minY) < 3 && abs($0.1.width-f.width) < 3 && abs($0.1.height-f.height) < 3 }),
                      let screen = NSScreen.screens.max(by: { screenRect($0).intersection(f).area < screenRect($1).intersection(f).area }), screenRect(screen).intersects(f) else { continue }
                if let sub = value(e, kAXSubroleAttribute as CFString) as? String, sub != kAXStandardWindowSubrole as String { continue }
                if (value(e, kAXModalAttribute as CFString) as? Bool) == true { continue }
                var canMove = DarwinBoolean(false); var canResize = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(e, kAXPositionAttribute as CFString, &canMove) == .success,
                      AXUIElementIsAttributeSettable(e, kAXSizeAttribute as CFString, &canResize) == .success,
                      canMove.boolValue, canResize.boolValue else { continue }
                found.append(Window(element: e, pid: app.processIdentifier, screen: screen))
            }
        }
        // Preserve stack order when AX returns windows in a different order.
        var ordered = orderUsingHistory(found, history: history) { CFEqual($0.element, $1.element) }
        for w in found where !history.contains(where: { CFEqual($0.element, w.element) }) {
            ordered.removeAll { CFEqual($0.element, w.element) }
            if let app = NSWorkspace.shared.frontmostApplication,
               let focused = value(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString),
               let index = ordered.firstIndex(where: { $0.screen == w.screen && CFEqual($0.element, focused) }) {
                ordered.insert(w, at: index)
            } else { ordered.append(w) }
        }
        let changed = ordered.count != windows.count || zip(ordered, windows).contains { !CFEqual($0.element, $1.element) || $0.screen != $1.screen }
        windows = ordered
        updateHistory()
        for window in windows {
            if let observer = observers[window.pid] {
                AXObserverAddNotification(observer, window.element, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        if changed || force { tile() }
    }
    func updateHistory() {
        history.removeAll { value($0.element, kAXRoleAttribute as CFString) == nil }
        floating.removeAll { element in !history.contains { CFEqual($0.element, element) } }
        history = mergeHistory(history, current: windows) { CFEqual($0.element, $1.element) }
    }
    func tile() {
        for screen in NSScreen.screens {
            let group = windows.filter { window in window.screen == screen && !floating.contains { CFEqual($0, window.element) } }; guard !group.isEmpty else { continue }
            let area = screenRect(screen)
            let rect = Rect(x:area.minX,y:area.minY,w:area.width,h:area.height)
            let rects: [Rect]?
            switch layoutMode {
            case 1: rects = mirrorTallLayout(rect, group.count, masters, ratio)
            case 2: rects = Array(repeating: rect, count: group.count)
            default: rects = tallLayout(rect, group.count, masters, ratio)
            }
            guard let rects else { continue }
            let current = focusedIndex().map { windows[$0] }
            for (w,r) in zip(group,rects) { setFrame(w.element, CGRect(x:r.x,y:r.y,width:r.w,height:r.h)) }
            if layoutMode == 2, let current, current.screen == screen { focus(current) }
        }
    }
    func focusedIndex() -> Int? {
        guard let app = NSWorkspace.shared.frontmostApplication, let e = value(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString) else { return nil }
        return windows.firstIndex { CFEqual($0.element, e) }
    }
    func focus(_ w: Window) { NSRunningApplication(processIdentifier: w.pid)?.activate(); AXUIElementPerformAction(w.element, kAXRaiseAction as CFString); AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue); AXUIElementSetAttributeValue(w.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
    func key(_ code: UInt32, shift: Bool) {
        if code == UInt32(kVK_ANSI_P) { paused.toggle(); if !paused { refresh(force:true) }; print(paused ? "Paused" : "Resumed"); return }
        guard !paused else { return }
        switch code {
        case UInt32(kVK_ANSI_T):
            guard let i = focusedIndex() else { return }
            let element = windows[i].element
            if let index = floating.firstIndex(where: { CFEqual($0, element) }) { floating.remove(at: index) }
            else { floating.append(element) }
            tile()
        case UInt32(kVK_ANSI_H): ratio = max(0.2, ratio - 0.05); tile()
        case UInt32(kVK_ANSI_L): ratio = min(0.8, ratio + 0.05); tile()
        case UInt32(kVK_ANSI_Comma): masters += 1; tile()
        case UInt32(kVK_ANSI_Period): masters = max(1, masters - 1); tile()
        case UInt32(kVK_Space): layoutMode = (layoutMode + 1) % 3; tile()
        case UInt32(kVK_ANSI_J), UInt32(kVK_ANSI_K):
            guard let i = focusedIndex(), windows.count > 1 else { return }
            let indices = windows.indices.filter { windows[$0].screen == windows[i].screen }; guard let p = indices.firstIndex(of:i), indices.count > 1 else { return }
            let next = indices[(p + (code == UInt32(kVK_ANSI_J) ? 1 : indices.count - 1)) % indices.count]
            if shift {
                let direction = code == UInt32(kVK_ANSI_J) ? 1 : -1
                if (direction > 0 && p == indices.count - 1) || (direction < 0 && p == 0) {
                    var group = indices.map { windows[$0] }
                    if direction > 0 { group.insert(group.removeLast(), at: 0) }
                    else { group.append(group.removeFirst()) }
                    for (index, window) in zip(indices, group) { windows[index] = window }
                } else { windows.swapAt(i,next) }
                updateHistory(); tile()
            } else { focus(windows[next]) }
        case UInt32(kVK_Return):
            guard let i = focusedIndex(), let first = windows.indices.first(where: { windows[$0].screen == windows[i].screen }) else { return }
            windows.swapAt(i,first); updateHistory(); tile()
        default: break
        }
    }
}
extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }
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
let defaultConfigURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Talus/config.json")
let configURL = ProcessInfo.processInfo.environment["TALUS_CONFIG"].map { URL(fileURLWithPath: $0) } ?? defaultConfigURL
let config: Configuration
do { config = try Configuration.load(from: configURL) }
catch { reportStartupError(title: "Talus configuration error", message: "\(configURL.path)\n\(error)") }
let manager = Manager(config: config)
final class StatusMenu: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    override init() {
        super.init()
        item.button?.title = "T"
        let menu = NSMenu()
        menu.delegate = self
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Talus", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) { pauseItem.title = manager.paused ? "Resume" : "Pause" }
    @objc func togglePause() { manager.paused.toggle(); if !manager.paused { manager.refresh(force: true) } }
    @objc func quitApp() { NSApp.terminate(nil) }
}
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(opts) { reportStartupError(title: "Accessibility permission needed", message: "Allow Talus in System Settings → Privacy & Security → Accessibility, then reopen Talus.") }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusMenu = StatusMenu()
let handler: EventHandlerUPP = { _, event, _ in
    var hotkey = EventHotKeyID(); GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
    manager.key(hotkey.id & 0xffff, shift: hotkey.id & 0x10000 != 0); return noErr
}
var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, nil)
var refs: [EventHotKeyRef] = []
let modifierBits = config.modifiers.reduce(UInt32(0)) { result, name in
    switch name {
    case "control": return result | UInt32(controlKey)
    case "option": return result | UInt32(optionKey)
    case "command": return result | UInt32(cmdKey)
    default: return result
    }
}
for code in [kVK_ANSI_H,kVK_ANSI_L,kVK_ANSI_J,kVK_ANSI_K,kVK_ANSI_Comma,kVK_ANSI_Period,kVK_Space,kVK_Return,kVK_ANSI_P,kVK_ANSI_T] {
    for shifted in ([kVK_ANSI_J,kVK_ANSI_K].contains(code) ? [false,true] : [false]) {
        var ref: EventHotKeyRef?; let id = UInt32(code) | (shifted ? 0x10000 : 0)
        let status = RegisterEventHotKey(UInt32(code), modifierBits | (shifted ? UInt32(shiftKey) : 0), EventHotKeyID(signature: 0x4d4f4e44, id: id), GetApplicationEventTarget(), 0, &ref)
        if status != noErr { fputs("Could not register shortcut key \(code): \(status)\n", stderr) }; if let ref { refs.append(ref) }
    }
}
print("Running. \(config.modifiers.joined(separator: "+"))+P pauses; Control-C quits.")
manager.observeApplications()
manager.refresh(force:true)
let workspace = NSWorkspace.shared.notificationCenter
let tokens = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification].map { name in
    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in manager.observeApplications(); manager.scheduleRefresh() }
}
// Some applications omit accessibility notifications. Reconcile as a fallback.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in manager.observeApplications(); manager.refresh() }
app.run()
