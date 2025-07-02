import Foundation
import CryptoKit

public enum CachingMode {
    case memoryOnly
    case diskOnly
    case memoryAndDisk
    case none
}

public enum CachePolicy {
    case cacheFirst
    case networkFirst
    case cacheThenNetwork
    case timedCache(TimeInterval)
    case noCache
}

/// A thread-safe general-purpose cache supporting in-memory and optional disk caching with expiration and cache policies.
/// Key must be Hashable & Codable, Value must be Codable.
public final class GeneralCache<Key: Hashable & Codable, Value: Codable> {
    // MARK: - In-memory
    private let memoryCache = NSCache<WrappedKey, Entry>()
    
    // MARK: - Disk
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let queue = DispatchQueue(label: "com.Palace.GeneralCache", attributes: .concurrent)
    private let mode: CachingMode
    
    // MARK: - Entry
    private final class Entry: Codable {
        let value: Value
        let expiration: Date?
        init(value: Value, expiration: Date?) {
            self.value = value
            self.expiration = expiration
        }
        var isExpired: Bool {
            if let exp = expiration { return exp < Date() }
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
    
    /// Store a value with optional expiration (thread-safe)
    public func set(_ value: Value, for key: Key, expiresIn interval: TimeInterval? = nil) {
        let expiration = interval.map { Date().addingTimeInterval($0) }
        let entry = Entry(value: value, expiration: expiration)
        let wrappedKey = WrappedKey(key)
        
        queue.async(flags: .barrier) {
            // memory
            if self.mode == .memoryOnly || self.mode == .memoryAndDisk {
                self.memoryCache.setObject(entry, forKey: wrappedKey)
            }
            // disk
            if self.mode == .diskOnly || self.mode == .memoryAndDisk {
                self.saveToDisk(entry, for: key)
            }
        }
    }
    
    /// Retrieve a value if present and not expired (thread-safe-ish)
    public func get(for key: Key) -> Value? {
        return queue.sync {
            // 1) memory
            let wrappedKey = WrappedKey(key)
            if self.mode == .memoryOnly || self.mode == .memoryAndDisk,
               let entry = self.memoryCache.object(forKey: wrappedKey), !entry.isExpired {
                return entry.value
            }
            if self.mode == .memoryOnly { return nil }
            // 2) disk
            guard self.mode == .diskOnly || self.mode == .memoryAndDisk else { return nil }
            let url = self.fileURL(for: key)
            do {
                let attrs = try fileManager.attributesOfItem(atPath: url.path)
                if let exp = attrs[.modificationDate] as? Date, exp < Date() {
                    self.remove(for: key)
                    return nil
                }
                let raw = try Data(contentsOf: url, options: .mappedIfSafe)
                let value: Value
                if Value.self == Data.self, let d = raw as? Value {
                    value = d
                } else {
                    let entry = try JSONDecoder().decode(Entry.self, from: raw)
                    guard !entry.isExpired else { self.remove(for: key); return nil }
                    value = entry.value
                }
                // re-prime memory
                if self.mode == .memoryAndDisk {
                    let entry = Entry(value: value, expiration: attrs[.modificationDate] as? Date)
                    self.memoryCache.setObject(entry, forKey: wrappedKey)
                }
                return value
            } catch {
                return nil
            }
        }
    }
    
    public func remove(for key: Key) {
        let wrappedKey = WrappedKey(key)
        queue.async(flags: .barrier) {
            if self.mode == .memoryOnly || self.mode == .memoryAndDisk {
                self.memoryCache.removeObject(forKey: wrappedKey)
            }
            if self.mode == .diskOnly || self.mode == .memoryAndDisk {
                try? self.fileManager.removeItem(at: self.fileURL(for: key))
            }
        }
    }
    
    /// Clear whole cache (thread-safe)
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
    
    /// Clear only in-memory (thread-safe)
    public func clearMemory() {
        queue.async(flags: .barrier) {
            self.memoryCache.removeAllObjects()
        }
    }
    
    // MARK: - Private I/O
    private func saveToDisk(_ entry: Entry, for key: Key) {
        let url = fileURL(for: key)
        do {
            let raw: Data
            if Value.self == Data.self, let d = entry.value as? Data {
                raw = d
            } else {
                raw = try JSONEncoder().encode(entry)
            }
            try raw.write(to: url, options: .atomic)
            if let exp = entry.expiration {
                try fileManager.setAttributes([.modificationDate: exp], ofItemAtPath: url.path)
            }
        } catch {
          ATLog(.error, "Failed to save cache item to disk")
        }
    }
    
    /// Sanitize and hash key for filename safety
    public func fileURL(for key: Key) -> URL {
        let name: String
        if let str = key as? String {
            name = str.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "", options: .regularExpression)
        } else {
            let data = try? JSONEncoder().encode(key)
            let hash = data.map { SHA256.hash(data: $0).compactMap { String(format: "%02x", $0) }.joined() } ?? String(describing: key)
            name = hash
        }
        return cacheDirectory.appendingPathComponent(name)
    }
}
