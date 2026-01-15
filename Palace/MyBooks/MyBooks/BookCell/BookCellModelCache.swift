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
      maxEntries: 50,  // Reduced from 200 - each model holds a UIImage
      unusedTTL: 120,  // 2 minutes - be more aggressive about cleanup
      observeRegistryChanges: true
    )
    
    public static let aggressive = Configuration(
      maxEntries: 100, // Reduced from 500
      unusedTTL: 300,  // 5 minutes
      observeRegistryChanges: true
    )
  }
  
  // MARK: - Cache Entry
  
  private struct CacheEntry {
    let model: BookCellModel
    var lastAccessed: Date
    let ttl: TimeInterval
    
    var isStale: Bool {
      Date().timeIntervalSince(lastAccessed) > ttl
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
  
  private var memoryWarningObserver: NSObjectProtocol?
  private var accountChangeObserver: NSObjectProtocol?
  
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
    
    setupMemoryWarningObserver()
    setupAccountChangeObserver()
    startPeriodicCleanup()
  }
  
  deinit {
    cleanupTask?.cancel()
    if let observer = memoryWarningObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = accountChangeObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }
  
  private func setupMemoryWarningObserver() {
    memoryWarningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.handleMemoryWarning()
    }
  }
  
  private func setupAccountChangeObserver() {
    accountChangeObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.TPPCurrentAccountDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.handleAccountChange()
    }
  }
  
  private func handleAccountChange() {
    // Clear all cached models when switching libraries
    // The new library has different books, so old models are useless
    let previousCount = cache.count
    cache.removeAll()
    accessOrder.removeAll()
    Log.info(#file, "BookCellModelCache: Cleared \(previousCount) entries after account change")
  }
  
  // MARK: - Public API
  
  /// Gets or creates a BookCellModel for the given book
  /// Reuses cached models when possible for better performance
  public func model(for book: TPPBook) -> BookCellModel {
    let key = book.identifier
    
    if var entry = cache[key] {
      entry.lastAccessed = Date()
      cache[key] = entry
      updateAccessOrder(key)
      
      return entry.model
    }
    
    // Create new model
    return createAndCacheModel(for: book)
  }
  
  private func createAndCacheModel(for book: TPPBook) -> BookCellModel {
    let model = BookCellModel(book: book, imageCache: imageCache, bookRegistry: bookRegistry)
    
    // Evict if at capacity
    if cache.count >= configuration.maxEntries {
      evictLRU()
    }
    
    // Cache it
    cache[book.identifier] = CacheEntry(model: model, lastAccessed: Date(), ttl: configuration.unusedTTL)
    updateAccessOrder(book.identifier)
    
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
    // Observe book state changes and invalidate models when registry state doesn't match model state.
    // This ensures UI always reflects the true state from the registry.
    bookRegistry.bookStatePublisher
      .sink { [weak self] (identifier, newState) in
        guard let self, let entry = self.cache[identifier] else { return }
        
        let modelRegistryState = entry.model.registryState
        
        // Invalidate if model's registry state doesn't match the actual registry state
        // This catches ALL state mismatches, not just downloading → finished transitions
        if modelRegistryState != newState {
          Log.debug(#file, "Cache invalidating '\(identifier)': model state=\(modelRegistryState.stringValue()) registry state=\(newState.stringValue())")
          self.invalidate(for: identifier)
        }
      }
      .store(in: &cancellables)
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
  
  /// Called automatically when receiving memory warning notification
  public func handleMemoryWarning() {
    let previousCount = cache.count
    
    // Be aggressive - clear ALL cached models on memory warning
    // They will be recreated on demand when scrolling
    cache.removeAll()
    accessOrder.removeAll()
    
    Log.info(#file, "BookCellModelCache: Cleared \(previousCount) entries after memory warning")
  }
}
