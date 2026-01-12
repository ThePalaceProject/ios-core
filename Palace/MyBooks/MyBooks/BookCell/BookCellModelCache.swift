//
//  BookCellModelCache.swift
//  Palace
//
//  High-performance cache for BookCellModel instances to avoid recreation on every render
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import Combine

// MARK: - BookCellModel Cache

/// Thread-safe cache for BookCellModel instances
/// Prevents expensive model recreation on every SwiftUI render cycle
@MainActor
final class BookCellModelCache: ObservableObject {
  
  // MARK: - Configuration
  
  public struct Configuration {
    /// Maximum number of cached models
    let maxEntries: Int
    
    /// How long to keep unused models
    let unusedTTL: TimeInterval
    
    /// Whether to observe book registry changes
    let observeRegistryChanges: Bool
    
    public static let `default` = Configuration(
      maxEntries: 200,
      unusedTTL: 300, // 5 minutes
      observeRegistryChanges: true
    )
    
    public static let aggressive = Configuration(
      maxEntries: 500,
      unusedTTL: 600, // 10 minutes
      observeRegistryChanges: true
    )
  }
  
  // MARK: - Cache Entry
  
  private struct CacheEntry {
    let model: BookCellModel
    var lastAccessed: Date
    
    var isStale: Bool {
      Date().timeIntervalSince(lastAccessed) > 300
    }
  }
  
  // MARK: - Properties
  
  private var cache: [String: CacheEntry] = [:]
  private var accessOrder: [String] = []
  private let configuration: Configuration
  private let imageCache: ImageCacheType
  private let bookRegistry: TPPBookRegistryProvider
  private var cancellables = Set<AnyCancellable>()
  private var cleanupTask: Task<Void, Never>?
  
  // MARK: - Singleton
  
  public static let shared = BookCellModelCache()
  
  // MARK: - Initialization
  
  public init(
    configuration: Configuration = .default,
    imageCache: ImageCacheType = ImageCache.shared,
    bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared
  ) {
    self.configuration = configuration
    self.imageCache = imageCache
    self.bookRegistry = bookRegistry
    
    if configuration.observeRegistryChanges {
      setupRegistryObserver()
    }
    
    startPeriodicCleanup()
  }
  
  deinit {
    cleanupTask?.cancel()
  }
  
  // MARK: - Public API
  
  /// Gets or creates a BookCellModel for the given book
  /// Reuses cached models when possible for better performance
  public func model(for book: TPPBook) -> BookCellModel {
    let key = book.identifier
    
    // Check cache
    if var entry = cache[key] {
      // Update book data if changed
      if entry.model.book.updated != book.updated {
        entry.model.book = book
      }
      
      // Update access time
      entry.lastAccessed = Date()
      cache[key] = entry
      updateAccessOrder(key)
      
      return entry.model
    }
    
    // Create new model
    let model = BookCellModel(book: book, imageCache: imageCache, bookRegistry: bookRegistry)
    
    // Evict if at capacity
    if cache.count >= configuration.maxEntries {
      evictLRU()
    }
    
    // Cache it
    cache[key] = CacheEntry(model: model, lastAccessed: Date())
    updateAccessOrder(key)
    
    return model
  }
  
  /// Preloads models for a batch of books (useful for prefetching)
  public func preload(books: [TPPBook]) {
    for book in books {
      _ = model(for: book)
    }
  }
  
  /// Invalidates a specific model (e.g., when book data changes)
  public func invalidate(for bookIdentifier: String) {
    cache.removeValue(forKey: bookIdentifier)
    accessOrder.removeAll { $0 == bookIdentifier }
  }
  
  /// Invalidates models for multiple books
  public func invalidate(for bookIdentifiers: [String]) {
    for id in bookIdentifiers {
      invalidate(for: id)
    }
  }
  
  /// Clears all cached models
  public func clear() {
    cache.removeAll()
    accessOrder.removeAll()
  }
  
  /// Removes stale entries
  public func evictStale() {
    let staleKeys = cache.filter { $0.value.isStale }.map { $0.key }
    for key in staleKeys {
      cache.removeValue(forKey: key)
      accessOrder.removeAll { $0 == key }
    }
  }
  
  // MARK: - Stats
  
  public var count: Int { cache.count }
  public var hitRate: Double { Double(cacheHits) / Double(max(1, cacheHits + cacheMisses)) }
  
  private var cacheHits: Int = 0
  private var cacheMisses: Int = 0
  
  // MARK: - Private Helpers
  
  private func updateAccessOrder(_ key: String) {
    accessOrder.removeAll { $0 == key }
    accessOrder.append(key)
    cacheHits += 1
  }
  
  private func evictLRU() {
    // Remove oldest 10% when evicting
    let evictCount = max(1, configuration.maxEntries / 10)
    
    for _ in 0..<evictCount {
      guard let oldestKey = accessOrder.first else { break }
      cache.removeValue(forKey: oldestKey)
      accessOrder.removeFirst()
    }
  }
  
  private func setupRegistryObserver() {
    // Observe book state changes to invalidate affected models
    bookRegistry.bookStatePublisher
      .sink { [weak self] (identifier, _) in
        // Don't invalidate, just let the model update its state
        // The model already observes the registry
        self?.touchModel(identifier: identifier)
      }
      .store(in: &cancellables)
  }
  
  private func touchModel(identifier: String) {
    if var entry = cache[identifier] {
      entry.lastAccessed = Date()
      cache[identifier] = entry
    }
  }
  
  private func startPeriodicCleanup() {
    cleanupTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute
        await MainActor.run {
          self?.evictStale()
        }
      }
    }
  }
}

// MARK: - Prefetching Support

extension BookCellModelCache {
  
  /// Prefetches models for visible range plus buffer
  /// - Parameters:
  ///   - books: All books in the list
  ///   - visibleRange: Currently visible indices
  ///   - buffer: Number of items to prefetch beyond visible range
  public func prefetch(
    books: [TPPBook],
    visibleRange: Range<Int>,
    buffer: Int = 10
  ) {
    let startIndex = max(0, visibleRange.lowerBound - buffer)
    let endIndex = min(books.count, visibleRange.upperBound + buffer)
    
    let prefetchRange = startIndex..<endIndex
    let booksToPreload = Array(books[prefetchRange])
    
    // Preload models in background-ish priority
    Task { @MainActor in
      for book in booksToPreload {
        _ = model(for: book)
      }
    }
  }
  
  /// Cancels prefetching for items that scrolled out of view
  public func cancelPrefetch(for bookIdentifiers: [String]) {
    // We don't actually cancel, but we can deprioritize
    // The LRU eviction will handle cleanup
  }
}

// MARK: - Memory Warning Handler

extension BookCellModelCache {
  
  /// Call this when receiving memory warning
  public func handleMemoryWarning() {
    // Keep only the most recently accessed 25%
    let keepCount = configuration.maxEntries / 4
    
    while cache.count > keepCount {
      evictLRU()
    }
    
    Log.info(#file, "BookCellModelCache: Reduced to \(cache.count) entries after memory warning")
  }
}
