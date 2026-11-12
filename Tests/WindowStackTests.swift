@main struct WindowStackTests {
    static func main() {
        var s = WindowStack<Int>()
        s.insert(1); s.insert(2); s.insert(3)
        precondition(s.items == [3, 2, 1] && s.focused == 3)
        s.focusNext(1); precondition(s.focused == 2)
        s.swapNext(1); precondition(s.items == [3, 1, 2] && s.focused == 2)
        s.swapMaster(); precondition(s.items == [2, 1, 3])
        s.remove(2); precondition(s.focused == 1 && s.items == [1, 3])
        s.focusNext(-1); precondition(s.focused == 3)
        s.remove(3); s.remove(1); precondition(s.focused == nil && s.items.isEmpty)
        print("Window stack tests passed")
    }
}
