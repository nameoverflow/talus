/// Logical workspaces. Hiding and restoring native windows belongs to the backend.
struct Workspaces<ID: Equatable> {
    private(set) var current: Int = 1
    private(set) var stacks: [Int: WindowStack<ID>] = [:]

    init(count: Int = 9) {
        precondition(count > 0)
        for number in 1...count { stacks[number] = WindowStack() }
    }
    var currentStack: WindowStack<ID> { stacks[current]! }
    mutating func view(_ number: Int) {
        guard stacks[number] != nil else { return }
        current = number
    }
    mutating func insert(_ id: ID) {
        guard !stacks.values.contains(where: { $0.items.contains(id) }) else { return }
        stacks[current]!.insert(id)
    }
    mutating func remove(_ id: ID) {
        for number in stacks.keys where stacks[number]!.items.contains(id) { stacks[number]!.remove(id) }
    }
    mutating func focus(_ id: ID) { stacks[current]!.focus(id) }
    mutating func focusNext(_ direction: Int) { stacks[current]!.focusNext(direction) }
    mutating func swapNext(_ direction: Int) { stacks[current]!.swapNext(direction) }
    mutating func swapMaster() { stacks[current]!.swapMaster() }
    mutating func sendFocused(to target: Int) {
        guard target != current, stacks[target] != nil, let id = stacks[current]!.focused else { return }
        stacks[current]!.remove(id)
        stacks[target]!.insert(id)
    }
}
