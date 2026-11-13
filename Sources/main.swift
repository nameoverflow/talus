import Cocoa
import ApplicationServices
import Carbon
import Darwin

struct Window { let element: AXUIElement; let pid: pid_t; let screen: NSScreen }

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

func screenRect(_ screen: NSScreen) -> CGRect {
    let r = screen.visibleFrame
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    return accessibilityFrame(visible: r, primaryTop: top)
}

final class Manager {
    var windows: [Window] = []
    var history: [Window] = []
    var floating: [AXUIElement] = []
    var ratio = 0.5
    var masters = 1
    var paused = false
    var layoutMode = 0
    var ignoredApps: Set<String>
    var ratioStep: Double
    let ownPID = ProcessInfo.processInfo.processIdentifier

    init(config: Configuration) {
        ratio = config.masterRatio
        masters = config.masterCount
        ratioStep = config.ratioStep
        ignoredApps = Set(config.ignoreApps)
    }

    func apply(config: Configuration) {
        ratio = config.masterRatio
        masters = config.masterCount
        ratioStep = config.ratioStep
        ignoredApps = Set(config.ignoreApps)
        if AXIsProcessTrusted() {
            refresh(force: true)
        }
    }

    var observers: [pid_t: AXObserver] = [:]
    var statusChanged: (() -> Void)?
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
        guard AXIsProcessTrusted() else { return }
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
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                let manager = Unmanaged<Manager>.fromOpaque(context).takeUnretainedValue()
                manager.rememberFocus()
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

    func refresh(force: Bool = false) {
        guard !paused, AXIsProcessTrusted() else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visible = list.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }.compactMap { row -> (pid_t, CGRect)? in
            guard let pid = row[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  rect.width > 100, rect.height > 80
            else { return nil }
            return (pid, rect)
        }
        var found: [Window] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            if app.processIdentifier == ownPID { continue }
            if let selectedPIDs = ProcessInfo.processInfo.environment["TALUS_TEST_PID"] {
                let allowed = selectedPIDs.split(separator: ",").map(String.init)
                if !allowed.contains(String(app.processIdentifier)) { continue }
            }
            if let bundle = app.bundleIdentifier, ignoredApps.contains(bundle) { continue }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            guard let elements = axValue(ax, kAXWindowsAttribute as CFString) as? [AXUIElement] else { continue }
            for e in elements {
                guard let f = frame(e), f.width > 100, f.height > 80,
                      visible.contains(where: {
                          $0.0 == app.processIdentifier && abs($0.1.minX - f.minX) < 3 && abs($0.1.minY - f.minY) < 3
                              && abs($0.1.width - f.width) < 3 && abs($0.1.height - f.height) < 3
                      }),
                      let screen = NSScreen.screens.max(by: { screenRect($0).intersection(f).area < screenRect($1).intersection(f).area }),
                      screenRect(screen).intersects(f)
                else { continue }
                if let sub = axValue(e, kAXSubroleAttribute as CFString) as? String, sub != kAXStandardWindowSubrole as String { continue }
                if (axValue(e, kAXModalAttribute as CFString) as? Bool) == true { continue }
                var canMove = DarwinBoolean(false); var canResize = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(e, kAXPositionAttribute as CFString, &canMove) == .success,
                      AXUIElementIsAttributeSettable(e, kAXSizeAttribute as CFString, &canResize) == .success,
                      canMove.boolValue, canResize.boolValue
                else { continue }
                found.append(Window(element: e, pid: app.processIdentifier, screen: screen))
            }
        }
        // Preserve stack order when AX returns windows in a different order.
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
        updateHistory()
        for window in windows {
            if let observer = observers[window.pid] {
                AXObserverAddNotification(observer, window.element, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        if changed || force { tile() }
        statusChanged?()
    }

    func updateHistory() {
        history.removeAll { axValue($0.element, kAXRoleAttribute as CFString) == nil }
        floating.removeAll { element in !history.contains { CFEqual($0.element, element) } }
        history = mergeHistory(history, current: windows) { CFEqual($0.element, $1.element) }
    }

    func tile() {
        for screen in NSScreen.screens {
            let group = windows.filter { window in
                window.screen == screen && !floating.contains { CFEqual($0, window.element) }
            }
            guard !group.isEmpty else { continue }
            let area = screenRect(screen)
            let rect = Rect(x: area.minX, y: area.minY, w: area.width, h: area.height)
            let rects: [Rect]?
            switch layoutMode {
            case 1: rects = mirrorTallLayout(rect, group.count, masters, ratio)
            case 2: rects = Array(repeating: rect, count: group.count)
            default: rects = tallLayout(rect, group.count, masters, ratio)
            }
            guard let rects else { continue }
            let current = focusedIndex().map { windows[$0] }
            for (w, r) in zip(group, rects) { setFrame(w.element, CGRect(x: r.x, y: r.y, width: r.w, height: r.h)) }
            if layoutMode == 2, let current, current.screen == screen { focus(current) }
        }
    }

    func rememberFocus() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let focused = axValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString),
              let window = windows.first(where: { CFEqual($0.element, focused) })
        else { return }
        lastFocused = window.element
    }

    func focusedIndex() -> Int? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let e = axValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString)
        else { return nil }
        return windows.firstIndex { CFEqual($0.element, e) }
    }

    func focus(_ w: Window) {
        lastFocused = w.element
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(w.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    func key(_ code: UInt32, shift: Bool) {
        if code == UInt32(kVK_ANSI_P) {
            paused.toggle()
            if !paused { refresh(force: true) }
            print(paused ? "Paused" : "Resumed")
            return
        }
        guard !paused, AXIsProcessTrusted() else { return }
        switch code {
        case UInt32(kVK_ANSI_T):
            guard let i = focusedIndex() else { return }
            let element = windows[i].element
            if let index = floating.firstIndex(where: { CFEqual($0, element) }) { floating.remove(at: index) }
            else { floating.append(element) }
            tile()
        case UInt32(kVK_ANSI_H): ratio = max(0.2, ratio - ratioStep); tile()
        case UInt32(kVK_ANSI_L): ratio = min(0.8, ratio + ratioStep); tile()
        case UInt32(kVK_ANSI_Comma): masters += 1; tile()
        case UInt32(kVK_ANSI_Period): masters = max(1, masters - 1); tile()
        case UInt32(kVK_Space): layoutMode = (layoutMode + 1) % 3; tile()
        case UInt32(kVK_ANSI_J), UInt32(kVK_ANSI_K):
            guard let i = focusedIndex(), windows.count > 1 else { return }
            let indices = windows.indices.filter { windows[$0].screen == windows[i].screen }
            guard let p = indices.firstIndex(of: i), indices.count > 1 else { return }
            let next = indices[(p + (code == UInt32(kVK_ANSI_J) ? 1 : indices.count - 1)) % indices.count]
            if shift {
                let direction = code == UInt32(kVK_ANSI_J) ? 1 : -1
                if (direction > 0 && p == indices.count - 1) || (direction < 0 && p == 0) {
                    var group = indices.map { windows[$0] }
                    if direction > 0 { group.insert(group.removeLast(), at: 0) }
                    else { group.append(group.removeFirst()) }
                    for (index, window) in zip(indices, group) { windows[index] = window }
                } else { windows.swapAt(i, next) }
                updateHistory(); tile()
            } else { focus(windows[next]) }
        case UInt32(kVK_Return):
            guard let i = focusedIndex(), let first = windows.indices.first(where: { windows[$0].screen == windows[i].screen }) else { return }
            windows.swapAt(i, first); updateHistory(); tile()
        default: break
        }
    }
}

extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

final class HotkeyRegistry {
    private var refs: [EventHotKeyRef] = []

    func apply(modifiers: [String]) {
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
        let codes = [kVK_ANSI_H, kVK_ANSI_L, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_Space, kVK_Return, kVK_ANSI_P, kVK_ANSI_T]
        for code in codes {
            for shifted in ([kVK_ANSI_J, kVK_ANSI_K].contains(code) ? [false, true] : [false]) {
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

let lockFD = open(supportDirectory.appendingPathComponent("talus.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
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

let manager = Manager(config: currentConfig)
let hotkeys = HotkeyRegistry()
var settingsController: SettingsWindowController?

func fileModificationDate(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}
var watchedConfigPath = currentResolution.loadURL.path
var watchedConfigMTime = fileModificationDate(currentResolution.loadURL)
var lastReportedReloadMTime: Date?

final class StatusMenu: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let axWarningItem = NSMenuItem(title: "⚠️ 授予辅助功能权限…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    let axSeparator = NSMenuItem.separator()
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
    var onOpenSettings: (() -> Void)?
    var onOpenConfigFile: (() -> Void)?
    var onReloadConfig: (() -> Void)?

    init(config: Configuration) {
        self.config = config
        self.commands = StatusCommands(stateFile: config.statusStateFile)
        super.init()
        commands.onChange = { [weak self] in self?.updateStatus() }
        item.button?.image = makeStatusIcon()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Talus"

        let menu = NSMenu()
        menu.delegate = self

        axWarningItem.target = self
        menu.addItem(axWarningItem)
        menu.addItem(axSeparator)

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
        item.menu = menu
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
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontWindow = trusted ? frontmost.flatMap { axValue(AXUIElementCreateApplication($0.processIdentifier), kAXFocusedWindowAttribute as CFString) } : nil
        let title: String
        if let frontWindow, CFGetTypeID(frontWindow) == AXUIElementGetTypeID() {
            title = axValue(frontWindow as! AXUIElement, kAXTitleAttribute as CFString) as? String ?? ""
        } else {
            title = ""
        }
        let names = ["Tall", "Mirror", "Full"]
        let custom = config.statusTextFile.map(readCustomStatus(at:)) ?? ""
        let spaceList = spaces.spaces(for: screen)
        let values = StatusValues(
            spaces: spaceList,
            layout: names[manager.layoutMode],
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
        if parts != cachedParts || dark != cachedDark {
            let image = configuredStatusImage(parts: parts, dark: dark, showIcon: currentCfg.statusShowIcon)
            image.accessibilityDescription = "Talus: \(spoken)"
            button.title = ""; button.image = image; button.imagePosition = .imageOnly
            button.toolTip = "Talus: \(spoken)"
            if ProcessInfo.processInfo.environment["TALUS_TRACE_STATUS"] == "1" {
                fputs("status: \(spoken)\n", stderr)
            }
            cachedParts = parts; cachedDark = dark
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        axWarningItem.isHidden = trusted
        axSeparator.isHidden = trusted
        pauseItem.title = manager.paused ? "恢复平铺" : "暂停平铺"
        openFileItem.title = "打开配置文件 (\(abbreviatedPath(currentResolution.saveURL)))"
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
    @objc func quitApp() { settingsController?.viewModel.flushPendingSave(); commands.stopAll(); NSApp.terminate(nil) }
}

let isAutomatedTest = ProcessInfo.processInfo.environment["TALUS_TEST_PID"] != nil
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

func applyLiveConfiguration(_ updated: Configuration, resolution: ConfigResolution) {
    let modifiersChanged = updated.modifiers != currentConfig.modifiers
    currentConfig = updated
    currentResolution = resolution
    manager.apply(config: updated)
    if modifiersChanged {
        hotkeys.apply(modifiers: updated.modifiers)
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
hotkeys.apply(modifiers: currentConfig.modifiers)

print("Running. \(currentConfig.modifiers.joined(separator: "+"))+P pauses; Control-C quits.")
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
].map { name in
    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
        manager.observeApplications()
        manager.scheduleRefresh()
        statusMenu.updateStatus()
        if name == NSWorkspace.activeSpaceDidChangeNotification {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { statusMenu.updateStatus() }
        }
    }
}

// Reconcile windows, Accessibility grant changes, and external dotfile edits.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    let nowTrusted = AXIsProcessTrusted()
    if nowTrusted && !wasTrusted {
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
        statusMenu.commands.stopAll()
        exit(0)
    }
    source.resume()
    return source
}

app.run()
statusMenu.commands.stopAll()
