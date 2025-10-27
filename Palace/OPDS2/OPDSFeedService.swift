//
//  OPDSFeedService.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Modern async/await service for OPDS feed operations
/// Wraps legacy Objective-C TPPOPDSFeed with type-safe async API
actor OPDSFeedService {
  
  static let shared = OPDSFeedService()
  
  private var inflightRequests: [URL: Task<TPPOPDSFeed, Error>] = [:]
  
  private init() {}
  
  // MARK: - Feed Fetching
  
  /// Fetches an OPDS feed from the given URL
  /// - Parameters:
  ///   - url: The URL to fetch from
  ///   - resetCache: Whether to reset the cache before fetching
  ///   - useToken: Whether to use authentication token if available
  /// - Returns: The parsed OPDS feed
  /// - Throws: PalaceError if fetch or parsing fails
  func fetchFeed(
    from url: URL,
    resetCache: Bool = false,
    useToken: Bool = true
  ) async throws -> TPPOPDSFeed {
    // Check for existing inflight request
    if let existingTask = inflightRequests[url] {
      return try await existingTask.value
    }
    
    // Create new task
    let task = Task<TPPOPDSFeed, Error> {
      return try await withCheckedThrowingContinuation { continuation in
        TPPOPDSFeed.withURL(
          url,
          shouldResetCache: resetCache,
          useTokenIfAvailable: useToken
        ) { feed, errorDict in
          if let feed = feed {
            continuation.resume(returning: feed)
          } else if let errorDict = errorDict {
            let error = self.parseError(from: errorDict, url: url)
            continuation.resume(throwing: error)
          } else {
            continuation.resume(throwing: PalaceError.parsing(.opdsFeedInvalid))
          }
        }
      }
    }
    
    // Store task
    inflightRequests[url] = task
    
    // Wait for completion and cleanup
    defer {
      inflightRequests[url] = nil
    }
    
    return try await task.value
  }
  
  /// Fetches a single OPDS entry from the given URL
  /// - Parameters:
  ///   - url: The URL to fetch from
  ///   - resetCache: Whether to reset the cache before fetching
  ///   - useToken: Whether to use authentication token if available
  /// - Returns: The first entry from the feed
  /// - Throws: PalaceError if fetch fails or no entry is found
  func fetchEntry(
    from url: URL,
    resetCache: Bool = false,
    useToken: Bool = true
  ) async throws -> TPPOPDSEntry {
    let feed = try await fetchFeed(from: url, resetCache: resetCache, useToken: useToken)
    
    guard let entry = feed.entries.first as? TPPOPDSEntry else {
      throw PalaceError.parsing(.opdsFeedInvalid)
    }
    
    return entry
  }
  
  /// Fetches a book from the given URL
  /// - Parameters:
  ///   - url: The URL to fetch from
  ///   - resetCache: Whether to reset the cache before fetching
  ///   - useToken: Whether to use authentication token if available
  /// - Returns: A TPPBook parsed from the entry
  /// - Throws: PalaceError if fetch or parsing fails
  func fetchBook(
    from url: URL,
    resetCache: Bool = false,
    useToken: Bool = true
  ) async throws -> TPPBook {
    let entry = try await fetchEntry(from: url, resetCache: resetCache, useToken: useToken)
    
    guard let book = TPPBook(entry: entry) else {
      throw PalaceError.parsing(.opdsFeedInvalid)
    }
    
    return book
  }
  
  // MARK: - Borrow Operations
  
  /// Borrows a book by performing a PUT/GET to the acquisition URL
  /// - Parameters:
  ///   - book: The book to borrow
  ///   - attemptDownload: Whether to immediately attempt download after borrowing
  /// - Returns: The borrowed book with updated acquisition links
  /// - Throws: PalaceError if borrow fails
  func borrowBook(
    _ book: TPPBook,
    attemptDownload: Bool = false
  ) async throws -> TPPBook {
    guard let acquisitionURL = book.defaultAcquisition?.hrefURL else {
      throw PalaceError.bookRegistry(.invalidState)
    }
    
    let borrowedBook = try await fetchBook(
      from: acquisitionURL,
      resetCache: true,
      useToken: true
    )
    
    return borrowedBook
  }
  
  // MARK: - Error Parsing
  
  private func parseError(from errorDict: [AnyHashable: Any], url: URL) -> PalaceError {
    // Check for problem document
    if let problemDoc = TPPProblemDocument.fromDictionary(errorDict) {
      return parseProblemDocument(problemDoc)
    }
    
    // Check for generic error info
    if let errorType = errorDict["type"] as? String {
      switch errorType {
      case TPPProblemDocument.TypeNoActiveLoan:
        return .bookRegistry(.bookNotFound)
      case TPPProblemDocument.TypeLoanAlreadyExists:
        return .bookRegistry(.invalidState)
      case TPPProblemDocument.TypeInvalidCredentials:
        return .authentication(.invalidCredentials)
      default:
        break
      }
    }
    
    // Check for HTTP status codes
    if let status = errorDict["status"] as? Int {
      switch status {
      case 401:
        return .authentication(.tokenExpired)
      case 403:
        return .network(.forbidden)
      case 404:
        return .network(.notFound)
      case 429:
        return .network(.rateLimited)
      case 500...599:
        return .network(.serverError)
      default:
        break
      }
    }
    
    // Default to parsing error
    Log.error(#file, "Failed to fetch OPDS feed from \(url): \(errorDict)")
    return .parsing(.opdsFeedInvalid)
  }
  
  private func parseProblemDocument(_ problemDoc: TPPProblemDocument) -> PalaceError {
    guard let type = problemDoc.type else {
      return .parsing(.opdsFeedInvalid)
    }
    
    switch type {
    case TPPProblemDocument.TypeNoActiveLoan:
      return .bookRegistry(.bookNotFound)
    case TPPProblemDocument.TypeLoanAlreadyExists:
      return .bookRegistry(.invalidState)
    case TPPProblemDocument.TypeInvalidCredentials:
      return .authentication(.invalidCredentials)
    default:
      return .parsing(.opdsFeedInvalid)
    }
  }
  
  // MARK: - Request Cancellation
  
  /// Cancels any inflight requests for the given URL
  func cancelRequest(for url: URL) {
    inflightRequests[url]?.cancel()
    inflightRequests[url] = nil
  }
  
  /// Cancels all inflight requests
  func cancelAllRequests() {
    inflightRequests.values.forEach { $0.cancel() }
    inflightRequests.removeAll()
  }
}

// MARK: - Convenience Extensions

extension OPDSFeedService {
  /// Fetches the user's loans feed
  func fetchLoans() async throws -> TPPOPDSFeed {
    guard let loansURL = AccountsManager.shared.currentAccount?.loansUrl else {
      throw PalaceError.authentication(.accountNotFound)
    }
    
    return try await fetchFeed(from: loansURL, resetCache: true, useToken: true)
  }
  
  /// Fetches the catalog root
  func fetchCatalogRoot() async throws -> TPPOPDSFeed {
    guard let catalogURL = AccountsManager.shared.currentAccount?.catalogUrl else {
      throw PalaceError.authentication(.accountNotFound)
    }
    
    return try await fetchFeed(from: catalogURL, resetCache: false, useToken: false)
  }
}

// MARK: - TPPProblemDocument Extension

extension TPPProblemDocument {
  static func fromDictionary(_ dict: [AnyHashable: Any]) -> TPPProblemDocument? {
    // Convert to [String: Any]
    var stringDict: [String: Any] = [:]
    for (key, value) in dict {
      if let stringKey = key as? String {
        stringDict[stringKey] = value
      }
    }
    
    // Try to create problem document
    guard let data = try? JSONSerialization.data(withJSONObject: stringDict),
          let problemDoc = try? JSONDecoder().decode(TPPProblemDocument.self, from: data) else {
      return nil
    }
    
    return problemDoc
  }
}

