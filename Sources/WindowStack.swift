/// XMonad-style focused zipper. The first item is the master window.
struct WindowStack<ID: Equatable> {
    private(set) var items: [ID] = []
    private(set) var focused: ID?

    mutating func insert(_ id: ID) {
        guard !items.contains(id) else { return }
        if let focused, let index = items.firstIndex(of: focused) { items.insert(id, at: index) }
        else { items.insert(id, at: 0) }
        focused = id
    }
    mutating func remove(_ id: ID) {
        guard let index = items.firstIndex(of: id) else { return }
        let wasFocused = focused == id
        items.remove(at: index)
        if wasFocused { focused = items.isEmpty ? nil : items[index % items.count] }
    }
    mutating func focus(_ id: ID) {
        if items.contains(id) { focused = id }
    }
    mutating func focusNext(_ direction: Int) {
        guard let focused, let i = items.firstIndex(of: focused), !items.isEmpty else { return }
        let target = (i + (direction >= 0 ? 1 : items.count - 1)) % items.count
        self.focused = items[target]
    }
    mutating func swapNext(_ direction: Int) {
        guard let focused, let i = items.firstIndex(of: focused), items.count > 1 else { return }
        if direction >= 0 && i == items.count - 1 { items.insert(items.removeLast(), at: 0) }
        else if direction < 0 && i == 0 { items.append(items.removeFirst()) }
        else { items.swapAt(i, i + (direction >= 0 ? 1 : -1)) }
    }
    mutating func swapMaster() {
        guard let focused, let i = items.firstIndex(of: focused) else { return }
        items.swapAt(0, i)
    }
}
