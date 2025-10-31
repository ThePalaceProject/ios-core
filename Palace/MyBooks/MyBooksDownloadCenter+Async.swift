//
//  MyBooksDownloadCenter+Async.swift
//  Palace
//
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
    
    // Try to extract problem document from error for better messaging
    let nsError = error as NSError
    let problemDoc = nsError.userInfo["problemDocument"] as? TPPProblemDocument
    
    let alert = TPPAlertUtils.alert(title: title, message: error.localizedDescription)
    
    // If we have a problem document, use its title/detail instead
    if let problemDoc = problemDoc {
      TPPAlertUtils.setProblemDocument(controller: alert, document: problemDoc, append: false)
    } else if let recovery = error.recoverySuggestion {
      alert.message = "\(error.localizedDescription)\n\n\(recovery)"
    }
    
    TPPAlertUtils.presentFromViewControllerOrNil(
      alertController: alert,
      viewController: nil,
      animated: true,
      completion: nil
    )
  }

