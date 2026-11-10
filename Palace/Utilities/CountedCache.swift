//
//  CountedCache.swift
//  Palace
//
//  An NSCache that keeps a count of the bytes it holds, for the memory event
//  line (PP-5509). NSCache does not report its size, so the count is kept here.
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

/// Counts what NSCache holds, not what was asked of it. Every insert is a new
/// box: its bytes are added before NSCache gets it and subtracted only when
/// NSCache reports that exact box evicted. NSCache reports a box on
/// replacement, `removeObject(forKey:)`, `removeAllObjects()` and its own limit
/// evictions, so the count equals the boxes NSCache holds whatever order
/// concurrent calls run in.
///
/// A value stored under several keys (ImageCache and GeneralCache do this)
/// is held in memory once, so its bytes count once, while any key holds it.
///
/// `@unchecked Sendable`: `cache` is thread-safe; `live`, `values` and
/// `ownBytes` are only touched under `lock`. `lock` is never held while calling
/// into `cache`, because NSCache calls the eviction delegate while it holds its
/// own lock.
final class CountedCache<Key: Hashable, Value: AnyObject>: @unchecked Sendable {

    private final class WrappedKey: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? WrappedKey)?.key == key
        }
    }

    private final class Box {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private struct ValueCount {
        var boxes: Int
        let bytes: Int
    }

    private let cache = NSCache<WrappedKey, Box>()
    /// NSCache keeps its delegate unretained.
    private let evictionDelegate: EvictionDelegate
    private let counter: CacheByteCounter
    private let lock = NSLock()
    /// Box identity to its value's identity, for every box NSCache holds.
    private var live: [ObjectIdentifier: ObjectIdentifier] = [:]
    /// Value identity to the number of live boxes holding it and its bytes.
    private var values: [ObjectIdentifier: ValueCount] = [:]
    private var ownBytes = 0

    init(counter: CacheByteCounter = CacheByteCounter()) {
        self.counter = counter
        let delegate = EvictionDelegate()
        evictionDelegate = delegate
        delegate.onEvict = { [weak self] object in
            guard let box = object as? Box else { return }
            self?.release(box)
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
        let box = Box(value)
        let valueID = ObjectIdentifier(value)
        lock.withLock {
            live[ObjectIdentifier(box)] = valueID
            if values[valueID] != nil {
                values[valueID]?.boxes += 1
            } else {
                let counted = max(0, bytes ?? cost)
                values[valueID] = ValueCount(boxes: 1, bytes: counted)
                adjust(counted)
            }
        }
        cache.setObject(box, forKey: WrappedKey(key), cost: cost)
    }

    func removeObject(forKey key: Key) {
        cache.removeObject(forKey: WrappedKey(key))
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }

    private func release(_ box: Box) {
        lock.withLock {
            guard let valueID = live.removeValue(forKey: ObjectIdentifier(box)),
                  var count = values[valueID] else { return }
            count.boxes -= 1
            if count.boxes > 0 {
                values[valueID] = count
            } else {
                values[valueID] = nil
                adjust(-count.bytes)
            }
        }
    }

    /// Caller holds `lock`.
    private func adjust(_ delta: Int) {
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
