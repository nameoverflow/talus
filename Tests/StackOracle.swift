@main struct StackOracle {
    static func main() {
        for n in 1...12 {
            var initial = WindowStack<Int>()
            for i in (1...n).reversed() { initial.insert(i) }
            var up = initial; up.swapNext(-1)
            var down = initial; down.focusNext(-1); down.swapNext(1)
            for s in [up, down] {
                let focus = s.focused.map { "Just \($0)" } ?? "Nothing"
                print(s.items.map(String.init).joined(separator:",") + ":" + focus)
            }
        }
    }
}
