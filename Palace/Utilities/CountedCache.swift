//
//  CountedCache.swift
//  Palace
//
//  An NSCache that keeps a count of the bytes it holds, for the memory event
//  line (PP-5509). NSCache does not report its size, so the count is kept here:
//  added on insert, subtracted on remove and on NSCache's own evictions.
//

import Foundation

/// A byte total that several caches can add to. A cache made per screen
/// reports into a shared counter, so one registration covers every instance.
final class CacheByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    var bytes: Int { lock.withLock { total } }

    fileprivate func add(_ delta: Int) {
        lock.withLock { total += delta }
    }
}

/// `@unchecked Sendable`: `cache` is thread-safe, and `entries`, `ownBytes`
/// are only touched under `lock`. `lock` is never held while calling into
/// `cache`, because NSCache can call the eviction delegate on the thread that
/// holds its own lock.
final class CountedCache<Key: Hashable, Value>: @unchecked Sendable {

    private final class WrappedKey: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? WrappedKey)?.key == key
        }
    }

    /// One insert. The count is tied to the box, not the key, so the eviction
    /// of a value that was already replaced subtracts nothing.
    private final class Box {
        let key: Key
        let value: Value
        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private struct Entry {
        let box: ObjectIdentifier
        let bytes: Int
    }

    private let cache = NSCache<WrappedKey, Box>()
    /// NSCache keeps its delegate unretained.
    private let evictionDelegate: EvictionDelegate
    private let counter: CacheByteCounter
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var ownBytes = 0

    init(counter: CacheByteCounter = CacheByteCounter()) {
        self.counter = counter
        let delegate = EvictionDelegate()
        evictionDelegate = delegate
        delegate.onEvict = { [weak self] object in
            guard let box = object as? Box else { return }
            self?.forget(box)
        }
        cache.delegate = delegate
    }

    deinit {
        cache.delegate = nil
        counter.add(-ownBytes)
    }

    var countLimit: Int {
        get { cache.countLimit }
        set { cache.countLimit = newValue }
    }

    var totalCostLimit: Int {
        get { cache.totalCostLimit }
        set { cache.totalCostLimit = newValue }
    }

    var name: String {
        get { cache.name }
        set { cache.name = newValue }
    }

    /// Bytes held by this cache now.
    var byteCount: Int { lock.withLock { ownBytes } }

    func object(forKey key: Key) -> Value? {
        cache.object(forKey: WrappedKey(key))?.value
    }

    /// `cost` goes to NSCache's limits; `bytes` (default `cost`) goes to the
    /// count. They differ where a cache sets no cost today, so counting does
    /// not start a limit that was never enforced.
    func setObject(_ value: Value, forKey key: Key, cost: Int, bytes: Int? = nil) {
        let box = Box(key: key, value: value)
        let counted = max(0, bytes ?? cost)
        lock.withLock {
            let previous = entries.updateValue(Entry(box: ObjectIdentifier(box), bytes: counted), forKey: key)
            adjust(counted - (previous?.bytes ?? 0))
        }
        cache.setObject(box, forKey: WrappedKey(key), cost: cost)
    }

    func removeObject(forKey key: Key) {
        lock.withLock {
            if let removed = entries.removeValue(forKey: key) {
                adjust(-removed.bytes)
            }
        }
        cache.removeObject(forKey: WrappedKey(key))
    }

    func removeAllObjects() {
        lock.withLock {
            entries.removeAll()
            adjust(-ownBytes)
        }
        cache.removeAllObjects()
    }

    private func forget(_ box: Box) {
        lock.withLock {
            guard let entry = entries[box.key], entry.box == ObjectIdentifier(box) else { return }
            entries[box.key] = nil
            adjust(-entry.bytes)
        }
    }

    /// Caller holds `lock`.
    private func adjust(_ delta: Int) {
        guard delta != 0 else { return }
        ownBytes += delta
        counter.add(delta)
    }
}

/// Not generic, so it can conform to the Objective-C delegate protocol.
private final class EvictionDelegate: NSObject, NSCacheDelegate, @unchecked Sendable {
    /// Set once in `CountedCache.init`, before the delegate is installed.
    var onEvict: ((Any) -> Void)?

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        onEvict?(obj)
    }
}
