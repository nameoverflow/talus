import AppKit
import Foundation

@main struct SettingsViewModelTests {
    static func main() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("talus-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let saveURL = tmpDir.appendingPathComponent(".talus.toml")
        let res = ConfigResolution(loadURL: saveURL, saveURL: saveURL, migratedFromJSON: false)

        // 1. Default config starts in simple mode
        let vm = SettingsViewModel(config: Configuration(), resolution: res)
        precondition(vm.statusMode == .simple)
        precondition(vm.modifierSymbolPrefix == "⌃⌥")

        // Cannot disable the last remaining modifier
        vm.toggleModifier("control")
        precondition(vm.modifiers == ["option"] && vm.modifierSymbolPrefix == "⌥")
        vm.toggleModifier("option")
        precondition(vm.modifiers == ["option"])

        // Immediate save writes valid TOML dotfile
        vm.workspaceMode = "virtual"
        vm.workspaceCount = 6
        vm.masterRatioPercent = 58
        vm.outerGap = 12
        vm.innerGap = 8
        vm.spaceLabels = ["终端", "网页", "聊天"]
        vm.addIgnoredApp("com.apple.systempreferences")
        vm.setAppWorkspace("com.apple.Safari", workspaceOneBased: 2)
        // Mutual exclusion: setting appWorkspace on an ignored app removes it from ignoreApps
        vm.addIgnoredApp("com.tencent.xinWeChat")
        precondition(vm.ignoreApps.contains("com.tencent.xinWeChat"))
        vm.setAppWorkspace("com.tencent.xinWeChat", workspaceOneBased: 3)
        precondition(!vm.ignoreApps.contains("com.tencent.xinWeChat"))
        vm.notifyChanged(immediate: true)

        let saved = try Configuration.load(from: saveURL)
        precondition(saved.modifiers == ["option"])
        precondition(saved.workspaceMode == "virtual" && saved.workspaceCount == 6)
        precondition(abs(saved.masterRatio - 0.58) < 0.001)
        precondition(saved.outerGap == 12 && saved.innerGap == 8)
        let reloaded = SettingsViewModel(config: saved, resolution: res)
        precondition(reloaded.outerGap == 12 && reloaded.innerGap == 8)
        precondition(saved.spaceLabels == ["终端", "网页", "聊天"])
        precondition(saved.ignoreApps == ["com.apple.systempreferences"])
        precondition(saved.appWorkspaces["com.apple.Safari"] == .index(2))
        precondition(saved.appWorkspaces["com.tencent.xinWeChat"] == .index(3))
        precondition(vm.workspaceOptionTitle(oneBased: 2) == "工作区 2 · 网页")

        // 2. Script mode detection & round-trip
        var scriptCfg = Configuration()
        scriptCfg.statusTemplate = "%mybar%"
        scriptCfg.statusCommands = [
            StatusCommand(name: "mybar", executable: "/usr/bin/python3", arguments: ["/tmp/bar.py"], interval: 15, timeout: 2, markup: true, onChange: true)
        ]
        let vmScript = SettingsViewModel(config: scriptCfg, resolution: res)
        precondition(vmScript.statusMode == .script)
        precondition(vmScript.scriptExecutable == "/usr/bin/python3")
        let rebuilt = vmScript.buildConfiguration()
        try rebuilt.validate()
        precondition(rebuilt.statusTemplate == "%mybar%" && rebuilt.statusCommands.count == 1)

        // 3. Preview image renders non-empty NSImage in both dark and light appearances
        let darkImg = vm.previewImage(dark: true)
        let lightImg = vm.previewImage(dark: false)
        precondition(darkImg.size.width > 20 && darkImg.size.height == 18)
        precondition(lightImg.size.width > 20 && lightImg.size.height == 18)

        // 4. Presets apply cleanly and validate
        for preset in ["compact", "underline", "pills", "powerline", "clock"] {
            vm.applyTemplatePreset(preset)
            let presetCfg = vm.buildConfiguration()
            try presetCfg.validate()
            precondition(vm.previewImage(dark: true).size.width > 20)
        }

        print("Settings UI view model tests passed")
    }
}
