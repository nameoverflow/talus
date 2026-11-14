import Foundation

struct WorkspaceLayoutState: Equatable {
    var layoutMode: Int
    var ratio: Double
    var masters: Int

    init(layoutMode: Int = 0, ratio: Double = 0.5, masters: Int = 1) {
        self.layoutMode = layoutMode
        self.ratio = ratio
        self.masters = masters
    }
}

/// Pure XMonad-inspired virtual workspace state machine.
/// Keeps independent window stacks, remembered focus, and layout parameters per workspace.
final class VirtualWorkspaceEngine<ID: Hashable> {
    private(set) var count: Int
    private(set) var active: Int = 0
    private(set) var stacks: [[ID]]
    private(set) var focusedByWorkspace: [Int: ID] = [:]
    var layouts: [WorkspaceLayoutState]

    private var defaultRatio: Double
    private var defaultMasters: Int

    init(count: Int = 5, defaultRatio: Double = 0.5, defaultMasters: Int = 1) {
        let clamped = min(9, max(1, count))
        self.count = clamped
        self.defaultRatio = defaultRatio
        self.defaultMasters = defaultMasters
        self.stacks = Array(repeating: [], count: clamped)
        self.layouts = Array(
            repeating: WorkspaceLayoutState(layoutMode: 0, ratio: defaultRatio, masters: defaultMasters),
            count: clamped
        )
    }

    var activeLayout: WorkspaceLayoutState {
        get { layouts[active] }
        set { layouts[active] = newValue }
    }

    var activeWindows: [ID] {
        stacks[active]
    }

    var inactiveWindows: [ID] {
        var result: [ID] = []
        for idx in 0..<count where idx != active {
            result.append(contentsOf: stacks[idx])
        }
        return result
    }

    var allWindows: [ID] {
        stacks.flatMap { $0 }
    }

    var activeFocused: ID? {
        if let f = focusedByWorkspace[active], stacks[active].contains(f) {
            return f
        }
        return stacks[active].first
    }

    func workspace(containing id: ID) -> Int? {
        stacks.firstIndex { $0.contains(id) }
    }

    func windowCount(in workspace: Int) -> Int {
        guard (0..<count).contains(workspace) else { return 0 }
        return stacks[workspace].count
    }

    func seedFromCurrentDesktop(
        _ orderedWindows: [ID],
        focused: ID?,
        assignedWorkspace: (ID) -> Int? = { _ in nil }
    ) {
        var seen: Set<ID> = []
        let unique = orderedWindows.filter { seen.insert($0).inserted }
        for idx in 0..<count {
            stacks[idx].removeAll()
        }
        focusedByWorkspace.removeAll()
        for id in unique {
            let ws = assignedWorkspace(id).flatMap { (0..<count).contains($0) ? $0 : nil } ?? active
            stacks[ws].append(id)
        }
        for ws in 0..<count where !stacks[ws].isEmpty {
            if let focused, stacks[ws].contains(focused) {
                focusedByWorkspace[ws] = focused
            } else {
                focusedByWorkspace[ws] = stacks[ws].first
            }
        }
    }

    func updateDefaults(ratio: Double, masters: Int) {
        let ratioChanged = abs(ratio - defaultRatio) > 0.0001
        let mastersChanged = masters != defaultMasters
        for idx in 0..<count {
            if ratioChanged && abs(layouts[idx].ratio - defaultRatio) < 0.0001 {
                layouts[idx].ratio = ratio
            }
            if mastersChanged && layouts[idx].masters == defaultMasters {
                layouts[idx].masters = masters
            }
        }
        defaultRatio = ratio
        defaultMasters = masters
    }

    func resizeCount(to requestedCount: Int) {
        let newCount = min(9, max(1, requestedCount))
        guard newCount != count else { return }

        if newCount > count {
            for _ in count..<newCount {
                stacks.append([])
                layouts.append(WorkspaceLayoutState(layoutMode: 0, ratio: defaultRatio, masters: defaultMasters))
            }
        } else {
            let lastIdx = newCount - 1
            for overflowIdx in newCount..<count {
                for id in stacks[overflowIdx] where !stacks[lastIdx].contains(id) {
                    stacks[lastIdx].append(id)
                }
                focusedByWorkspace.removeValue(forKey: overflowIdx)
            }
            stacks.removeSubrange(newCount..<count)
            layouts.removeSubrange(newCount..<count)
            if active >= newCount {
                active = lastIdx
            }
            if focusedByWorkspace[lastIdx] == nil || !stacks[lastIdx].contains(focusedByWorkspace[lastIdx]!) {
                focusedByWorkspace[lastIdx] = stacks[lastIdx].first
            }
        }
        count = newCount
    }

    /// Reconciles live windows discovered by macOS with workspace stacks:
    /// - Removes closed windows from any workspace, shifting focus to a deterministic neighbor.
    /// - Preserves stack ordering of already-tracked windows.
    /// - Routes newly created windows matching an app rule directly to their assigned workspace (`doShift`),
    ///   or inserts them onto `active` at the focused slot (XMonad style).
    @discardableResult
    func reconcile(
        discovered: [ID],
        currentlyFocused: ID?,
        assignedWorkspace: (ID) -> Int? = { _ in nil },
        canInsertBeforeFocus: (ID, ID) -> Bool = { _, _ in true }
    ) -> (changed: Bool, autoShiftedOffActive: [ID]) {
        let beforeStacks = stacks
        var autoShifted: [ID] = []
        var uniqueDiscovered: [ID] = []
        var seenDiscovered: Set<ID> = []
        for id in discovered where seenDiscovered.insert(id).inserted {
            uniqueDiscovered.append(id)
        }

        // 1. Prune closed windows from every workspace while picking neighbor focus
        for ws in 0..<count {
            let oldStack = stacks[ws]
            let newStack = oldStack.filter { seenDiscovered.contains($0) }
            if newStack != oldStack {
                if let oldFocus = focusedByWorkspace[ws], !newStack.contains(oldFocus) {
                    if let oldIdx = oldStack.firstIndex(of: oldFocus), !newStack.isEmpty {
                        // Prefer next surviving window at or after oldIdx, otherwise preceding neighbor
                        var replacement: ID?
                        for probe in (oldIdx + 1)..<oldStack.count {
                            if seenDiscovered.contains(oldStack[probe]) {
                                replacement = oldStack[probe]
                                break
                            }
                        }
                        if replacement == nil {
                            for probe in stride(from: oldIdx - 1, through: 0, by: -1) {
                                if seenDiscovered.contains(oldStack[probe]) {
                                    replacement = oldStack[probe]
                                    break
                                }
                            }
                        }
                        focusedByWorkspace[ws] = replacement ?? newStack.first
                    } else {
                        focusedByWorkspace[ws] = newStack.first
                    }
                }
                stacks[ws] = newStack
            }
        }

        // 2. Track all currently assigned windows
        var assigned = Set(stacks.flatMap { $0 })

        // Update active focus before inserting new windows if focus is already on an active window
        if let currentlyFocused, stacks[active].contains(currentlyFocused) {
            focusedByWorkspace[active] = currentlyFocused
        }

        // 3. Route newly discovered windows either to their rule workspace (`doShift`) or onto `active`
        let anchorFocus = activeFocused
        for id in uniqueDiscovered where !assigned.contains(id) {
            assigned.insert(id)
            let targetWS = assignedWorkspace(id).flatMap { (0..<count).contains($0) ? $0 : nil } ?? active
            if targetWS != active {
                stacks[targetWS].insert(id, at: 0)
                focusedByWorkspace[targetWS] = id
                autoShifted.append(id)
            } else {
                if let anchor = anchorFocus,
                   let anchorIdx = stacks[active].firstIndex(of: anchor),
                   canInsertBeforeFocus(id, anchor) {
                    stacks[active].insert(id, at: anchorIdx)
                } else {
                    stacks[active].append(id)
                }
                if currentlyFocused == id || focusedByWorkspace[active] == nil {
                    focusedByWorkspace[active] = id
                }
            }
        }

        // 4. Normalize active workspace focus
        if let f = focusedByWorkspace[active], !stacks[active].contains(f) {
            focusedByWorkspace[active] = stacks[active].first
        } else if focusedByWorkspace[active] == nil {
            focusedByWorkspace[active] = stacks[active].first
        }

        return (stacks != beforeStacks, autoShifted)
    }

    @discardableResult
    func switchTo(_ target: Int) -> Bool {
        guard (0..<count).contains(target), target != active else { return false }
        active = target
        if let f = focusedByWorkspace[active], stacks[active].contains(f) {
            // keep remembered focus
        } else {
            focusedByWorkspace[active] = stacks[active].first
        }
        return true
    }

    /// Moves `id` to `target` workspace without leaving `active` (XMonad `W.shift`).
    /// Returns whether a move occurred and the next window to focus on `active` (nil if `active` became empty).
    func moveWindow(_ id: ID, to target: Int) -> (moved: Bool, nextFocusOnActive: ID?) {
        guard (0..<count).contains(target),
              let source = workspace(containing: id),
              source != target,
              let oldIdx = stacks[source].firstIndex(of: id)
        else {
            return (false, activeFocused)
        }

        stacks[source].remove(at: oldIdx)
        if focusedByWorkspace[source] == id {
            if stacks[source].isEmpty {
                focusedByWorkspace.removeValue(forKey: source)
            } else {
                focusedByWorkspace[source] = stacks[source][min(oldIdx, stacks[source].count - 1)]
            }
        }

        stacks[target].removeAll { $0 == id }
        stacks[target].insert(id, at: 0)
        focusedByWorkspace[target] = id

        return (true, activeFocused)
    }

    /// Called when macOS reports focus moved to `id` (e.g. via `⌘Tab` or Dock click).
    /// Returns the new workspace index if `active` switched to an inactive workspace, or `nil` otherwise.
    func handleExternalFocus(_ id: ID) -> Int? {
        guard let ws = workspace(containing: id) else { return nil }
        focusedByWorkspace[ws] = id
        if ws != active {
            active = ws
            return ws
        }
        return nil
    }

    func setActiveFocus(_ id: ID?) {
        if let id, stacks[active].contains(id) {
            focusedByWorkspace[active] = id
        } else if stacks[active].isEmpty {
            focusedByWorkspace.removeValue(forKey: active)
        }
    }

    func replaceActiveStack(_ newOrder: [ID]) {
        var seen: Set<ID> = []
        let currentSet = Set(stacks[active])
        var filtered = newOrder.filter { currentSet.contains($0) && seen.insert($0).inserted }
        for id in stacks[active] where seen.insert(id).inserted {
            filtered.append(id)
        }
        stacks[active] = filtered
        if let f = focusedByWorkspace[active], !filtered.contains(f) {
            focusedByWorkspace[active] = filtered.first
        }
    }
}
