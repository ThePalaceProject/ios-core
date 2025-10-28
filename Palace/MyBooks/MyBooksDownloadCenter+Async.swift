//
//  MyBooksDownloadCenter+Async.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Modern async/await extensions for MyBooksDownloadCenter
extension MyBooksDownloadCenter {
  
  // MARK: - Async Borrow Operations
  
  /// Borrows a book asynchronously using modern async/await pattern
  /// - Parameters:
  ///   - book: The book to borrow
  ///   - attemptDownload: Whether to immediately attempt download after borrowing
  /// - Returns: The borrowed book with updated acquisition links
  /// - Throws: PalaceError if borrow fails
  func borrowAsync(
    _ book: TPPBook,
    attemptDownload: Bool = false
  ) async throws -> TPPBook {
    // Use modern OPDSFeedService instead of legacy callback-based TPPOPDSFeed
    guard let acquisitionURL = book.defaultAcquisition?.hrefURL else {
      throw PalaceError.bookRegistry(.invalidState)
    }
    
    // Set processing state
    await MainActor.run {
      TPPBookRegistry.shared.setProcessing(true, for: book.identifier)
    }
    
    defer {
      Task { @MainActor in
        TPPBookRegistry.shared.setProcessing(false, for: book.identifier)
      }
    }
    
    do {
      // Fetch the borrowed book using modern async API with automatic retries
      let recovery = DownloadErrorRecovery()
      let borrowedBook = try await recovery.executeWithRetry(
        policy: DownloadErrorRecovery.RetryPolicy.default
      ) {
        try await OPDSFeedService.shared.fetchBook(
          from: acquisitionURL,
          resetCache: true,
          useToken: true
        )
      }
      
      // Preserve existing location
      let location = TPPBookRegistry.shared.location(forIdentifier: borrowedBook.identifier)
      
      // Determine correct registry state based on availability
      var newState: TPPBookState = .downloadNeeded
      borrowedBook.defaultAcquisition?.availability.matchUnavailable(
        { _ in newState = .holding },
        limited: { _ in newState = .downloadNeeded },
        unlimited: { _ in newState = .downloadNeeded },
        reserved: { _ in newState = .holding },
        ready: { _ in newState = .downloadNeeded }
      )
      
      // Add to registry
      TPPBookRegistry.shared.addBook(
        borrowedBook,
        location: location,
        state: newState,
        fulfillmentId: nil as String?,
        readiumBookmarks: nil as [TPPReadiumBookmark]?,
        genericBookmarks: nil as [TPPBookLocation]?
      )
      
      // Emit explicit state update so SwiftUI lists refresh immediately
      TPPBookRegistry.shared.setState(newState, for: borrowedBook.identifier)
      
      // Optionally start download
      if attemptDownload && newState == .downloadNeeded {
        await MainActor.run {
          startDownload(for: borrowedBook)
        }
      }
      
      return borrowedBook
      
    } catch let error as PalaceError {
      // Handle structured errors
      await MainActor.run {
        showBorrowError(error, for: book)
      }
      throw error
    } catch {
      // Convert unknown errors to PalaceError
      let palaceError = PalaceError.from(error)
      await MainActor.run {
        showBorrowError(palaceError, for: book)
      }
      throw palaceError
    }
  }
  
  /// Displays borrow error to user
  @MainActor
  private func showBorrowError(_ error: PalaceError, for book: TPPBook) {
    let title = "Borrow Failed"
    let message = error.localizedDescription
    let recovery = error.recoverySuggestion
    
    let alert = TPPAlertUtils.alert(title: title, message: message)
    
    if let recovery = recovery {
      alert.message = "\(message)\n\n\(recovery)"
    }
    
    TPPAlertUtils.presentFromViewControllerOrNil(
      alertController: alert,
      viewController: nil,
      animated: true,
      completion: nil
    )
  }
  
  // MARK: - Async Download Operations
  
  /// Starts download with error recovery and network awareness
  /// - Parameter book: The book to download
  /// - Throws: PalaceError if download cannot be started
  func startDownloadAsync(for book: TPPBook) async throws {
    // Check disk space first
    let estimatedSize = await DiskSpaceChecker.shared.estimateDownloadSize(for: book)
    guard await DiskSpaceChecker.shared.hasSufficientSpace(forDownloadSize: estimatedSize) else {
      throw PalaceError.download(.insufficientSpace)
    }
    
    // Check network conditions
    let networkSuitable = await NetworkConditionMonitor.shared.isNetworkSuitableForDownload()
    if !networkSuitable {
      Log.warn(#file, "Network conditions not suitable for download, waiting...")
      
      // Wait for better conditions (max 60s)
      let gotSuitable = await NetworkConditionMonitor.shared.waitForSuitableConditions(timeout: 60)
      if !gotSuitable {
        throw PalaceError.network(.noConnection)
      }
    }
    
    // Start the download on main actor
    await MainActor.run {
      startDownload(for: book)
    }
  }
  
  // MARK: - Async Return Operations
  
  /// Returns a book asynchronously
  /// - Parameter identifier: The book identifier to return
  /// - Returns: True if return succeeded
  func returnBookAsync(withIdentifier identifier: String) async -> Bool {
    await withCheckedContinuation { continuation in
      returnBook(withIdentifier: identifier) {
        continuation.resume(returning: true)
      }
    }
  }
  
  // MARK: - Async Delete Operations
  
  /// Deletes local content asynchronously
  /// - Parameter identifier: The book identifier
  func deleteLocalContentAsync(for identifier: String) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      deleteLocalContent(for: identifier)
      continuation.resume()
    }
  }
  
  // MARK: - Download Progress Monitoring
  
  /// Monitors download progress as an AsyncStream
  /// - Parameter bookIdentifier: The book to monitor
  /// - Returns: AsyncStream of progress values (0.0 to 1.0)
  func downloadProgressStream(for bookIdentifier: String) -> AsyncStream<Double> {
    AsyncStream { continuation in
      let cancellable = downloadProgressPublisher
        .filter { $0.0 == bookIdentifier }
        .map { $0.1 }
        .sink { progress in
          continuation.yield(progress)
        }
      
      continuation.onTermination = { _ in
        cancellable.cancel()
      }
    }
  }
  
  /// Waits for download to complete
  /// - Parameters:
  ///   - bookIdentifier: The book to monitor
  ///   - timeout: Maximum wait time
  /// - Returns: True if download completed successfully
  func waitForDownloadCompletion(
    for bookIdentifier: String,
    timeout: TimeInterval = 300
  ) async -> Bool {
    let startTime = Date()
    
    for await state in TPPBookRegistry.shared.stateUpdates(for: bookIdentifier) {
      if state == .downloadSuccessful {
        return true
      }
      
      if state == .downloadFailed || state == .unregistered {
        return false
      }
      
      if Date().timeIntervalSince(startTime) > timeout {
        return false
      }
    }
    
    return false
  }
}

// MARK: - Batch Operations

extension MyBooksDownloadCenter {
  /// Downloads multiple books with concurrency limit
  /// - Parameters:
  ///   - books: Array of books to download
  ///   - maxConcurrent: Maximum concurrent downloads
  func downloadBooksAsync(_ books: [TPPBook], maxConcurrent: Int = 3) async {
    await withTaskGroup(of: Void.self) { group in
      var iterator = books.makeIterator()
      var activeCount = 0
      
      while let book = iterator.next() {
        if activeCount >= maxConcurrent {
          // Wait for one to complete
          await group.next()
          activeCount -= 1
        }
        
        group.addTask {
          do {
            try await self.startDownloadAsync(for: book)
          } catch {
            Log.error(#file, "Failed to download \(book.title): \(error.localizedDescription)")
          }
        }
        activeCount += 1
      }
    }
  }
}

