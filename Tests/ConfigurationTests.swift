import Foundation

@main struct ConfigurationTests {
    static func main() throws {
        let d = JSONDecoder()
        let empty = try d.decode(Configuration.self, from: Data("{}".utf8)); try empty.validate()
        precondition(empty.modifiers == ["control", "option"] && empty.masterRatio == 0.5 && empty.ratioStep == 0.03 && empty.masterCount == 1)
        precondition(empty.statusFormat == "{spaces}  {layout}" && empty.statusTemplate == nil && empty.statusShowIcon && empty.statusCommands.isEmpty)

        let emptyTOML = try Configuration.decodeTOML("# empty config\n"); try emptyTOML.validate()
        precondition(emptyTOML == empty)

        let withoutIcon = try d.decode(Configuration.self, from: Data("{\"statusShowIcon\":false}".utf8)); try withoutIcon.validate()
        precondition(!withoutIcon.statusShowIcon)

        for path in [
            "Examples/status-compact.json",
            "Examples/status-powerline.json",
            "Examples/status-compact.toml",
            "Examples/status-powerline.toml",
        ] {
            _ = try Configuration.load(from: URL(fileURLWithPath: path))
        }

        // Sectioned TOML + round-trip serialization
        let tomlInput = """
        modifiers = ["option"]

        [workspaces]
        mode = "virtual"
        count = 6

        [layout]
        master_ratio = 0.6
        ratio_step = 0.05
        master_count = 2

        [rules]
        ignore_apps = ["com.apple.systempreferences"]

        [rules.app_workspaces]
        "com.apple.Safari" = 2
        "com.tencent.xinWeChat" = "聊天"

        [status]
        show_icon = false
        space_labels = ["终端", "网页", "聊天"]
        workspace_icons = ["terminal", "globe", "chevron.left.forwardslash.chevron.right"]
        template = "%spaces%  <fc=#89CFC2>%layout%</fc>  %clock%"
        workspace_current = "<fc=#10201E,#89CFC2> %label%%fullscreen% </fc>"
        workspace_other = "%label%%fullscreen%"
        fonts = ["Menlo-Regular"]
        font_size = 12.0

        [[status.commands]]
        name = "clock"
        executable = "/bin/date"
        arguments = ["+%H:%M"]
        interval = 30
        timeout = 2
        markup = false
        on_change = true
        """
        let parsedTOML = try Configuration.decodeTOML(tomlInput)
        try parsedTOML.validate()
        precondition(parsedTOML.modifiers == ["option"])
        precondition(parsedTOML.workspaceMode == "virtual" && parsedTOML.workspaceCount == 6)
        precondition(parsedTOML.masterRatio == 0.6 && parsedTOML.ratioStep == 0.05 && parsedTOML.masterCount == 2)
        precondition(parsedTOML.ignoreApps == ["com.apple.systempreferences"])
        precondition(parsedTOML.appWorkspaces["com.apple.Safari"] == .index(2))
        precondition(parsedTOML.appWorkspaces["com.tencent.xinWeChat"] == .label("聊天"))
        precondition(parsedTOML.appWorkspaces["com.apple.Safari"]?.resolve(workspaceCount: 6, spaceLabels: parsedTOML.spaceLabels) == 1)
        precondition(parsedTOML.appWorkspaces["com.tencent.xinWeChat"]?.resolve(workspaceCount: 6, spaceLabels: parsedTOML.spaceLabels) == 2)
        precondition(WorkspaceTarget.label("unknown").resolve(workspaceCount: 6, spaceLabels: parsedTOML.spaceLabels) == nil)
        precondition(!parsedTOML.statusShowIcon && parsedTOML.spaceLabels == ["终端", "网页", "聊天"])
        precondition(parsedTOML.workspaceIcons == ["terminal", "globe", "chevron.left.forwardslash.chevron.right"])
        precondition(parsedTOML.statusCommands.count == 1 && parsedTOML.statusCommands[0].onChange == true)

        let serialized = parsedTOML.toTOML()
        let roundTripped = try Configuration.decodeTOML(serialized)
        try roundTripped.validate()
        precondition(roundTripped == parsedTOML)

        // Disk save & load round-trip (.toml)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("talus-cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dotfileURL = tmpDir.appendingPathComponent(".talus.toml")
        try parsedTOML.save(to: dotfileURL)
        let loadedDotfile = try Configuration.load(from: dotfileURL)
        precondition(loadedDotfile == parsedTOML)

        // Dotfile resolution priority tests
        let fakeHome = URL(fileURLWithPath: "/Users/tester")
        let rNone = Configuration.resolvePaths(homeDirectory: fakeHome, environment: [:], fileExists: { _ in false })
        precondition(rNone.loadURL.path == "/Users/tester/.talus.toml" && rNone.saveURL.path == "/Users/tester/.talus.toml" && !rNone.migratedFromJSON)

        let rXDG = Configuration.resolvePaths(homeDirectory: fakeHome, environment: [:], fileExists: {
            $0 == "/Users/tester/.config/talus/config.toml"
        })
        precondition(rXDG.loadURL.path == "/Users/tester/.config/talus/config.toml" && rXDG.saveURL.path == "/Users/tester/.config/talus/config.toml")

        let rDotOverXDG = Configuration.resolvePaths(homeDirectory: fakeHome, environment: [:], fileExists: {
            $0 == "/Users/tester/.talus.toml" || $0 == "/Users/tester/.config/talus/config.toml"
        })
        precondition(rDotOverXDG.loadURL.path == "/Users/tester/.talus.toml")

        let rLegacyJSON = Configuration.resolvePaths(homeDirectory: fakeHome, environment: [:], fileExists: {
            $0 == "/Users/tester/Library/Application Support/Talus/config.json"
        })
        precondition(rLegacyJSON.loadURL.path == "/Users/tester/Library/Application Support/Talus/config.json")
        precondition(rLegacyJSON.saveURL.path == "/Users/tester/.talus.toml" && rLegacyJSON.migratedFromJSON)

        let rEnv = Configuration.resolvePaths(homeDirectory: fakeHome, environment: ["TALUS_CONFIG": "/tmp/custom.toml"], fileExists: { _ in true })
        precondition(rEnv.loadURL.path == "/tmp/custom.toml" && rEnv.saveURL.path == "/tmp/custom.toml")

        // Unknown / duplicate TOML keys rejected
        for badTOML in [
            "modifers = [\"option\"]",
            "[layout]\nunknown_field = 1",
            "master_ratio = 0.5\n[layout]\nmaster_ratio = 0.6",
            "[[status.commands]]\nname = \"a\"\nexecutable = \"/bin/echo\"\nbogus = true",
        ] {
            do {
                _ = try Configuration.decodeTOML(badTOML)
                fatalError("Unknown or duplicate TOML key was accepted: \(badTOML)")
            } catch { }
        }

        let custom = try d.decode(Configuration.self, from: Data("{\"modifiers\":[\"command\"],\"masterRatio\":0.6,\"masterCount\":2,\"ignoreApps\":[\"com.example.app\"]}".utf8)); try custom.validate()
        precondition(custom.modifiers == ["command"] && custom.ignoreApps == ["com.example.app"])
        for json in [
            "{\"modifiers\":[]}",
            "{\"modifiers\":[\"shift\"]}",
            "{\"workspaceMode\":\"hybrid\"}",
            "{\"workspaceCount\":0}",
            "{\"workspaceCount\":10}",
            "{\"appWorkspaces\":{\"com.apple.Safari\":0}}",
            "{\"appWorkspaces\":{\"com.apple.Safari\":12}}",
            "{\"appWorkspaces\":{\"com.apple.Safari\":\"\"}}",
            "{\"appWorkspaces\":{\"\":2}}",
            "{\"masterRatio\":0.9}",
            "{\"masterCount\":0}",
            "{\"ratioStep\":0}",
            "{\"statusCommands\":[{\"name\":\"spaces\",\"executable\":\"/bin/echo\"}]}",
            "{\"statusCommands\":[{\"name\":\"a\",\"executable\":\"echo\"}]}"
        ] {
            let config = try d.decode(Configuration.self, from: Data(json.utf8))
            do { try config.validate(); fatalError("invalid config was accepted") } catch { }
        }
        var collision = Configuration(); collision.statusTextFile = "/tmp/talus/x/../status"; collision.statusStateFile = "/tmp/talus/status"
        do { try collision.validate(); fatalError("same input and output accepted") } catch { }
        var long = Configuration(); long.statusFormat = String(repeating: "x", count: 161)
        do { try long.validate(); fatalError("long format accepted") } catch { }
        print("Configuration tests passed")
    }
}
