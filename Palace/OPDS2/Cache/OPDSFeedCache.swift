//
//  OPDSFeedCache.swift
//  Palace
//
//  High-performance feed caching with stale-while-revalidate pattern
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - Cache Entry

/// Represents a cached feed with metadata for freshness checking
struct OPDSCacheEntry<T: Codable & Sendable>: Codable, Sendable {
  public let feed: T
  public let timestamp: Date
  public let etag: String?
  public let lastModified: String?
  
  public init(feed: T, timestamp: Date = Date(), etag: String? = nil, lastModified: String? = nil) {
    self.feed = feed
    self.timestamp = timestamp
    self.etag = etag
    self.lastModified = lastModified
  }
  
  /// Check if cache entry is stale (older than TTL but not expired)
  public func isStale(ttl: TimeInterval) -> Bool {
    Date().timeIntervalSince(timestamp) > ttl
  }
  
  /// Check if cache entry is expired (should not be used at all)
  public func isExpired(maxAge: TimeInterval) -> Bool {
    Date().timeIntervalSince(timestamp) > maxAge
  }
}

// MARK: - Feed Cache Protocol

protocol OPDSFeedCaching: Actor {
  associatedtype FeedType: Codable & Sendable
  
  func get(for url: URL) async -> OPDSCacheEntry<FeedType>?
  func set(_ entry: OPDSCacheEntry<FeedType>, for url: URL) async
  func remove(for url: URL) async
  func clear() async
}

// MARK: - OPDS2 Feed Cache

/// Thread-safe actor-based cache for OPDS2 feeds with stale-while-revalidate
actor OPDS2FeedCache: OPDSFeedCaching {
  public typealias FeedType = OPDS2Feed
  
  // MARK: - Configuration
  
  public struct Configuration: Sendable {
    /// Time after which cached data is considered stale (returns cached + refreshes in background)
    public let staleTTL: TimeInterval
    
    /// Time after which cached data is expired (must fetch fresh)
    public let maxAge: TimeInterval
    
    /// Maximum number of entries in memory cache
    public let maxMemoryEntries: Int
    
    /// Whether to persist to disk
    public let persistToDisk: Bool
    
    public static let `default` = Configuration(
      staleTTL: 300,        // 5 minutes
      maxAge: 3600,         // 1 hour
      maxMemoryEntries: 50,
      persistToDisk: true
    )
    
    public static let aggressive = Configuration(
      staleTTL: 60,         // 1 minute
      maxAge: 600,          // 10 minutes
      maxMemoryEntries: 100,
      persistToDisk: true
    )
    
    public init(staleTTL: TimeInterval, maxAge: TimeInterval, maxMemoryEntries: Int, persistToDisk: Bool) {
      self.staleTTL = staleTTL
      self.maxAge = maxAge
      self.maxMemoryEntries = maxMemoryEntries
      self.persistToDisk = persistToDisk
    }
  }
  
  // MARK: - Properties
  
  private var memoryCache: [String: OPDSCacheEntry<OPDS2Feed>] = [:]
  private var accessOrder: [String] = []
  private let configuration: Configuration
  private let diskCache: GeneralCache<String, Data>?
  
  public static let shared = OPDS2FeedCache()
  
  // MARK: - Initialization
  
  public init(configuration: Configuration = .default) {
    self.configuration = configuration
    
    if configuration.persistToDisk {
      self.diskCache = GeneralCache<String, Data>(cacheName: "OPDS2Feeds", mode: .memoryAndDisk)
    } else {
      self.diskCache = nil
    }
  }
  
  // MARK: - Cache Operations
  
  public func get(for url: URL) async -> OPDSCacheEntry<OPDS2Feed>? {
    let key = cacheKey(for: url)
    
    // Try memory cache first
    if let entry = memoryCache[key] {
      // Update access order for LRU
      updateAccessOrder(key)
      
      // Check if expired
      if entry.isExpired(maxAge: configuration.maxAge) {
        memoryCache.removeValue(forKey: key)
        return nil
      }
      
      return entry
    }
    
    // Try disk cache
    if let diskCache = diskCache,
       let data = diskCache.get(for: key),
       let entry = try? JSONDecoder().decode(OPDSCacheEntry<OPDS2Feed>.self, from: data) {
      
      // Check if expired
      if entry.isExpired(maxAge: configuration.maxAge) {
        diskCache.remove(for: key)
        return nil
      }
      
      // Promote to memory cache
      memoryCache[key] = entry
      updateAccessOrder(key)
      
      return entry
    }
    
    return nil
  }
  
  public func set(_ entry: OPDSCacheEntry<OPDS2Feed>, for url: URL) async {
    let key = cacheKey(for: url)
    
    // Evict if at capacity
    if memoryCache.count >= configuration.maxMemoryEntries {
      evictLRU()
    }
    
    // Store in memory
    memoryCache[key] = entry
    updateAccessOrder(key)
    
    // Persist to disk
    if let diskCache = diskCache,
       let data = try? JSONEncoder().encode(entry) {
      diskCache.set(data, for: key, expiresIn: configuration.maxAge)
    }
  }
  
  public func remove(for url: URL) async {
    let key = cacheKey(for: url)
    memoryCache.removeValue(forKey: key)
    accessOrder.removeAll { $0 == key }
    diskCache?.remove(for: key)
  }
  
  public func clear() async {
    memoryCache.removeAll()
    accessOrder.removeAll()
    diskCache?.clear()
  }
  
  // MARK: - Stale-While-Revalidate
  
  /// Gets cached feed, returns stale data immediately while refreshing in background
  /// - Parameters:
  ///   - url: The feed URL
  ///   - fetcher: Async function to fetch fresh data
  /// - Returns: The feed (possibly stale) and whether a background refresh was triggered
  public func getWithRevalidation(
    for url: URL,
    fetcher: @escaping () async throws -> (OPDS2Feed, etag: String?, lastModified: String?)
  ) async throws -> (feed: OPDS2Feed, isStale: Bool, didTriggerRefresh: Bool) {
    
    if let entry = await get(for: url) {
      let isStale = entry.isStale(ttl: configuration.staleTTL)
      
      if isStale {
        // Return stale data, refresh in background
        Task.detached { [weak self] in
          do {
            let (freshFeed, etag, lastModified) = try await fetcher()
            let newEntry = OPDSCacheEntry(
              feed: freshFeed,
              etag: etag,
              lastModified: lastModified
            )
            await self?.set(newEntry, for: url)
            Log.debug(#file, "Background refresh completed for \(url.absoluteString)")
          } catch {
            Log.warn(#file, "Background refresh failed for \(url.absoluteString): \(error)")
          }
        }
        return (entry.feed, isStale: true, didTriggerRefresh: true)
      } else {
        // Fresh data, no refresh needed
        return (entry.feed, isStale: false, didTriggerRefresh: false)
      }
    }
    
    // No cache, must fetch
    let (freshFeed, etag, lastModified) = try await fetcher()
    let newEntry = OPDSCacheEntry(
      feed: freshFeed,
      etag: etag,
      lastModified: lastModified
    )
    await set(newEntry, for: url)
    
    return (freshFeed, isStale: false, didTriggerRefresh: false)
  }
  
  // MARK: - Conditional Fetch Support
  
  /// Get headers for conditional fetch (If-None-Match, If-Modified-Since)
  public func conditionalHeaders(for url: URL) async -> [String: String] {
    guard let entry = await get(for: url) else { return [:] }
    
    var headers: [String: String] = [:]
    
    if let etag = entry.etag {
      headers["If-None-Match"] = etag
    }
    
    if let lastModified = entry.lastModified {
      headers["If-Modified-Since"] = lastModified
    }
    
    return headers
  }
  
  // MARK: - Cache Stats
  
  public func stats() async -> (memoryCount: Int, diskEnabled: Bool) {
    return (memoryCache.count, diskCache != nil)
  }
  
  // MARK: - Private Helpers
  
  private func cacheKey(for url: URL) -> String {
    url.absoluteString
  }
  
  private func updateAccessOrder(_ key: String) {
    accessOrder.removeAll { $0 == key }
    accessOrder.append(key)
  }
  
  private func evictLRU() {
    guard let oldestKey = accessOrder.first else { return }
    memoryCache.removeValue(forKey: oldestKey)
    accessOrder.removeFirst()
  }
}

// MARK: - Legacy OPDS1 Feed Cache

/// Cache for legacy OPDS1 feeds (TPPOPDSFeed)
actor OPDS1FeedCache {
  
  private var memoryCache: [String: CacheEntry] = [:]
  private let staleTTL: TimeInterval = 300 // 5 minutes
  private let maxAge: TimeInterval = 3600 // 1 hour
  
  private struct CacheEntry {
    let feed: TPPOPDSFeed
    let timestamp: Date
    
    var isStale: Bool {
      Date().timeIntervalSince(timestamp) > 300
    }
    
    var isExpired: Bool {
      Date().timeIntervalSince(timestamp) > 3600
    }
  }
  
  public static let shared = OPDS1FeedCache()
  
  public func get(for url: URL) async -> TPPOPDSFeed? {
    let key = url.absoluteString
    guard let entry = memoryCache[key], !entry.isExpired else {
      memoryCache.removeValue(forKey: key)
      return nil
    }
    return entry.feed
  }
  
  public func set(_ feed: TPPOPDSFeed, for url: URL) async {
    let key = url.absoluteString
    memoryCache[key] = CacheEntry(feed: feed, timestamp: Date())
  }
  
  public func isStale(for url: URL) async -> Bool {
    let key = url.absoluteString
    return memoryCache[key]?.isStale ?? true
  }
  
  public func remove(for url: URL) async {
    memoryCache.removeValue(forKey: url.absoluteString)
  }
  
  public func clear() async {
    memoryCache.removeAll()
  }
}
