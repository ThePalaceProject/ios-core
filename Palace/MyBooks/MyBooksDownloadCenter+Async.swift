//
//  MyBooksDownloadCenter+Async.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Modern async/await extensions for MyBooksDownloadCenter
extension MyBooksDownloadCenter {
  
  // MARK: - Borrow Re-auth State
  
  /// Tracks whether we've already attempted re-authentication for a borrow operation
  /// Prevents infinite re-auth loops for persistent auth failures
  private static var borrowReauthAttempted: Set<String> = []
  private static let borrowReauthLock = NSLock()
  
  private static func hasBorrowReauthBeenAttempted(for bookId: String) -> Bool {
    borrowReauthLock.lock()
    defer { borrowReauthLock.unlock() }
    return borrowReauthAttempted.contains(bookId)
  }
  
  private static func markBorrowReauthAttempted(for bookId: String) {
    borrowReauthLock.lock()
    defer { borrowReauthLock.unlock() }
    borrowReauthAttempted.insert(bookId)
  }
  
  private static func clearBorrowReauthAttempted(for bookId: String) {
    borrowReauthLock.lock()
    defer { borrowReauthLock.unlock() }
    borrowReauthAttempted.remove(bookId)
  }
  
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
    let bookIdentifier = book.identifier
    
    #if DEBUG
    // Check if error simulation is enabled via Developer Settings
    if let simulated = DebugSettings.shared.createSimulatedBorrowError() {
      await MainActor.run {
        showBorrowError(.network(.forbidden), originalError: simulated.error, for: book, problemDocument: simulated.problemDocument)
      }
      throw simulated.error
    }
    #endif
    
    // Use modern OPDSFeedService instead of legacy callback-based TPPOPDSFeed
    guard let acquisitionURL = book.defaultAcquisition?.hrefURL else {
      throw PalaceError.bookRegistry(.invalidState)
    }
    
    // Set processing state - this shows a spinner in the UI
    await MainActor.run {
      TPPBookRegistry.shared.setProcessing(true, for: bookIdentifier)
    }
    
    // Helper to clear processing state on all exit paths
    // Using @MainActor func instead of detached Task to ensure immediate execution
    @MainActor func clearProcessingState() {
      TPPBookRegistry.shared.setProcessing(false, for: bookIdentifier)
    }
    
    do {
      // Fetch the borrowed book using modern async API with automatic retries
      // Use borrowOperation policy for fast fail - shows error quickly instead of freezing
      let recovery = DownloadErrorRecovery()
      let borrowedBook = try await recovery.executeWithRetry(
        policy: DownloadErrorRecovery.RetryPolicy.borrowOperation
      ) {
        try await OPDSFeedService.shared.fetchBook(
          from: acquisitionURL,
          resetCache: true,
          useToken: true
        )
      }
      
      // Clear processing state before updating registry
      await clearProcessingState()
      
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
      
      // Clear re-auth tracking on success
      Self.clearBorrowReauthAttempted(for: bookIdentifier)
      
      return borrowedBook
      
    } catch let error as PalaceError {
      // Clear processing state immediately on error
      await clearProcessingState()
      
      // Check if this is an authentication error that needs re-auth
      if await handleBorrowAuthErrorIfNeeded(error, originalError: nil, for: book, attemptDownload: attemptDownload) {
        // Re-auth was triggered, don't show error alert
        throw error
      }
      
      // Handle structured errors - but PalaceError doesn't carry problem document
      await MainActor.run {
        showBorrowError(error, originalError: nil, for: book)
      }
      throw error
    } catch {
      // Clear processing state immediately on error
      await clearProcessingState()
      
      // Extract problem document from original NSError before converting
      // The server's problem document contains the user-friendly error message
      let nsError = error as NSError
      let problemDoc = nsError.problemDocument
      
      let palaceError = PalaceError.from(error)
      
      // Check if this is an authentication error that needs re-auth
      if await handleBorrowAuthErrorIfNeeded(palaceError, originalError: error, for: book, attemptDownload: attemptDownload, problemDocument: problemDoc) {
        // Re-auth was triggered, don't show error alert
        throw palaceError
      }
      
      await MainActor.run {
        showBorrowError(palaceError, originalError: error, for: book, problemDocument: problemDoc)
      }
      throw palaceError
    }
  }
  
  /// Checks if the error indicates an authentication failure and handles re-auth if needed
  /// - Returns: `true` if re-auth was triggered (caller should not show error), `false` otherwise
  private func handleBorrowAuthErrorIfNeeded(
    _ error: PalaceError,
    originalError: Error?,
    for book: TPPBook,
    attemptDownload: Bool,
    problemDocument: TPPProblemDocument? = nil
  ) async -> Bool {
    let userAccount = TPPUserAccount.sharedAccount()
    let authDef = userAccount.authDefinition
    let hasCredentials = userAccount.hasCredentials()
    
    // Check if this is an auth-related error
    let isAuthError: Bool = {
      // Check PalaceError type
      if case .authentication = error {
        return true
      }
      
      // Check problem document type
      if let problemDoc = problemDocument, problemDoc.type == TPPProblemDocument.TypeInvalidCredentials {
        return true
      }
      
      // Check original error for 401 status
      if let nsError = originalError as NSError?, nsError.code == TPPErrorCode.invalidCredentials.rawValue {
        return true
      }
      
      return false
    }()
    
    guard isAuthError else {
      return false
    }
    
    // Circuit breaker: Don't re-auth if we already tried for this book
    guard !Self.hasBorrowReauthBeenAttempted(for: book.identifier) else {
      Log.warn(#file, "Borrow re-auth already attempted for '\(book.title)' - showing error instead")
      return false
    }
    
    Log.info(#file, "Borrow failed with auth error for '\(book.title)' - attempting re-authentication")
    Self.markBorrowReauthAttempted(for: book.identifier)
    
    // Handle based on auth type
    if authDef?.isSaml == true && hasCredentials {
      // SAML: Session cookies expired - need to re-auth via IDP
      Log.info(#file, "SAML session expired during borrow - triggering SAML re-auth flow")
      
      await MainActor.run { [weak self] in
        SignInModalPresenter.presentSignInModalForCurrentAccount {
          guard let self else { return }
          Log.info(#file, "SAML re-auth completed, retrying borrow for '\(book.title)'")
          
          // Clear the re-auth flag after successful auth so future attempts can also re-auth
          Self.clearBorrowReauthAttempted(for: book.identifier)
          
          // Retry the borrow
          Task {
            do {
              _ = try await self.borrowAsync(book, attemptDownload: attemptDownload)
            } catch {
              Log.error(#file, "Retry borrow failed after SAML re-auth: \(error.localizedDescription)")
            }
          }
        }
      }
      return true
      
    } else if !hasCredentials && (authDef?.needsAuth ?? false) {
      // No credentials - show sign-in modal
      Log.info(#file, "No credentials for borrow - showing sign-in modal")
      
      await MainActor.run { [weak self] in
        SignInModalPresenter.presentSignInModalForCurrentAccount {
          guard let self else { return }
          Log.info(#file, "Sign-in completed, retrying borrow for '\(book.title)'")
          
          Self.clearBorrowReauthAttempted(for: book.identifier)
          
          Task {
            do {
              _ = try await self.borrowAsync(book, attemptDownload: attemptDownload)
            } catch {
              Log.error(#file, "Retry borrow failed after sign-in: \(error.localizedDescription)")
            }
          }
        }
      }
      return true
    }
    
    // For OAuth/Token auth, the network layer should have already tried token refresh
    // If we got here, refresh failed - show the error
    Log.warn(#file, "Auth error for non-SAML auth type - token refresh likely failed")
    return false
  }
  
  /// Displays borrow error to user with optional problem document from server
  /// - Parameters:
  ///   - error: The structured PalaceError
  ///   - originalError: The original error that may contain problem document
  ///   - book: The book that failed to borrow
  ///   - problemDocument: Optional pre-extracted problem document
  @MainActor
  private func showBorrowError(
    _ error: PalaceError,
    originalError: Error?,
    for book: TPPBook,
    problemDocument: TPPProblemDocument? = nil
  ) {
    let title = Strings.MyDownloadCenter.borrowFailed
    
    // Try to extract problem document from the original error
    // This is where the server's specific error message lives (e.g., "loan limit reached", "credentials suspended")
    let problemDoc: TPPProblemDocument? = {
      // Use pre-extracted problem document if available
      if let doc = problemDocument {
        return doc
      }
      // Try to extract from original error
      if let nsError = originalError as NSError? {
        return nsError.problemDocument
      }
      return nil
    }()
    
    // Log the problem document details for debugging
    if let doc = problemDoc {
      Log.info(#file, "Borrow error with problem document - type: \(doc.type ?? "unknown"), title: \(doc.title ?? "none"), detail: \(doc.detail ?? "none")")
    }
    
    // Start with the generic error message
    let alert = TPPAlertUtils.alert(title: title, message: error.localizedDescription)
    
    // If we have a problem document from the server, use its title/detail instead
    // This provides specific messages like "loan limit reached" or "credentials suspended"
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
}
