import AppKit
import CoreGraphics

private final class StatusClickFixture: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let output: URL
    let regions = (0..<4).map { StatusWorkspaceHitRegion(index: $0, rect: NSRect(x: $0 * 6, y: 0, width: 6, height: 18)) }
    var clicks: [Int] = []
    var eventLocations: [Double] = []

    init(output: URL) {
        self.output = output
        super.init()
        let button = item.button!
        // Keep the fixture narrow so it fits beside the live app and the notch.
        button.image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 2, width: 24, height: 14).fill()
            return true
        }
        button.image!.accessibilityDescription = "Talus status click test"
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: .leftMouseUp)
    }

    @objc private func clicked() {
        eventLocations.append(Double(NSApp.currentEvent?.locationInWindow.x ?? -1))
        clicks.append(statusWorkspaceIndexUnderPointer(button: item.button!, regions: regions) ?? -1)
        publish()
    }

    func publish() {
        guard let button = item.button, let window = button.window,
              let imageRect = button.cell?.imageRect(forBounds: button.bounds),
              window.frame.minY > 0 else { return }
        if let safe = window.screen?.auxiliaryTopRightArea, window.frame.minX < safe.minX {
            return // The fixture is hidden by the notch; do not click an invisible item.
        }
        let points = regions.map { region -> [Double] in
            let local = NSPoint(x: imageRect.minX + region.rect.midX, y: button.bounds.midY)
            let screen = window.convertPoint(toScreen: button.convert(local, to: nil))
            return [screen.x, NSScreen.screens[0].frame.maxY - screen.y]
        }
        let state: [String: Any] = ["points": points, "clicks": clicks, "eventLocations": eventLocations]
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: output, options: .atomic)
        }
    }
}

@main struct StatusClickProbe {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        if CommandLine.arguments[1] == "--fixture" {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let fixture = StatusClickFixture(output: output)
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in fixture.publish() }
            withExtendedLifetime(fixture) { app.run() }
        } else {
            try verifyClicks(output: output)
        }
    }

    private static func verifyClicks(output: URL) throws {
        guard CGPreflightPostEventAccess() else { throw failure("Mouse event posting is not allowed") }
        func state() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String: Any]
        }
        let points = try state()["points"] as! [[Double]]
        let originalPointer = CGEvent(source: nil)!.location
        defer {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalPointer,
                    mouseButton: .left)!.post(tap: .cghidEventTap)
        }
        let targets = [0, 1, 3, 2, 0]
        for (sequence, target) in targets.enumerated() {
            let point = CGPoint(x: points[target][0], y: points[target][1])
            for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
                event.flags = []
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.08)
            }
            var observed: [Int] = []
            for _ in 0..<100 {
                observed = try state()["clicks"] as! [Int]
                if observed.count > sequence { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard observed == Array(targets.prefix(sequence + 1)) else {
                throw failure("Expected \(Array(targets.prefix(sequence + 1))), observed \(observed)")
            }
        }
        print("Five real status-item clicks selected their exact targets; action event x values: \(try state()["eventLocations"]!)")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TalusStatusClickTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
