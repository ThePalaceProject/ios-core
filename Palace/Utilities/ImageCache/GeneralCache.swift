import Foundation
import UIKit
import CryptoKit
import PalaceLogging

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

// `@unchecked Sendable`: every read and write of the cache files, and every
// memory-cache access that has to stay consistent with them, happens under
// `lock`. The memory-only clears skip the lock because `NSCache` is itself
// thread-safe and dropping a memory entry can never make a read wrong (the
// value is still on disk, or in `.memoryOnly` mode it is simply gone).
// `memoryWarningObserver` is set once during `init` and only read in `deinit`.
// `Key`/`Value` are constrained to `Sendable` so cached values can cross
// threads safely (all call sites use `GeneralCache<String, Data>`).
public final class GeneralCache<Key: Hashable & Codable & Sendable, Value: Codable & Sendable>: @unchecked Sendable {
    private let memoryCache = NSCache<WrappedKey, Entry>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let mode: CachingMode

    /// Serializes cache reads and writes on the calling thread.
    ///
    /// This is a lock rather than a dispatch queue on purpose. Covers are read
    /// from Swift-concurrency tasks, whose threads come from a pool only as
    /// wide as the CPU count. The previous design read with `queue.sync` and
    /// wrote with `queue.async(flags: .barrier)` from `ImageCache`'s `.utility`
    /// processing queue. Once a barrier was queued every new reader waited
    /// behind it, and the barrier needed a fresh low-priority worker thread to
    /// run — which the system will not start while all the higher-priority
    /// pool threads count as busy, and they were busy waiting on this queue. On
    /// a full catalog screen that deadlocked the entire pool permanently, so
    /// every async job in the app stopped, feed loads included (PP-5134).
    ///
    /// A lock cannot do that: the thread releasing it wakes the next waiter
    /// directly, so no operation here ever needs a thread that is not already
    /// running. The cost is that readers no longer run concurrently with each
    /// other, and writes do their disk I/O on the caller's thread instead of in
    /// the background.
    private let lock = NSLock()
    private var memoryWarningObserver: NSObjectProtocol?

    private final class Entry: Codable, Sendable {
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

    // `@unchecked Sendable`: immutable `let key` (which is itself `Sendable`);
    // used only as an `NSCache` key.
    private final class WrappedKey: NSObject, @unchecked Sendable {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? WrappedKey else { return false }
            return other.key == key
        }
    }

    public init(cacheName: String = "GeneralCache", mode: CachingMode = .memoryAndDisk) {
        self.mode = mode
        guard let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(cacheName, isDirectory: true)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            configureCacheLimits()
            setupMemoryWarningHandler()
            return
        }
        cacheDirectory = cachesDir.appendingPathComponent(cacheName, isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        configureCacheLimits()
        setupMemoryWarningHandler()
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func configureCacheLimits() {
        let deviceMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        let cacheMemoryMB: Int
        let itemCountLimit: Int

        // Reduced limits GeneralCache backs ImageCache's compressed JPEG
        // store. Combined with the decoded UIImage NSCache layer, old limits allowed
        // too much data to accumulate (50 MB ImageIO in footprint).
        if deviceMemoryMB < 2048 {
            cacheMemoryMB = 20
            itemCountLimit = 100
        } else if deviceMemoryMB < 4096 {
            cacheMemoryMB = 40
            itemCountLimit = 150
        } else {
            cacheMemoryMB = 60
            itemCountLimit = 200
        }

        memoryCache.totalCostLimit = cacheMemoryMB * 1024 * 1024
        memoryCache.countLimit = itemCountLimit
    }

    private func setupMemoryWarningHandler() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }

    private func handleMemoryWarning() {
        // Runs on the main thread; deliberately does not take `lock`, which a
        // reader may be holding across disk I/O. See the type comment.
        memoryCache.removeAllObjects()
    }

    public func set(_ value: Value, for key: Key, expiresIn interval: TimeInterval? = nil) {
        let expirationDate = interval.map { Date().addingTimeInterval($0) }
        let entry = Entry(value: value, expiration: expirationDate)
        let wrappedKey = WrappedKey(key)
        lock.withLock {
            if mode == .memoryOnly || mode == .memoryAndDisk {
                let cost = estimatedCost(for: value)
                memoryCache.setObject(entry, forKey: wrappedKey, cost: cost)
            }
            if mode == .diskOnly || mode == .memoryAndDisk {
                saveToDisk(entry, for: key)
            }
        }
    }

    private func estimatedCost(for value: Value) -> Int {
        if Value.self == Data.self, let data = value as? Data {
            return data.count
        }
        return 4096
    }

    public func get(for key: Key) -> Value? {
        return lock.withLock {
            let wrappedKey = WrappedKey(key)
            if mode == .memoryOnly || mode == .memoryAndDisk,
               let entry = memoryCache.object(forKey: wrappedKey), !entry.isExpired {
                return entry.value
            }
            if mode == .memoryOnly { return nil }
            let url = fileURL(for: key)
            do {
                let attrs = try fileManager.attributesOfItem(atPath: url.path)
                if let exp = attrs[.modificationDate] as? Date, exp < Date() {
                    removeWhileLocked(key)
                    return nil
                }
                let raw = try Data(contentsOf: url, options: .mappedIfSafe)
                let value: Value
                if Value.self == Data.self, let d = raw as? Value {
                    value = d
                } else {
                    let diskEntry = try JSONDecoder().decode(Entry.self, from: raw)
                    guard !diskEntry.isExpired else {
                        removeWhileLocked(key)
                        return nil
                    }
                    value = diskEntry.value
                }
                if mode == .memoryAndDisk {
                    let exp = attrs[.modificationDate] as? Date
                    let reentry = Entry(value: value, expiration: exp)
                    let cost = estimatedCost(for: value)
                    memoryCache.setObject(reentry, forKey: wrappedKey, cost: cost)
                }
                return value
            } catch {
                if (error as NSError).code != 260 {
                    print("[GeneralCache] Cache error for key \(key): \(error)")
                }
                return nil
            }
        }
    }

    @discardableResult
    public func get(_ key: Key,
                    policy: CachePolicy,
                    fetcher: @escaping @Sendable () async throws -> Value) async throws -> Value {
        switch policy {
        case .cacheFirst:
            if let cached = get(for: key) { return cached }
            fallthrough
        case .networkFirst:
            do {
                let fresh = try await fetcher()
                set(fresh, for: key)
                return fresh
            } catch {
                if let cached = get(for: key) { return cached }
                throw error
            }
        case .cacheThenNetwork:
            if let cached = get(for: key) {
                Task.detached {
                    if let fresh = try? await fetcher() {
                        self.set(fresh, for: key)
                    }
                }
                return cached
            } else {
                let fresh = try await fetcher()
                set(fresh, for: key)
                return fresh
            }
        case .timedCache(let interval):
            if let cached = get(for: key) {
                return cached
            }
            let fresh = try await fetcher()
            set(fresh, for: key, expiresIn: interval)
            return fresh
        case .noCache:
            return try await fetcher()
        }
    }

    public func remove(for key: Key) {
        lock.withLock { removeWhileLocked(key) }
    }

    /// The body of `remove(for:)`, for callers that already hold `lock`
    /// (`NSLock` is not reentrant).
    private func removeWhileLocked(_ key: Key) {
        if mode == .memoryOnly || mode == .memoryAndDisk {
            memoryCache.removeObject(forKey: WrappedKey(key))
        }
        if mode == .diskOnly || mode == .memoryAndDisk {
            try? fileManager.removeItem(at: fileURL(for: key))
        }
    }

    public func clear() {
        lock.withLock {
            if mode == .memoryOnly || mode == .memoryAndDisk {
                memoryCache.removeAllObjects()
            }
            if mode == .diskOnly || mode == .memoryAndDisk {
                (try? fileManager.contentsOfDirectory(at: cacheDirectory,
                                                      includingPropertiesForKeys: nil))?
                    .forEach { try? fileManager.removeItem(at: $0) }
            }
        }
    }

    public func clearMemory() {
        // No `lock`: see `handleMemoryWarning` and the type comment.
        memoryCache.removeAllObjects()
    }

    private func saveToDisk(_ entry: Entry, for key: Key) {
        let url = fileURL(for: key)
        do {
            if !fileManager.fileExists(atPath: cacheDirectory.path) {
                try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            }
            let raw: Data
            if Value.self == Data.self, let d = entry.value as? Data {
                raw = d
            } else {
                raw = try JSONEncoder().encode(entry)
            }
            try raw.write(to: url, options: .atomic)
            if let exp = entry.expiration {
                try fileManager.setAttributes([.modificationDate: exp],
                                              ofItemAtPath: url.path)
            }
        } catch {
            print("Cache disk write failed: \(error)")
        }
    }

    public func fileURL(for key: Key) -> URL {
        let name: String
        if let str = key as? String {
            let sanitized = str.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "",
                                                     options: .regularExpression)
            name = sanitized.isEmpty ? "empty_\(abs(str.hashValue))" : sanitized
        } else {
            let data = try? JSONEncoder().encode(key)
            let hash = data.map { SHA256.hash(data: $0).compactMap {
                String(format: "%02x", $0)
            }.joined() } ?? String(describing: key)
            name = hash.isEmpty ? "hash_\(abs(key.hashValue))" : hash
        }

        guard !name.isEmpty else {
            Log.error(#file, "GeneralCache: Empty cache filename for key, using fallback")
            return cacheDirectory.appendingPathComponent("fallback_\(abs(key.hashValue))")
        }

        return cacheDirectory.appendingPathComponent(name)
    }

    public static func clearAllCaches() {
        let fileManager = FileManager.default
        guard let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let bundleID = Bundle.main.bundleIdentifier?.lowercased()
        do {
            let contents = try fileManager.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: nil)
            for url in contents {
                // Preserve Adobe DRM directories and critical system data
                let filename = url.lastPathComponent.lowercased()
                let fullPath = url.path.lowercased()
                let shouldPreserve = filename.contains("adobe") ||
                    filename.contains("adept") ||
                    filename.contains("drm") ||
                    filename.contains("activation") ||
                    filename.contains("device") ||
                    filename.hasPrefix("com.adobe") ||
                    filename.hasPrefix("acsm") ||
                    filename.contains("rights") ||
                    filename.contains("license") ||
                    (bundleID != nil && filename == bundleID) ||
                    fullPath.contains("adobe") ||
                    fullPath.contains("adept") ||
                    fullPath.contains("/drm/") ||
                    fullPath.contains("deviceprovider") ||
                    fullPath.contains("authorization")

                if shouldPreserve {
                    NSLog("[GeneralCache] Preserving Adobe DRM directory: \(filename)")
                    continue
                }

                try? fileManager.removeItem(at: url)
            }
        } catch {
            NSLog("[GeneralCache] Failed to clear caches: \(error)")
        }
    }

    /// Key under which the last-purged app version+build is stored. Computed
    /// (not stored) because Swift forbids stored static properties on a generic
    /// type.
    static var cacheVersionKey: String { "AppCacheVersionBuild" }

    // PUBLIC_INTENT: pre-existing public API (unchanged visibility) — called from
    // TPPAppDelegate at launch. Flagged only because the adjacent `cacheVersionKey`
    // static extraction shifted this line in the diff; not a new public surface.
    public static func clearCacheOnUpdate() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build   = info?["CFBundleVersion"] as? String ?? "0"

        let versionBuild = "\(version) (\(build))"

        // The version compare + flag write stay SYNCHRONOUS on the launch path
        // (called from `TPPAppDelegate.applicationDidFinishLaunching`). The
        // actual Caches-dir enumeration/delete is dispatched off-main — nothing
        // on the launch path waits for the purge to finish.
        clearCacheOnUpdate(
            defaults: .standard,
            currentVersionBuild: versionBuild
        ) {
            DispatchQueue.global(qos: .utility).async {
                Self.clearAllCaches()
            }
        }
    }

    /// Testable seam for `clearCacheOnUpdate()`. Keeps the version gate and the
    /// flag write synchronous; invokes `purge` (which production dispatches
    /// off-main) exactly once, and only when the stored version differs from
    /// `currentVersionBuild`. Returns `true` when a purge was triggered.
    @discardableResult
    static func clearCacheOnUpdate(
        defaults: UserDefaults,
        currentVersionBuild: String,
        purge: () -> Void
    ) -> Bool {
        let previous = defaults.string(forKey: cacheVersionKey)
        guard previous != currentVersionBuild else { return false }

        purge()
        defaults.set(currentVersionBuild, forKey: cacheVersionKey)
        return true
    }
}
