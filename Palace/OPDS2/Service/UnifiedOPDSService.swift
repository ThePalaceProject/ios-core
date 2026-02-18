//
//  UnifiedOPDSService.swift
//  Palace
//
//  Unified OPDS service supporting OPDS2 (primary) with OPDS1 (fallback)
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - Feed Format

enum OPDSFormat: String, Sendable {
  case opds2 = "application/opds+json"
  case opds1 = "application/atom+xml"
  case unknown
  
  public static func detect(from contentType: String?) -> OPDSFormat {
    guard let contentType = contentType?.lowercased() else { return .unknown }
    
    if contentType.contains("json") || contentType.contains("opds+json") {
      return .opds2
    } else if contentType.contains("xml") || contentType.contains("atom") {
      return .opds1
    }
    
    return .unknown
  }
  
  public static func detect(from data: Data) -> OPDSFormat {
    // Check first bytes for JSON vs XML
    guard let firstChar = String(data: data.prefix(1), encoding: .utf8) else {
      return .unknown
    }
    
    if firstChar == "{" || firstChar == "[" {
      return .opds2
    } else if firstChar == "<" {
      return .opds1
    }
    
    return .unknown
  }
}

// MARK: - Unified Feed Result

/// Unified result that can contain either OPDS2 or OPDS1 feed
enum UnifiedOPDSFeed: Sendable {
  case opds2(OPDS2Feed)
  case opds1(TPPOPDSFeed)
  
  public var format: OPDSFormat {
    switch self {
    case .opds2: return .opds2
    case .opds1: return .opds1
    }
  }
  
  public var title: String {
    switch self {
    case .opds2(let feed): return feed.title
    case .opds1(let feed): return feed.title ?? ""
    }
  }
  
  /// Get as OPDS1 feed (for backward compatibility with existing UI)
  public var asOPDS1: TPPOPDSFeed? {
    switch self {
    case .opds1(let feed): return feed
    case .opds2: return nil // Conversion would go here
    }
  }
  
  /// Get as OPDS2 feed
  public var asOPDS2: OPDS2Feed? {
    switch self {
    case .opds2(let feed): return feed
    case .opds1: return nil
    }
  }
}

// MARK: - Unified OPDS Service

/// Modern OPDS service that supports OPDS2 with automatic OPDS1 fallback
actor UnifiedOPDSService {
  
  // MARK: - Dependencies
  
  private let opds2Cache: OPDS2FeedCache
  private let opds1Cache: OPDS1FeedCache
  private let urlSession: URLSession
  
  // MARK: - State
  
  private var inflightRequests: [URL: Task<UnifiedOPDSFeed, Error>] = [:]
  
  // MARK: - Singleton
  
  public static let shared = UnifiedOPDSService()
  
  // MARK: - Initialization
  
  public init(
    opds2Cache: OPDS2FeedCache = .shared,
    opds1Cache: OPDS1FeedCache = .shared,
    urlSession: URLSession = .shared
  ) {
    self.opds2Cache = opds2Cache
    self.opds1Cache = opds1Cache
    self.urlSession = urlSession
  }
  
  // MARK: - Primary API
  
  /// Fetches a feed, preferring OPDS2 format with automatic OPDS1 fallback
  /// Uses stale-while-revalidate caching for optimal performance
  public func fetchFeed(
    from url: URL,
    preferOPDS2: Bool = true,
    useToken: Bool = true,
    forceRefresh: Bool = false
  ) async throws -> UnifiedOPDSFeed {
    
    // Check for existing inflight request
    if let existing = inflightRequests[url] {
      return try await existing.value
    }
    
    // Create new fetch task
    let task = Task<UnifiedOPDSFeed, Error> { [self] in
      // Try OPDS2 first if preferred
      if preferOPDS2 {
        do {
          let feed = try await fetchOPDS2Feed(from: url, useToken: useToken, forceRefresh: forceRefresh)
          return .opds2(feed)
        } catch {
          Log.info(#file, "OPDS2 fetch failed, falling back to OPDS1: \(error.localizedDescription)")
        }
      }
      
      // Fallback to OPDS1
      let feed = try await fetchOPDS1Feed(from: url, useToken: useToken, forceRefresh: forceRefresh)
      return .opds1(feed)
    }
    
    inflightRequests[url] = task
    
    defer {
      inflightRequests[url] = nil
    }
    
    return try await task.value
  }
  
  /// Fetches feed with automatic format detection
  public func fetchFeedAutoDetect(
    from url: URL,
    useToken: Bool = true
  ) async throws -> UnifiedOPDSFeed {
    
    // First, make a HEAD request to check content type
    var headRequest = URLRequest(url: url)
    headRequest.httpMethod = "HEAD"
    addAuthHeaders(to: &headRequest, useToken: useToken)
    
    do {
      let (_, response) = try await urlSession.data(for: headRequest)
      
      if let httpResponse = response as? HTTPURLResponse {
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
        let format = OPDSFormat.detect(from: contentType)
        
        switch format {
        case .opds2:
          let feed = try await fetchOPDS2Feed(from: url, useToken: useToken, forceRefresh: false)
          return .opds2(feed)
        case .opds1:
          let feed = try await fetchOPDS1Feed(from: url, useToken: useToken, forceRefresh: false)
          return .opds1(feed)
        case .unknown:
          // Try OPDS2 first, fallback to OPDS1
          return try await fetchFeed(from: url, preferOPDS2: true, useToken: useToken)
        }
      }
    } catch {
      Log.warn(#file, "HEAD request failed, trying full fetch: \(error)")
    }
    
    // Fallback to standard fetch
    return try await fetchFeed(from: url, preferOPDS2: true, useToken: useToken)
  }
  
  // MARK: - OPDS2 Fetch
  
  private func fetchOPDS2Feed(
    from url: URL,
    useToken: Bool,
    forceRefresh: Bool
  ) async throws -> OPDS2Feed {
    
    // Check cache unless forcing refresh
    if !forceRefresh {
      let result = try await opds2Cache.getWithRevalidation(for: url) { [self] in
        try await performOPDS2Fetch(from: url, useToken: useToken)
      }
      return result.feed
    }
    
    // Force fresh fetch
    let (feed, etag, lastModified) = try await performOPDS2Fetch(from: url, useToken: useToken)
    let entry = OPDSCacheEntry(feed: feed, etag: etag, lastModified: lastModified)
    await opds2Cache.set(entry, for: url)
    
    return feed
  }
  
  private func performOPDS2Fetch(
    from url: URL,
    useToken: Bool
  ) async throws -> (OPDS2Feed, etag: String?, lastModified: String?) {
    
    var request = URLRequest(url: url)
    request.setValue("application/opds+json", forHTTPHeaderField: "Accept")
    addAuthHeaders(to: &request, useToken: useToken)
    
    // Add conditional headers if we have cached data
    let conditionalHeaders = await opds2Cache.conditionalHeaders(for: url)
    for (key, value) in conditionalHeaders {
      request.setValue(value, forHTTPHeaderField: key)
    }
    
    let (data, response) = try await urlSession.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse else {
      throw PalaceError.network(.invalidResponse)
    }
    
    // Handle 304 Not Modified
    if httpResponse.statusCode == 304 {
      if let cached = await opds2Cache.get(for: url) {
        return (cached.feed, cached.etag, cached.lastModified)
      }
      throw PalaceError.network(.invalidResponse)
    }
    
    guard (200...299).contains(httpResponse.statusCode) else {
      throw PalaceError.network(.serverError)
    }
    
    // Parse OPDS2 JSON
    let feed = try OPDS2Feed.from(data: data)
    
    // Extract caching headers
    let etag = httpResponse.value(forHTTPHeaderField: "ETag")
    let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")
    
    return (feed, etag, lastModified)
  }
  
  // MARK: - OPDS1 Fetch (Fallback)
  
  private func fetchOPDS1Feed(
    from url: URL,
    useToken: Bool,
    forceRefresh: Bool
  ) async throws -> TPPOPDSFeed {
    
    // Check cache
    if !forceRefresh, let cached = await opds1Cache.get(for: url) {
      // Trigger background refresh if stale
      if await opds1Cache.isStale(for: url) {
        Task.detached { [self] in
          do {
            let fresh = try await performOPDS1Fetch(from: url, useToken: useToken)
            await opds1Cache.set(fresh, for: url)
          } catch {
            Log.warn(#file, "Background OPDS1 refresh failed: \(error)")
          }
        }
      }
      return cached
    }
    
    // Fetch fresh
    let feed = try await performOPDS1Fetch(from: url, useToken: useToken)
    await opds1Cache.set(feed, for: url)
    
    return feed
  }
  
  private func performOPDS1Fetch(
    from url: URL,
    useToken: Bool
  ) async throws -> TPPOPDSFeed {
    // Use existing OPDSFeedService for OPDS1 compatibility
    return try await OPDSFeedService.shared.fetchFeed(
      from: url,
      resetCache: true,
      useToken: useToken
    )
  }
  
  // MARK: - Auth Headers
  
  private func addAuthHeaders(to request: inout URLRequest, useToken: Bool) {
    guard useToken else { return }
    
    let userAccount = TPPUserAccount.sharedAccount()
    
    if let authToken = userAccount.authToken {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    } else if let barcode = userAccount.barcode, let pin = userAccount.pin {
      let credentials = "\(barcode):\(pin)"
      if let data = credentials.data(using: .utf8) {
        let base64 = data.base64EncodedString()
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
      }
    }
  }
  
  // MARK: - Cache Management
  
  public func invalidateCache(for url: URL) async {
    await opds2Cache.remove(for: url)
    await opds1Cache.remove(for: url)
  }
  
  public func clearAllCaches() async {
    await opds2Cache.clear()
    await opds1Cache.clear()
  }
  
  // MARK: - Request Management
  
  public func cancelRequest(for url: URL) {
    inflightRequests[url]?.cancel()
    inflightRequests[url] = nil
  }
  
  public func cancelAllRequests() {
    inflightRequests.values.forEach { $0.cancel() }
    inflightRequests.removeAll()
  }
}

// MARK: - Convenience Extensions

extension UnifiedOPDSService {
  
  /// Fetches catalog root with caching
  public func fetchCatalogRoot() async throws -> UnifiedOPDSFeed {
    guard let catalogURLString = AccountsManager.shared.currentAccount?.catalogUrl,
          let catalogURL = URL(string: catalogURLString) else {
      throw PalaceError.authentication(.accountNotFound)
    }
    
    return try await fetchFeed(from: catalogURL, preferOPDS2: true, useToken: false)
  }
  
  /// Fetches user's loans feed
  public func fetchLoans() async throws -> UnifiedOPDSFeed {
    guard let loansURL = AccountsManager.shared.currentAccount?.loansUrl else {
      throw PalaceError.authentication(.accountNotFound)
    }
    
    return try await fetchFeed(from: loansURL, preferOPDS2: true, useToken: true, forceRefresh: true)
  }
  
  /// Fetches a specific page/lane
  public func fetchPage(at url: URL) async throws -> UnifiedOPDSFeed {
    return try await fetchFeed(from: url, preferOPDS2: true, useToken: true)
  }
}
