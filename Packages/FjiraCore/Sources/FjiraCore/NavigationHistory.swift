/// A bounded history of destinations. Revisiting via Back/Forward never adds an entry.
struct NavigationHistory<Destination: Equatable> {
    private var destinations: [Destination]
    private var index = 0
    private let limit: Int

    init(initial: Destination, limit: Int = 100) {
        precondition(limit >= 2)
        destinations = [initial]
        self.limit = limit
    }

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < destinations.count }
    var current: Destination { destinations[index] }

    mutating func visit(_ destination: Destination) {
        guard destination != current else { return }
        destinations.removeSubrange((index + 1)..<destinations.count)
        destinations.append(destination)
        if destinations.count > limit { destinations.removeFirst() }
        index = destinations.count - 1
    }

    mutating func replaceCurrent(_ destination: Destination) {
        destinations[index] = destination
    }

    mutating func goBack() -> Destination? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    mutating func goForward() -> Destination? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }

    mutating func reset(to destination: Destination) {
        destinations = [destination]
        index = 0
    }
}
