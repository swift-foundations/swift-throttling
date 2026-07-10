//
//  RateLimiter.Storage.swift
//  swift-throttling
//
//  Created by Coen ten Thije Boonkkamp on 19/12/2024.
//

extension RateLimiter {
    /// A capacity-bounded, least-recently-used (LRU) key/value store backing
    /// ``RateLimiter``'s per-key attempt tracking.
    ///
    /// `Storage` enforces a fixed maximum number of entries. When a new key is
    /// inserted past capacity, the least recently used entry is evicted. Both
    /// reads (``cachedValue(for:)``) and writes (``setValue(_:for:)``) refresh
    /// an entry's recency, so frequently touched keys survive eviction.
    ///
    /// This is internal machinery: it exists because the rate limiter's
    /// documented contract ("Bounded cache with LRU eviction",
    /// "Bounded cache prevents memory exhaustion") requires capacity bounding
    /// and predicate retention that the composed cache primitive does not yet
    /// provide. It is value-typed and held in actor-isolated storage, so no
    /// internal synchronization is required.
    struct Storage<Value: Sendable>: Sendable {
        /// The maximum number of entries retained before LRU eviction begins.
        private let capacity: Int

        /// The cached values, keyed by ``Key``.
        private var entries: [Key: Value]

        /// The monotonically increasing recency stamp for each live key.
        ///
        /// Higher values are more recently accessed; the entry with the
        /// smallest stamp is the least recently used.
        private var recency: [Key: UInt64]

        /// A monotonic counter minted on each access to stamp recency.
        private var clock: UInt64

        /// Creates an empty store bounded to at most `capacity` entries.
        ///
        /// - Parameter capacity: The maximum number of entries to retain.
        ///   Values below `1` are clamped to `1`, since a zero-capacity store
        ///   could never retain the entry it was just asked to hold.
        init(capacity: Int) {
            self.capacity = Swift.max(1, capacity)
            self.entries = [:]
            self.recency = [:]
            self.clock = 0
        }

        /// The number of entries currently retained.
        var count: Int {
            entries.count
        }

        /// Returns the value cached for `key`, refreshing its recency on a hit.
        ///
        /// - Parameter key: The key to look up.
        /// - Returns: The cached value, or `nil` if `key` is not present.
        mutating func cachedValue(for key: Key) -> Value? {
            guard let value = entries[key] else { return nil }
            touch(key)
            return value
        }

        /// Stores `value` for `key`, refreshing its recency.
        ///
        /// Inserting a previously unseen key past ``capacity`` evicts the least
        /// recently used entry. Updating an existing key never evicts, since the
        /// entry count does not grow.
        ///
        /// - Parameters:
        ///   - value: The value to store.
        ///   - key: The key to store it under.
        mutating func setValue(_ value: Value, for key: Key) {
            let isNewKey = entries[key] == nil
            entries[key] = value
            touch(key)
            if isNewKey {
                evictIfNeeded()
            }
        }

        /// Removes and returns the value cached for `key`, if any.
        ///
        /// - Parameter key: The key to remove.
        /// - Returns: The removed value, or `nil` if `key` was not present.
        @discardableResult
        mutating func removeValue(for key: Key) -> Value? {
            recency[key] = nil
            return entries.removeValue(forKey: key)
        }

        /// Retains only the entries for which `isIncluded` returns `true`.
        ///
        /// This is a bulk maintenance scan: it does not refresh the recency of
        /// surviving entries, preserving their relative eviction order.
        ///
        /// - Parameter isIncluded: A predicate evaluated for each key/value
        ///   pair; entries for which it returns `false` are dropped.
        mutating func filter(_ isIncluded: (Key, Value) -> Bool) {
            var removals: [Key] = []
            for (key, value) in entries where !isIncluded(key, value) {
                removals.append(key)
            }
            for key in removals {
                entries[key] = nil
                recency[key] = nil
            }
        }

        /// Stamps `key` as the most recently used entry.
        private mutating func touch(_ key: Key) {
            clock &+= 1
            recency[key] = clock
        }

        /// Evicts the least recently used entry while over capacity.
        private mutating func evictIfNeeded() {
            while entries.count > capacity {
                guard let leastRecentlyUsed = recency.min(by: { $0.value < $1.value })?.key
                else { return }
                entries[leastRecentlyUsed] = nil
                recency[leastRecentlyUsed] = nil
            }
        }
    }
}
