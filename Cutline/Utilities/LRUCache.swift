import Foundation

/// A thread-safe cache that, when full, drops the entries used longest ago, so the
/// ones in use (a static grade, a clip's text) survive while others come and go (an
/// animated grade makes a new entry every frame). Limited by count and by cost.
nonisolated final class LRUCache<Key: Hashable, Value>: @unchecked Sendable {
    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var totalCost = 0
    let countLimit: Int
    let costLimit: Int

    init(countLimit: Int, costLimit: Int = .max) {
        self.countLimit = max(1, countLimit)
        self.costLimit = costLimit
    }

    var count: Int {
        lock.withLock { entries.count }
    }

    subscript(key: Key) -> Value? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            clock += 1
            entry.lastUse = clock
            entries[key] = entry
            return entry.value
        }
    }

    func set(_ value: Value, for key: Key, cost: Int = 1) {
        lock.withLock {
            clock += 1
            if let old = entries[key] { totalCost -= old.cost }
            entries[key] = Entry(value: value, cost: cost, lastUse: clock)
            totalCost += cost
            evict()
        }
    }

    /// The cached value, or `make()`'s result stored for next time. `make` runs outside
    /// the lock, so slow work doesn't hold up other threads.
    func value(for key: Key, cost: (Value) -> Int = { _ in 1 }, _ make: () -> Value) -> Value {
        if let cached = self[key] { return cached }
        let value = make()
        set(value, for: key, cost: cost(value))
        return value
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            totalCost = 0
        }
    }

    /// Drops the least recently used entries until within both limits (the newest stays).
    private func evict() {
        guard entries.count > countLimit || totalCost > costLimit else { return }
        let oldestFirst = entries.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, entry) in oldestFirst where entries.count > 1 && (entries.count > countLimit || totalCost > costLimit) {
            entries[key] = nil
            totalCost -= entry.cost
        }
    }
}
