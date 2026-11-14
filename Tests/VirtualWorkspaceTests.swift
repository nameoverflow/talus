import Foundation

@main struct VirtualWorkspaceTests {
    static func main() {
        let engine = VirtualWorkspaceEngine<String>(count: 5, defaultRatio: 0.52, defaultMasters: 1)
        precondition(engine.count == 5 && engine.active == 0)

        // 1. Seed initial desktop windows onto workspace 0
        engine.seedFromCurrentDesktop(["A", "B", "C"], focused: "B")
        precondition(engine.activeWindows == ["A", "B", "C"])
        precondition(engine.activeFocused == "B")
        precondition(engine.inactiveWindows.isEmpty)

        // 2. Throw window "B" to workspace 2 (index 1, 0-based -> let's test index 2 = workspace 3)
        // Active workspace stays 0, focus moves deterministically to neighbor "C"
        let res = engine.moveWindow("B", to: 2)
        precondition(res.moved)
        precondition(engine.active == 0)
        precondition(engine.activeWindows == ["A", "C"])
        precondition(res.nextFocusOnActive == "C" && engine.activeFocused == "C")
        precondition(engine.windowCount(in: 2) == 1)
        precondition(engine.inactiveWindows == ["B"])

        // 3. Per-workspace independent layout state
        engine.activeLayout.layoutMode = 1 // Mirror on workspace 0
        engine.activeLayout.ratio = 0.65
        precondition(engine.switchTo(2))
        precondition(engine.active == 2)
        precondition(engine.activeWindows == ["B"] && engine.activeFocused == "B")
        precondition(engine.activeLayout.layoutMode == 0 && abs(engine.activeLayout.ratio - 0.52) < 0.0001)
        precondition(Set(engine.inactiveWindows) == Set(["A", "C"]))

        // 4. Spawn new window "D" while on workspace 2: inserted before focused "B" (master slot)
        engine.reconcile(discovered: ["C", "B", "A", "D"], currentlyFocused: "D")
        precondition(engine.activeWindows == ["D", "B"])
        precondition(engine.activeFocused == "D")
        // Workspace 0 order ("A", "C") is preserved despite arbitrary discovered order
        _ = engine.switchTo(0)
        precondition(engine.activeWindows == ["A", "C"])
        precondition(engine.activeFocused == "C")
        precondition(engine.activeLayout.layoutMode == 1 && abs(engine.activeLayout.ratio - 0.65) < 0.0001)

        // 5. External focus (e.g. Cmd-Tab to "B" on workspace 2) automatically switches workspace
        let jumped = engine.handleExternalFocus("B")
        precondition(jumped == 2 && engine.active == 2 && engine.activeFocused == "B")

        // 6. Closing focused window "B" selects neighbor "D" deterministically
        engine.reconcile(discovered: ["A", "C", "D"], currentlyFocused: nil)
        precondition(engine.activeWindows == ["D"] && engine.activeFocused == "D")

        // 7. Throwing last window away from active workspace leaves activeFocused == nil
        let lastMove = engine.moveWindow("D", to: 4)
        precondition(lastMove.moved && lastMove.nextFocusOnActive == nil && engine.activeWindows.isEmpty)

        // 8. Shrinking workspace count from 5 -> 3 merges workspace 4's "D" into workspace 2 (index 2) without losing windows
        engine.resizeCount(to: 3)
        precondition(engine.count == 3)
        precondition(engine.stacks[2] == ["D"])
        precondition(Set(engine.allWindows) == Set(["A", "C", "D"]))

        // 9. Updating defaults updates untouched workspaces while keeping customized workspace 0 ratio
        engine.updateDefaults(ratio: 0.60, masters: 2)
        precondition(abs(engine.layouts[0].ratio - 0.65) < 0.0001)
        precondition(abs(engine.layouts[1].ratio - 0.60) < 0.0001 && engine.layouts[1].masters == 2)

        // 10. App auto-shift (`doShift`) on seed and on new window creation
        let routed = VirtualWorkspaceEngine<String>(count: 4, defaultRatio: 0.5, defaultMasters: 1)
        let rule: (String) -> Int? = { win in
            if win.hasPrefix("safari:") { return 1 }
            if win.hasPrefix("chat:") { return 3 }
            return nil
        }
        routed.seedFromCurrentDesktop(["term:1", "safari:1"], focused: "term:1", assignedWorkspace: rule)
        precondition(routed.active == 0)
        precondition(routed.activeWindows == ["term:1"])
        precondition(routed.stacks[1] == ["safari:1"])

        // New chat window appears and briefly reports currentlyFocused == "chat:1":
        // reconcile routes it to workspace 3, keeps active == 0 & activeFocused == "term:1", and reports autoShiftedOffActive
        let rec = routed.reconcile(
            discovered: ["term:1", "safari:1", "chat:1"],
            currentlyFocused: "chat:1",
            assignedWorkspace: rule
        )
        precondition(rec.changed && rec.autoShiftedOffActive == ["chat:1"])
        precondition(routed.active == 0 && routed.activeFocused == "term:1")
        precondition(routed.stacks[3] == ["chat:1"] && routed.focusedByWorkspace[3] == "chat:1")

        // Manual move of "safari:1" to workspace 0 is NOT overridden on subsequent reconcile!
        _ = routed.moveWindow("safari:1", to: 0)
        let rec2 = routed.reconcile(
            discovered: ["term:1", "safari:1", "chat:1"],
            currentlyFocused: "safari:1",
            assignedWorkspace: rule
        )
        precondition(!rec2.changed && rec2.autoShiftedOffActive.isEmpty)
        precondition(routed.stacks[0].contains("safari:1"))

        print("Virtual workspace engine tests passed")
    }
}
