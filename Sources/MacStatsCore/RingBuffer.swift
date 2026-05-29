/// Fixed-capacity buffer that keeps the most recent `capacity` appended values.
public struct RingBuffer<Element> {
    private var storage: [Element] = []
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be > 0")
        self.capacity = capacity
    }

    public mutating func append(_ element: Element) {
        storage.append(element)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Oldest-to-newest.
    public var values: [Element] { storage }
    public var count: Int { storage.count }
}
