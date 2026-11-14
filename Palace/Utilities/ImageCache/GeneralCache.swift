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

// `@unchecked Sendable`: every read of the cache files, every rename or link
// that publishes a written file, `pendingWrites`, and every memory-cache access
// that has to stay consistent with them happen under `lock`. Only the byte
// write of a new entry runs outside it, into a staging file no reader can
// name. The memory-only clears skip the lock because `CountedCache` is itself
// thread-safe and dropping a memory entry can never make a read wrong (the
// value is still on disk, or in `.memoryOnly` mode it is simply gone).
// `Key`/`Value` are constrained to `Sendable` so cached values can cross
// threads safely (all call sites use `GeneralCache<String, Data>`).
public final class GeneralCache<Key: Hashable & Codable & Sendable, Value: Codable & Sendable>: @unchecked Sendable {
    private let memoryCache: CountedCache<Key, Entry>
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
    /// other. Writes put their bytes in a staging file on the caller's thread
    /// without the lock, then take it only to rename the file into place.
    private let lock = NSLock()

    /// The write each key is waiting for, by generation. A write publishes its
    /// staged file under a key only while it is still that key's latest write,
    /// so a `remove`, `clear` or newer `set` that lands during the byte write
    /// wins. Guarded by `lock`.
    private var pendingWrites: [Key: UInt64] = [:]
    private var lastWriteGeneration: UInt64 = 0

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

    /// Writes the encoded bytes of one entry. Injected only by tests, to hold
    /// a write open while other calls run.
    private let writeData: @Sendable (Data, URL) throws -> Void

    public convenience init(cacheName: String = "GeneralCache", mode: CachingMode = .memoryAndDisk) {
        self.init(cacheName: cacheName, mode: mode, writeData: { try $0.write(to: $1) })
    }

    /// `byteCounter` receives the memory layer's bytes (PP-5509).
    convenience init(cacheName: String, mode: CachingMode, byteCounter: CacheByteCounter) {
        self.init(cacheName: cacheName, mode: mode, writeData: { try $0.write(to: $1) }, byteCounter: byteCounter)
    }

    init(
        cacheName: String,
        mode: CachingMode,
        writeData: @escaping @Sendable (Data, URL) throws -> Void,
        byteCounter: CacheByteCounter = CacheByteCounter(),
        memoryRelease: MemoryReleaseCoordinator = .shared
    ) {
        memoryCache = CountedCache(counter: byteCounter)
        self.mode = mode
        self.writeData = writeData
        guard let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(cacheName, isDirectory: true)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            configureCacheLimits()
            registerMemoryRelease(on: memoryRelease)
            return
        }
        cacheDirectory = cachesDir.appendingPathComponent(cacheName, isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        configureCacheLimits()
        registerMemoryRelease(on: memoryRelease)
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

    private func registerMemoryRelease(on memoryRelease: MemoryReleaseCoordinator) {
        memoryRelease.register(self, stage: .cachedData) { cache in
            cache.handleMemoryWarning()
        }
    }

    private func handleMemoryWarning() {
        // Runs on the thread that posted the warning (main, from UIKit);
        // deliberately does not take `lock`, which a reader may be holding
        // across disk I/O. See the type comment.
        memoryCache.removeAllObjects()
    }

    public func set(_ value: Value, for key: Key, expiresIn interval: TimeInterval? = nil) {
        set(value, for: [key], expiresIn: interval)
    }

    /// Stores one value under several keys. On disk the value is written once;
    /// the other keys are hard links to that file, so each key still reads and
    /// removes as its own file.
    func set(_ value: Value, for keys: [Key], expiresIn interval: TimeInterval? = nil) {
        guard !keys.isEmpty else { return }
        let expirationDate = interval.map { Date().addingTimeInterval($0) }
        let entry = Entry(value: value, expiration: expirationDate)
        let writesToDisk = mode == .diskOnly || mode == .memoryAndDisk
        let generation: UInt64 = lock.withLock {
            if mode == .memoryOnly || mode == .memoryAndDisk {
                let cost = estimatedCost(for: value)
                for key in keys {
                    memoryCache.setObject(entry, forKey: key, cost: cost)
                }
            }
            guard writesToDisk else { return 0 }
            lastWriteGeneration &+= 1
            for key in keys {
                pendingWrites[key] = lastWriteGeneration
            }
            return lastWriteGeneration
        }
        guard writesToDisk else { return }

        let staged = stageOnDisk(entry)
        lock.withLock {
            publish(staged, for: keys, generation: generation)
        }
    }

    /// Whether `key` has a file on disk that has not expired, or a write for it
    /// in progress. Reads no file contents.
    func hasUnexpiredDiskEntry(for key: Key) -> Bool {
        guard mode == .diskOnly || mode == .memoryAndDisk else { return false }
        return lock.withLock {
            if pendingWrites[key] != nil { return true }
            guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL(for: key).path) else {
                return false
            }
            if let exp = attrs[.modificationDate] as? Date, exp < Date() { return false }
            return true
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
            if mode == .memoryOnly || mode == .memoryAndDisk,
               let entry = memoryCache.object(forKey: key), !entry.isExpired {
                return entry.value
            }
            if mode == .memoryOnly { return nil }
            let url = fileURL(for: key)
            do {
                let attrs = try fileManager.attributesOfItem(atPath: url.path)
                if let exp = attrs[.modificationDate] as? Date, exp < Date() {
                    removeStoredWhileLocked(key)
                    return nil
                }
                let raw = try Data(contentsOf: url, options: .mappedIfSafe)
                let value: Value
                if Value.self == Data.self, let d = raw as? Value {
                    value = d
                } else {
                    let diskEntry = try JSONDecoder().decode(Entry.self, from: raw)
                    guard !diskEntry.isExpired else {
                        removeStoredWhileLocked(key)
                        return nil
                    }
                    value = diskEntry.value
                }
                if mode == .memoryAndDisk {
                    let exp = attrs[.modificationDate] as? Date
                    let reentry = Entry(value: value, expiration: exp)
                    let cost = estimatedCost(for: value)
                    memoryCache.setObject(reentry, forKey: key, cost: cost)
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
        pendingWrites[key] = nil
        removeStoredWhileLocked(key)
    }

    /// Drops the memory entry and file for `key` but leaves a write in progress
    /// alone, for `get` discarding an expired file. Caller holds `lock`.
    private func removeStoredWhileLocked(_ key: Key) {
        if mode == .memoryOnly || mode == .memoryAndDisk {
            memoryCache.removeObject(forKey: key)
        }
        if mode == .diskOnly || mode == .memoryAndDisk {
            try? fileManager.removeItem(at: fileURL(for: key))
        }
    }

    public func clear() {
        lock.withLock {
            pendingWrites.removeAll()
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

    /// Deletes the oldest stored files, by creation date, until the disk layer
    /// holds at most `maxBytes`. Folders and staging files are left alone.
    func prune(maxBytes: Int) {
        guard mode == .diskOnly || mode == .memoryAndDisk else { return }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
        lock.withLock {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { return }
            var files = urls.compactMap { url -> (url: URL, size: Int, created: Date)? in
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                return (url, values.fileSize ?? 0, values.creationDate ?? .distantPast)
            }
            var total = files.reduce(0) { $0 + $1.size }
            guard total > maxBytes else { return }
            files.sort { $0.created < $1.created }
            for file in files where total > maxBytes {
                try? fileManager.removeItem(at: file.url)
                total -= file.size
            }
        }
    }

    /// Bytes the memory layer holds now (PP-5509).
    var memoryBytes: Int { memoryCache.byteCount }

    public func clearMemory() {
        // No `lock`: see `handleMemoryWarning` and the type comment.
        memoryCache.removeAllObjects()
    }

    /// Writes the entry's bytes to a new staging file and returns its URL, or
    /// nil if the write failed. Called without `lock`. Staging names start with
    /// a dot, which `fileURL(for:)` never produces, so no reader can see a
    /// partial file.
    private func stageOnDisk(_ entry: Entry) -> URL? {
        let url = cacheDirectory.appendingPathComponent(".staged-\(UUID().uuidString)")
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
            try writeData(raw, url)
            if let exp = entry.expiration {
                try fileManager.setAttributes([.modificationDate: exp], ofItemAtPath: url.path)
            }
            return url
        } catch {
            print("Cache disk write failed: \(error)")
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    /// Moves a staged file into place under every key whose latest write is
    /// still `generation`. The first such key takes the file by rename; the
    /// others become hard links to it. Caller holds `lock`.
    private func publish(_ staged: URL?, for keys: [Key], generation: UInt64) {
        var published: URL?
        for key in keys where pendingWrites[key] == generation {
            pendingWrites[key] = nil
            guard let staged else { continue }
            let url = fileURL(for: key)
            if let published {
                try? fileManager.removeItem(at: url)
                if (try? fileManager.linkItem(at: published, to: url)) == nil {
                    try? fileManager.copyItem(at: published, to: url)
                }
            } else if Darwin.rename(staged.path, url.path) == 0 {
                published = url
            } else {
                print("Cache disk write failed: rename errno \(errno)")
            }
        }
        if published == nil, let staged {
            try? fileManager.removeItem(at: staged)
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
