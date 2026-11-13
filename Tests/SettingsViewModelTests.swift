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
        vm.masterRatioPercent = 58
        vm.spaceLabels = ["终端", "网页"]
        vm.addIgnoredApp("com.apple.systempreferences")
        vm.notifyChanged(immediate: true)

        let saved = try Configuration.load(from: saveURL)
        precondition(saved.modifiers == ["option"])
        precondition(abs(saved.masterRatio - 0.58) < 0.001)
        precondition(saved.spaceLabels == ["终端", "网页"])
        precondition(saved.ignoreApps == ["com.apple.systempreferences"])

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

        print("Settings UI view model tests passed")
    }
}
