import AppKit
import SwiftUI

@main struct RenderSettingsPreview {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: RenderSettingsPreview <output-directory> [outer-gap inner-gap]\n", stderr)
            exit(1)
        }
        let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let sampleTOML = """
        modifiers = ["option"]

        [workspaces]
        mode = "virtual"
        count = 5
        labels = ["终端", "网页", "代码", "聊天", "杂项"]

        [layout]
        master_ratio = 0.52
        ratio_step = 0.03
        master_count = 1

        [rules]
        ignore_apps = ["com.apple.systempreferences", "com.apple.calculator"]

        [rules.app_workspaces]
        "com.apple.Terminal" = "终端"
        "com.apple.Safari" = "网页"
        "com.tencent.xinWeChat" = "聊天"

        [status]
        show_icon = true
        template = "%spaces%  <fc=#0D9488>%layout%</fc> · %count%"
        workspace_current = "<fc=#FFFFFF,#0F766E> %index%:%label%%fullscreen% </fc>"
        workspace_other = " %index%:%label%%fullscreen% "
        """
        var config = try Configuration.decodeTOML(sampleTOML)
        if CommandLine.arguments.count >= 4 {
            guard let outer = Double(CommandLine.arguments[2]),
                  let inner = Double(CommandLine.arguments[3]) else {
                fatalError("Gap arguments must be numbers")
            }
            config.outerGap = outer
            config.innerGap = inner
            try config.validate()
        }
        let fakeDotfile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".talus.toml")
        let resolution = ConfigResolution(loadURL: fakeDotfile, saveURL: fakeDotfile, migratedFromJSON: false)

        for (appearanceName, isDark) in [("dark", true), ("light", false)] {
            let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
            for tab in SettingsTab.allCases {
                let vm = SettingsViewModel(config: config, resolution: resolution)
                vm.selectedTab = tab
                vm.statusBanner = "✓ 已自动保存至 ~/.talus.toml 并生效"

                let framedView = WindowChromePreviewWrapper(title: "Talus 设置", dark: isDark) {
                    SettingsRootView(model: vm)
                        .environment(\.colorScheme, isDark ? .dark : .light)
                }

                let width: CGFloat = 656
                let height: CGFloat = 712
                let win = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                win.appearance = appearance
                win.isOpaque = false
                win.backgroundColor = .clear
                let hosting = NSHostingView(rootView: framedView)
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
                hosting.appearance = appearance
                win.contentView = hosting

                // Pump run loop briefly so SwiftUI & AppKit subviews lay out completely
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                hosting.layoutSubtreeIfNeeded()

                let bounds = hosting.bounds
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(bounds.width * 2),
                    pixelsHigh: Int(bounds.height * 2),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ) else {
                    fatalError("Cannot allocate bitmap")
                }
                rep.size = bounds.size
                NSAppearance.currentDrawing()
                appearance.performAsCurrentDrawingAppearance {
                    hosting.cacheDisplay(in: bounds, to: rep)
                }
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    fatalError("Cannot encode PNG")
                }
                let outURL = outDir.appendingPathComponent("settings-\(tab.rawValue)-\(appearanceName).png")
                try png.write(to: outURL)
            }
        }
        print("Rendered settings previews to \(outDir.path)")
    }
}

private struct WindowChromePreviewWrapper<Content: View>: View {
    let title: String
    let dark: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
                Spacer()
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dark ? Color.white.opacity(0.88) : Color.black.opacity(0.82))
                Spacer()
                Color.clear.frame(width: 52, height: 12)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(dark ? Color(red: 0.17, green: 0.18, blue: 0.20) : Color(red: 0.94, green: 0.94, blue: 0.96))

            Divider()

            content()
                .background(dark ? Color(red: 0.12, green: 0.13, blue: 0.15) : Color(red: 0.96, green: 0.96, blue: 0.97))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 1)
        )
        .padding(8)
    }
}
