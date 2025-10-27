//
//  TPPBookRegistryAsync.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import UIKit

/// Modern async/await extensions for TPPBookRegistry
/// These methods provide async alternatives to callback-based operations
extension TPPBookRegistry {
  
  // MARK: - Async Load & Sync
  
  /// Asynchronously loads the registry for the given account
  /// - Parameter account: Optional account ID (uses current account if nil)
  func loadAsync(account: String? = nil) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        self.load(account: account)
        // Wait for loading to complete by monitoring state
        var attempts = 0
        while self.state == .loading && attempts < 50 {
          Thread.sleep(forTimeInterval: 0.1)
          attempts += 1
        }
        continuation.resume()
      }
    }
  }
  
  /// Asynchronously syncs the registry with the server
  /// - Returns: Tuple of (errorDocument, hasNewBooks)
  /// - Throws: PalaceError if sync fails
  func syncAsync() async throws -> (errorDocument: [AnyHashable: Any]?, hasNewBooks: Bool) {
    // Use OPDSFeedService for modern async approach
    guard let loansURL = AccountsManager.shared.currentAccount?.loansUrl else {
      throw PalaceError.authentication(.accountNotFound)
    }
    
    do {
      let feed = try await OPDSFeedService.shared.fetchFeed(
        from: loansURL,
        resetCache: true,
        useToken: true
      )
      
      // Process the feed on a background task
      return await processLoansSync(feed: feed)
      
    } catch let error as PalaceError {
      Log.error(#file, "Registry sync failed: \(error.localizedDescription)")
      throw error
    }
  }
  
  /// Processes a loans feed for sync
  private func processLoansSync(feed: TPPOPDSFeed) async -> (errorDocument: [AnyHashable: Any]?, hasNewBooks: Bool) {
    return await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        self.state = .syncing
        
        var changesMade = false
        self.syncQueue.sync {
          var recordsToDelete = Set<String>(self.registry.keys)
          
          for entry in feed.entries {
            guard let opdsEntry = entry as? TPPOPDSEntry,
                  let book = TPPBook(entry: opdsEntry) else {
              continue
            }
            
            recordsToDelete.remove(book.identifier)
            
            if self.registry[book.identifier] != nil {
              self.updateBook(book)
              changesMade = true
            } else {
              self.addBook(book)
              changesMade = true
            }
          }
          
          // Remove books no longer in loans
          recordsToDelete.forEach { identifier in
            if let recordState = self.registry[identifier]?.state,
               recordState == .downloadSuccessful || recordState == .used {
              MyBooksDownloadCenter.shared.deleteLocalContent(for: identifier)
            }
            self.registry[identifier]?.state = .unregistered
            self.removeBook(forIdentifier: identifier)
            changesMade = true
          }
          
          self.save()
        }
        
        self.state = .synced
        continuation.resume(returning: (nil, changesMade))
      }
    }
  }
  
  // MARK: - Async State Operations
  
  /// Asynchronously sets the state for a book
  /// - Parameters:
  ///   - state: The new state
  ///   - bookIdentifier: The book identifier
  func setStateAsync(_ state: TPPBookState, for bookIdentifier: String) async {
    await withCheckedContinuation { continuation in
      setState(state, for: bookIdentifier)
      // setState already dispatches to main and sends updates
      continuation.resume()
    }
  }
  
  /// Asynchronously adds a book to the registry
  /// - Parameters:
  ///   - book: The book to add
  ///   - location: Optional reading location
  ///   - state: The initial state
  ///   - fulfillmentId: Optional fulfillment ID
  ///   - readiumBookmarks: Optional Readium bookmarks
  ///   - genericBookmarks: Optional generic bookmarks
  func addBookAsync(
    _ book: TPPBook,
    location: TPPBookLocation? = nil,
    state: TPPBookState = .downloadNeeded,
    fulfillmentId: String? = nil,
    readiumBookmarks: [TPPReadiumBookmark]? = nil,
    genericBookmarks: [TPPBookLocation]? = nil
  ) async {
    await withCheckedContinuation { continuation in
      addBook(
        book,
        location: location,
        state: state,
        fulfillmentId: fulfillmentId,
        readiumBookmarks: readiumBookmarks,
        genericBookmarks: genericBookmarks
      )
      continuation.resume()
    }
  }
  
  /// Asynchronously removes a book from the registry
  /// - Parameter bookIdentifier: The book identifier to remove
  func removeBookAsync(forIdentifier bookIdentifier: String) async {
    await withCheckedContinuation { continuation in
      removeBook(forIdentifier: bookIdentifier)
      continuation.resume()
    }
  }
  
  /// Asynchronously saves the registry
  func saveAsync() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      save()
      // save() already handles async dispatch, wait a bit for it to complete
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
        continuation.resume()
      }
    }
  }
  
  // MARK: - AsyncSequence Publishers
  
  /// Returns an AsyncStream of registry updates
  /// Modern alternative to registryPublisher
  func registryUpdates() -> AsyncStream<[String: TPPBookRegistryRecord]> {
    AsyncStream { continuation in
      let cancellable = registryPublisher
        .sink { registry in
          continuation.yield(registry)
        }
      
      continuation.onTermination = { _ in
        cancellable.cancel()
      }
    }
  }
  
  /// Returns an AsyncStream of book state updates
  /// Modern alternative to bookStatePublisher
  func bookStateUpdates() -> AsyncStream<(String, TPPBookState)> {
    AsyncStream { continuation in
      let cancellable = bookStatePublisher
        .sink { update in
          continuation.yield(update)
        }
      
      continuation.onTermination = { _ in
        cancellable.cancel()
      }
    }
  }
  
  /// Returns an AsyncStream of state updates for a specific book
  /// - Parameter bookIdentifier: The book to monitor
  /// - Returns: AsyncStream of state changes for this book
  func stateUpdates(for bookIdentifier: String) -> AsyncStream<TPPBookState> {
    AsyncStream { continuation in
      let cancellable = bookStatePublisher
        .filter { $0.0 == bookIdentifier }
        .map { $0.1 }
        .sink { state in
          continuation.yield(state)
        }
      
      continuation.onTermination = { _ in
        cancellable.cancel()
      }
    }
  }
}

// MARK: - Async Iterator Helpers

extension TPPBookRegistry {
  /// Waits for a specific state for a book
  /// - Parameters:
  ///   - state: The state to wait for
  ///   - bookIdentifier: The book identifier
  ///   - timeout: Maximum time to wait (default 30 seconds)
  /// - Returns: True if state was reached, false if timeout
  func waitForState(
    _ state: TPPBookState,
    for bookIdentifier: String,
    timeout: TimeInterval = 30
  ) async -> Bool {
    let startTime = Date()
    
    for await currentState in stateUpdates(for: bookIdentifier) {
      if currentState == state {
        return true
      }
      
      if Date().timeIntervalSince(startTime) > timeout {
        return false
      }
    }
    
    return false
  }
  
  /// Observes registry updates until a condition is met
  /// - Parameters:
  ///   - condition: The condition to wait for
  ///   - timeout: Maximum time to wait
  /// - Returns: The registry when condition is met, or nil if timeout
  func waitForCondition(
    _ condition: @escaping ([String: TPPBookRegistryRecord]) -> Bool,
    timeout: TimeInterval = 30
  ) async -> [String: TPPBookRegistryRecord]? {
    let startTime = Date()
    
    for await registry in registryUpdates() {
      if condition(registry) {
        return registry
      }
      
      if Date().timeIntervalSince(startTime) > timeout {
        return nil
      }
    }
    
    return nil
  }
}

// MARK: - Batch Operations

extension TPPBookRegistry {
  /// Adds multiple books in a batch operation
  /// - Parameters:
  ///   - books: Array of tuples (book, state)
  func addBooksAsync(_ books: [(book: TPPBook, state: TPPBookState)]) async {
    for (book, state) in books {
      await addBookAsync(book, state: state)
    }
  }
  
  /// Removes multiple books in a batch operation
  /// - Parameter identifiers: Array of book identifiers to remove
  func removeBooksAsync(identifiers: [String]) async {
    for identifier in identifiers {
      await removeBookAsync(forIdentifier: identifier)
    }
  }
  
  /// Updates states for multiple books
  /// - Parameter updates: Dictionary of [bookIdentifier: newState]
  func setStatesAsync(_ updates: [String: TPPBookState]) async {
    for (identifier, state) in updates {
      await setStateAsync(state, for: identifier)
    }
  }
}

