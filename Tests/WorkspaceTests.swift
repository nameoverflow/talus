@main struct WorkspaceTests {
    static func main() {
        var spaces = Workspaces<Int>(count: 3)
        spaces.insert(1); spaces.insert(2)
        spaces.sendFocused(to: 2)
        precondition(spaces.currentStack.items == [1])
        spaces.view(2)
        precondition(spaces.currentStack.items == [2] && spaces.currentStack.focused == 2)
        spaces.insert(3); spaces.view(1)
        precondition(spaces.currentStack.focused == 1)
        spaces.view(2); precondition(spaces.currentStack.focused == 3)
        spaces.remove(2); precondition(spaces.currentStack.items == [3])
        spaces.view(99); precondition(spaces.current == 2)
        spaces.sendFocused(to: 99); precondition(spaces.currentStack.items == [3])
        print("Workspace state tests passed")
    }
}
