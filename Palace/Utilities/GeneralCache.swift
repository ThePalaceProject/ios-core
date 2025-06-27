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
final class GeneralCache<Key: Hashable & Codable, Value: Codable> {
    let memoryCache = NSCache<WrappedKey, Entry>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let queue = DispatchQueue(label: "GeneralCacheQueue", attributes: .concurrent)
    private let mode: CachingMode

    struct Entry: Codable {
        let value: Value
        let expiration: Date?
    }

    private class WrappedKey: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? WrappedKey else { return false }
            return other.key == key
        }
    }

    init(cacheName: String = "GeneralCache", mode: CachingMode = .memoryAndDisk) {
        self.mode = mode
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent(cacheName)
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    /// Set a value in the cache with optional expiration.
    func set(_ value: Value, for key: Key, expiresIn: TimeInterval? = nil) {
        let expiration = expiresIn.map { Date().addingTimeInterval($0) }
        let entry = Entry(value: value, expiration: expiration)
        let wrappedKey = WrappedKey(key)
        queue.async(flags: .barrier) {
            switch self.mode {
            case .memoryOnly:
                self.memoryCache.setObject(entry, forKey: wrappedKey)
            case .diskOnly:
                self.saveToDisk(entry, for: key)
            case .memoryAndDisk:
                self.memoryCache.setObject(entry, forKey: wrappedKey)
                self.saveToDisk(entry, for: key)
            case .none:
                break
            }
        }
    }

    /// Get a value from the cache (memory/disk) if available and not expired.
    func get(for key: Key) -> Value? {
        let wrappedKey = WrappedKey(key)
        var entry: Entry?
        queue.sync {
            if self.mode == .memoryOnly || self.mode == .memoryAndDisk {
                entry = self.memoryCache.object(forKey: wrappedKey)
            }
        }
        if let entry = entry {
            if let expiration = entry.expiration, expiration < Date() {
                remove(for: key)
                return nil
            }
            return entry.value
        }
        if self.mode == .diskOnly || self.mode == .memoryAndDisk {
            if let entry = loadFromDisk(for: key) {
                if let expiration = entry.expiration, expiration < Date() {
                    remove(for: key)
                    return nil
                }
                // Promote to memory if allowed
                if self.mode == .memoryAndDisk {
                    queue.async(flags: .barrier) {
                        self.memoryCache.setObject(entry, forKey: wrappedKey)
                    }
                }
                return entry.value
            }
        }
        return nil
    }

    /// Remove a value from the cache.
    func remove(for key: Key) {
        let wrappedKey = WrappedKey(key)
        queue.async(flags: .barrier) {
            if self.mode == .memoryOnly || self.mode == .memoryAndDisk {
                self.memoryCache.removeObject(forKey: wrappedKey)
            }
            if self.mode == .diskOnly || self.mode == .memoryAndDisk {
                let fileURL = self.fileURL(for: key)
                try? self.fileManager.removeItem(at: fileURL)
            }
        }
    }

    /// Clear the entire cache.
    func clear() {
        queue.async(flags: .barrier) {
            if self.mode == .memoryOnly || self.mode == .memoryAndDisk {
                self.memoryCache.removeAllObjects()
            }
            if self.mode == .diskOnly || self.mode == .memoryAndDisk {
                if let files = try? self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil) {
                    for file in files { try? self.fileManager.removeItem(at: file) }
                }
            }
        }
    }

    // MARK: - Disk
    private func fileURL(for key: Key) -> URL {
        let data = try? JSONEncoder().encode(key)
        let keyString = data?.base64EncodedString() ?? String(describing: key)
        return cacheDirectory.appendingPathComponent(keyString)
    }

    private func saveToDisk(_ entry: Entry, for key: Key) {
        let fileURL = fileURL(for: key)
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: fileURL)
        }
    }

    private func loadFromDisk(for key: Key) -> Entry? {
        let fileURL = fileURL(for: key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    // MARK: - Policy-based API
    /// Get a value using a cache policy and async fetcher.
    /// - Parameters:
    ///   - key: The cache key
    ///   - policy: The cache policy to use
    ///   - fetcher: Closure to fetch from server if needed
    /// - Returns: The value, from cache or server
    @discardableResult
    func get(for key: Key, policy: CachePolicy, fetcher: @escaping () async throws -> Value) async throws -> Value {
        switch policy {
        case .cacheFirst:
            if let cached = get(for: key) {
                return cached
            }
            let value = try await fetcher()
            set(value, for: key)
            return value
        case .networkFirst:
            let value = try await fetcher()
            set(value, for: key)
            return value
        case .cacheThenNetwork:
            if let cached = get(for: key) {
                // Optionally, you could update the cache in background
                Task {
                    let value = try? await fetcher()
                    if let value = value { self.set(value, for: key) }
                }
                return cached
            } else {
                let value = try await fetcher()
                set(value, for: key)
                return value
            }
        case .timedCache(let interval):
            if let entry = getEntry(for: key), let expiration = entry.expiration, expiration > Date() {
                return entry.value
            }
            let value = try await fetcher()
            set(value, for: key, expiresIn: interval)
            return value
        case .noCache:
            return try await fetcher()
        }
    }

    // Helper to get the full entry (for expiration logic)
    private func getEntry(for key: Key) -> Entry? {
        let wrappedKey = WrappedKey(key)
        var entry: Entry?
        queue.sync {
            if self.mode == .memoryOnly || self.mode == .memoryAndDisk {
                entry = self.memoryCache.object(forKey: wrappedKey)
            }
        }
        if let entry = entry {
            if let expiration = entry.expiration, expiration < Date() {
                remove(for: key)
                return nil
            }
            return entry
        }
        if self.mode == .diskOnly || self.mode == .memoryAndDisk {
            if let entry = loadFromDisk(for: key) {
                if let expiration = entry.expiration, expiration < Date() {
                    remove(for: key)
                    return nil
                }
                if self.mode == .memoryAndDisk {
                    queue.async(flags: .barrier) {
                        self.memoryCache.setObject(entry, forKey: wrappedKey)
                    }
                }
                return entry
            }
        }
        return nil
    }
} 