import AppKit

@main struct SettingsWindowLayoutTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let saveURL = FileManager.default.temporaryDirectory.appendingPathComponent("talus-layout-test.toml")
        let resolution = ConfigResolution(loadURL: saveURL, saveURL: saveURL, migratedFromJSON: false)
        var config = Configuration()
        config.workspaceMode = "virtual"
        config.spaceLabels = ["终端", "网页", "代码", "聊天", "杂项"]
        config.statusTemplate = "%spaces%  <fc=#0D9488>%layout%</fc> · %count%"
        let controller = SettingsWindowController(config: config, resolution: resolution) { _, _ in }
        controller.show()
        let window = controller.nsWindow!
        defer { window.orderOut(nil) }

        // Exercise the real NSHostingController: a standalone NSHostingView preview
        // did not reproduce the zero-width scroll area in the settings window.
        for scrollerStyle in [NSScroller.Style.overlay, .legacy] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for size in [NSSize(width: 640, height: 660), NSSize(width: 600, height: 560), NSSize(width: 960, height: 780)] {
                    window.setContentSize(size)
                    for tab in SettingsTab.allCases {
                        controller.viewModel.selectedTab = tab
                        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                        let hosting = window.contentView!
                        hosting.layoutSubtreeIfNeeded()
                        guard let scroll = firstScrollView(in: hosting), let document = scroll.documentView else {
                            fatalError("Missing settings content for \(tab)")
                        }
                        scroll.scrollerStyle = scrollerStyle
                        scroll.tile()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                        hosting.layoutSubtreeIfNeeded()
                        let viewport = scroll.contentView.bounds
                        precondition(abs(scroll.frame.width - hosting.bounds.width) < 1,
                                     "\(tab) scroll width \(scroll.frame.width), window width \(hosting.bounds.width)")
                        precondition(viewport.height > 100, "Settings viewport collapsed")
                        precondition(abs(document.bounds.width - viewport.width) < 1,
                                     "\(tab) content must fit the viewport horizontally")
                        if document.bounds.height > viewport.height {
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - viewport.height))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            precondition(scroll.contentView.bounds.minY > 0, "Settings content cannot scroll")
                            scroll.contentView.scroll(to: .zero)
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                    }
                }
            }
        }
        print("Settings window layout tests passed (3 tabs, 3 sizes, light/dark, overlay/legacy scrollbars, scrolling)")
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = firstScrollView(in: child) { return scroll }
        }
        return nil
    }
}
