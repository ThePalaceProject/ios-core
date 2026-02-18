//
//  TPPBookRegistryAsync.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import UIKit

/// Modern async/await extensions for TPPBookRegistry
extension TPPBookRegistry {
  
  // MARK: - Async Sync
  
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
        // State is managed internally by sync() method
        
        var changesMade = false
        
        // Process entries - use public API
        var newBooks: [TPPBook] = []
        for entry in feed.entries {
          guard let opdsEntry = entry as? TPPOPDSEntry,
                let book = TPPBook(entry: opdsEntry) else {
            continue
          }
          newBooks.append(book)
        }
        
        // Check what changed - compare with current books
        let currentBooks = self.allBooks
        let currentIds = Set(currentBooks.map { $0.identifier })
        let newIds = Set(newBooks.map { $0.identifier })
        
        // Books to add/update
        for book in newBooks {
          if currentIds.contains(book.identifier) {
            // Update existing
            let _ = self.updatedBookMetadata(book)
          } else {
            // Add new - derive initial state from book availability
            let initialState = TPPBookRegistryRecord.deriveInitialState(for: book)
            self.addBook(book, state: initialState)
          }
          changesMade = true
        }
        
        let removedIds = currentIds.subtracting(newIds)
        for identifier in removedIds {
          let state = self.state(for: identifier)
            if state == .downloadSuccessful || state == .used {
            MyBooksDownloadCenter.shared.deleteLocalContent(for: identifier)
          }
          self.setState(.unregistered, for: identifier)
          self.removeBook(forIdentifier: identifier)
          changesMade = true
        }
        
        continuation.resume(returning: (nil, changesMade))
      }
    }
  }
}

