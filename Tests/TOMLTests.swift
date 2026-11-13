import Foundation

@main struct TOMLTests {
    static func main() throws {
        let sample = """
        # Top-level comment
        modifiers = [
          "option", # inline comment inside array
        ]

        [layout]
        master_ratio = 0.55
        ratio_step = 0.03
        master_count = 2

        [rules]
        ignore_apps = ['com.apple.systempreferences', "com.apple.finder"]

        [status]
        show_icon = false
        space_labels = ["终端", "网页", "\\u804A\\u5929"]
        template = '''
        %spaces%  <fc=#89CFC2>%layout%</fc>  %clock%'''
        font_size = 12

        [[status.commands]]
        name = "clock"
        executable = "/bin/date"
        arguments = ["+%H:%M"]
        interval = 30
        markup = false

        [[status.commands]]
        name = "bar"
        executable = "/usr/bin/python3"
        on_change = true
        """

        let parsed = try TOMLParser.parse(sample)
        precondition(parsed["modifiers"] == .array([.string("option")]))
        precondition(parsed["layout"]?.tableValue?["master_ratio"]?.doubleValue == 0.55)
        precondition(parsed["layout"]?.tableValue?["master_count"]?.intValue == 2)
        precondition(parsed["rules"]?.tableValue?["ignore_apps"] == .array([
            .string("com.apple.systempreferences"),
            .string("com.apple.finder"),
        ]))

        let status = parsed["status"]?.tableValue
        precondition(status?["show_icon"]?.boolValue == false)
        precondition(status?["space_labels"] == .array([.string("终端"), .string("网页"), .string("聊天")]))
        precondition(status?["template"]?.stringValue == "%spaces%  <fc=#89CFC2>%layout%</fc>  %clock%")
        precondition(status?["font_size"]?.doubleValue == 12.0)
        precondition(status?["commands"]?.arrayValue?.count == 2)

        // Inline table, dotted keys, hex/oct/bin integers, multiline basic string
        let extra = """
        hex_val = 0xff
        oct_val = 0o755
        bin_val = 0b1010
        dotted.a.b = 1_000
        inline = { x = 1, y = "two" }
        multi = \"\"\"
        hello \\
          world\"\"\"
        """
        let p2 = try TOMLParser.parse(extra)
        precondition(p2["hex_val"]?.intValue == 255)
        precondition(p2["oct_val"]?.intValue == 493)
        precondition(p2["bin_val"]?.intValue == 10)
        precondition(p2["dotted"]?.tableValue?["a"]?.tableValue?["b"]?.intValue == 1000)
        precondition(p2["inline"]?.tableValue?["y"]?.stringValue == "two")
        precondition(p2["multi"]?.stringValue == "hello world")

        // Reject malformed / duplicate TOML
        let invalidCases = [
            "a = 1\na = 2",
            "[layout]\nx = 1\n[layout]\ny = 2",
            "unterminated = \"hello",
            "leading_zero = 012",
            "missing_eq",
            "[unclosed",
            "[[unclosed]",
        ]
        for bad in invalidCases {
            do {
                _ = try TOMLParser.parse(bad)
                fatalError("Invalid TOML should have failed: \(bad)")
            } catch { }
        }

        print("TOML parser and writer tests passed")
    }
}
