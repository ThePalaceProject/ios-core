import Foundation
import UIKit
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

public final class GeneralCache<Key: Hashable & Codable, Value: Codable> {
  private let memoryCache = NSCache<WrappedKey, Entry>()
  private let fileManager = FileManager.default
  private let cacheDirectory: URL
  private let queue = DispatchQueue(label: "com.Palace.GeneralCache", attributes: .concurrent)
  private let mode: CachingMode
  private var memoryWarningObserver: NSObjectProtocol?
  
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
  
  public init(cacheName: String = "GeneralCache", mode: CachingMode = .memoryAndDisk) {
    self.mode = mode
    let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
    
    if deviceMemoryMB < 2048 {
      cacheMemoryMB = 50
      itemCountLimit = 200
    } else if deviceMemoryMB < 4096 {
      cacheMemoryMB = 100
      itemCountLimit = 400
    } else {
      cacheMemoryMB = 150
      itemCountLimit = 600
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
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      self.memoryCache.removeAllObjects()
    }
  }
  
  public func set(_ value: Value, for key: Key, expiresIn interval: TimeInterval? = nil) {
    let expirationDate = interval.map { Date().addingTimeInterval($0) }
    let entry = Entry(value: value, expiration: expirationDate)
    let wrappedKey = WrappedKey(key)
    queue.sync(flags: .barrier) {
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
    return queue.sync {
      let wrappedKey = WrappedKey(key)
      if (mode == .memoryOnly || mode == .memoryAndDisk),
         let entry = memoryCache.object(forKey: wrappedKey), !entry.isExpired {
        return entry.value
      }
      if mode == .memoryOnly { return nil }
      let url = fileURL(for: key)
      do {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        if let exp = attrs[.modificationDate] as? Date, exp < Date() {
          remove(for: key)
          return nil
        }
        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        let value: Value
        if Value.self == Data.self, let d = raw as? Value {
          value = d
        } else {
          let diskEntry = try JSONDecoder().decode(Entry.self, from: raw)
          guard !diskEntry.isExpired else {
            remove(for: key)
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
                  fetcher: @escaping () async throws -> Value) async throws -> Value {
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
    let wrappedKey = WrappedKey(key)
    queue.sync(flags: .barrier) {
      if mode == .memoryOnly || mode == .memoryAndDisk {
        memoryCache.removeObject(forKey: wrappedKey)
      }
      if mode == .diskOnly || mode == .memoryAndDisk {
        try? fileManager.removeItem(at: fileURL(for: key))
      }
    }
  }
  
  public func clear() {
    queue.sync(flags: .barrier) {
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
    queue.sync(flags: .barrier) {
      memoryCache.removeAllObjects()
    }
  }
  
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
      name = str.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "",
                                      options: .regularExpression)
    } else {
      let data = try? JSONEncoder().encode(key)
      let hash = data.map { SHA256.hash(data: $0).compactMap {
        String(format: "%02x", $0)
      }.joined() } ?? String(describing: key)
      name = hash
    }
    return cacheDirectory.appendingPathComponent(name)
  }
  
  public static func clearAllCaches() {
    let fileManager = FileManager.default
    let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
  
  public static func clearCacheOnUpdate() {
    let cacheVersionKey = "AppCacheVersionBuild"

    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "0"
    let build   = info?["CFBundleVersion"] as? String ?? "0"

    let versionBuild = "\(version) (\(build))"

    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: cacheVersionKey)

    if previous != versionBuild {
      Self.clearAllCaches()
      defaults.set(versionBuild, forKey: cacheVersionKey)
    }
  }}
