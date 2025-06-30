import Foundation
import UIKit

/// Where to store cached data
public enum CachingMode {
    case memoryOnly
    case diskOnly
    case memoryAndDisk
    case none
}

/// How to use/update the cache
public enum CachePolicy {
    case cacheFirst
    case networkFirst
    case cacheThenNetwork
    case timedCache(TimeInterval)
    case noCache
}

/// A general-purpose cache supporting in-memory and optional disk caching with expiration and cache policies.
/// Key must be Hashable & Codable, Value must be Codable.
public final class GeneralCache<Key: Hashable & Codable, Value: Codable> {
    private let memoryCache = NSCache<WrappedKey, Entry>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let queue = DispatchQueue(label: "GeneralCacheQueue", attributes: .concurrent)
    private let mode: CachingMode

    private final class Entry: Codable {
        let value: Value
        let expiration: Date?

        init(value: Value, expiration: Date?) {
            self.value = value
            self.expiration = expiration
        }

        var isExpired: Bool {
            if let exp = expiration {
                return exp < Date()
            }
            return false
        }
    }

    private final class WrappedKey: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? WrappedKey else { return false }
            return other.key == key
        }
    }

    /// Initializes the cache
    public init(cacheName: String = "GeneralCache", mode: CachingMode = .memoryAndDisk) {
        self.mode = mode
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDir.appendingPathComponent(cacheName, isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Store a value with optional expiration
    public func set(_ value: Value, for key: Key, expiresIn interval: TimeInterval? = nil) {
        let expiration = interval.map { Date().addingTimeInterval($0) }
        let entry = Entry(value: value, expiration: expiration)
        let wrapped = WrappedKey(key)

        queue.async(flags: .barrier) {
            switch self.mode {
            case .memoryOnly:
                self.memoryCache.setObject(entry, forKey: wrapped)
            case .diskOnly:
                self.save(entry, for: key)
            case .memoryAndDisk:
                self.memoryCache.setObject(entry, forKey: wrapped)
                self.save(entry, for: key)
            case .none:
                break
            }
        }
    }

    /// Retrieve a value if present and not expired
    public func get(for key: Key) -> Value? {
        guard let value = loadValue(for: key) else { return nil }
        return value
    }

    /// Remove a value from cache
    public func remove(for key: Key) {
        let wrapped = WrappedKey(key)
        queue.async(flags: .barrier) {
            if self.mode == .memoryOnly || self.mode == .memoryAndDisk {
                self.memoryCache.removeObject(forKey: wrapped)
            }
            if self.mode == .diskOnly || self.mode == .memoryAndDisk {
                try? self.fileManager.removeItem(at: self.fileURL(for: key))
            }
        }
    }

    /// Clear entire cache (memory + disk)
    public func clear() {
        queue.async(flags: .barrier) {
            if self.mode == .memoryOnly || self.mode == .memoryAndDisk {
                self.memoryCache.removeAllObjects()
            }
            if self.mode == .diskOnly || self.mode == .memoryAndDisk {
                (try? self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil))?
                    .forEach { try? self.fileManager.removeItem(at: $0) }
            }
        }
    }

    /// Clear only the in-memory cache
    public func clearMemory() {
        queue.async(flags: .barrier) {
            self.memoryCache.removeAllObjects()
        }
    }

    // MARK: - Policy-based API
    @discardableResult
    public func get(
        _ key: Key,
        policy: CachePolicy,
        fetcher: @escaping () async throws -> Value
    ) async throws -> Value {
        switch policy {
        case .cacheFirst:
            if let cached = get(for: key) { return cached }
            fallthrough
        case .networkFirst:
            let value = try await fetcher()
            set(value, for: key)
            return value
        case .cacheThenNetwork:
            if let cached = get(for: key) {
                Task.detached {
                    if let fresh = try? await fetcher() {
                        self.set(fresh, for: key)
                    }
                }
                return cached
            } else {
                let value = try await fetcher()
                set(value, for: key)
                return value
            }
        case .timedCache(let interval):
            if let entryValue = loadValue(for: key) {
                return entryValue
            }
            let fresh = try await fetcher()
            set(fresh, for: key, expiresIn: interval)
            return fresh
        case .noCache:
            return try await fetcher()
        }
    }

    // MARK: - Private Helpers

    private func loadValue(for key: Key) -> Value? {
        let wrapped = WrappedKey(key)
        // in-memory
        if mode == .memoryOnly || mode == .memoryAndDisk {
            if let entry = memoryCache.object(forKey: wrapped), !entry.isExpired {
                return entry.value
            }
            if mode == .memoryAndDisk {
                memoryCache.removeObject(forKey: wrapped)
            }
        }
        // disk
        if mode == .diskOnly || mode == .memoryAndDisk {
            let url = fileURL(for: key)
            // check expiration via file attribute
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let exp = attrs[.modificationDate] as? Date,
               exp < Date() {
                remove(for: key)
                return nil
            }
            // read raw data
            guard let raw = try? Data(contentsOf: url) else { return nil }
            // decode
            let value: Value
            if Value.self == Data.self {
                // direct Data
                value = raw as! Value
            } else if let entry = try? JSONDecoder().decode(Entry.self, from: raw), !entry.isExpired {
                value = entry.value
                // prime memory
                if mode == .memoryAndDisk {
                    queue.async(flags: .barrier) {
                        self.memoryCache.setObject(entry, forKey: wrapped)
                    }
                }
            } else {
                remove(for: key)
                return nil
            }
            return value
        }
        return nil
    }

    private func save(_ entry: Entry, for key: Key) {
        let url = fileURL(for: key)
        if Value.self == Data.self, let raw = entry.value as? Data {
            try? raw.write(to: url)
        } else if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: url)
        }
        // set expiration as file modification date
        if let exp = entry.expiration {
            try? fileManager.setAttributes([.modificationDate: exp], ofItemAtPath: url.path)
        }
    }

    func fileURL(for key: Key) -> URL {
        guard let data = try? JSONEncoder().encode(key) else {
            return cacheDirectory.appendingPathComponent(String(describing: key))
        }
        return cacheDirectory.appendingPathComponent(data.base64EncodedString())
    }
}
