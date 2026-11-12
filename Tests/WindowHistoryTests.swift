@main struct WindowHistoryTests {
 static func main() {
    let original = ["a", "b", "c", "d"]
    let switched = mergeHistory(original, current: ["c", "a"], equals: ==)
    precondition(switched == ["c", "b", "a", "d"])
    precondition(orderUsingHistory(["a", "c"], history: switched, equals: ==) == ["c", "a"])
    precondition(orderUsingHistory(["new", "a"], history: switched, equals: ==) == ["a", "new"])
    print("Space history tests passed")
 }
}
