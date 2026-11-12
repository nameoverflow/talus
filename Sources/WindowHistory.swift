/// Keeps off-Space windows in the order last assigned while replacing the
/// entries belonging to the current Space with their latest order.
func mergeHistory<T>(_ history: [T], current: [T], equals: (T, T) -> Bool) -> [T] {
    var result = history
    for item in current where !result.contains(where: { equals($0, item) }) { result.append(item) }
    let positions = result.indices.filter { index in current.contains { equals($0, result[index]) } }
    for (index, item) in zip(positions, current) { result[index] = item }
    return result
}
func orderUsingHistory<T>(_ current: [T], history: [T], equals: (T, T) -> Bool) -> [T] {
    let known = history.compactMap { old in current.first { equals($0, old) } }
    return known + current.filter { item in !known.contains { equals($0, item) } }
}
