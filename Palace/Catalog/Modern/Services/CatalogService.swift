//
//  CatalogService.swift
//  Palace
//
//  Created by Palace Modernization on Catalog Renovation
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Service layer for catalog operations
@MainActor
class CatalogService: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = CatalogService()
    
    // MARK: - Properties
    
    private let networkService = NetworkService.shared
    private let cacheService = CatalogCacheService.shared
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch catalog feed from URL
    func fetchCatalogFeed(from url: URL) async throws -> CatalogFeed {
        // Check cache first
        if let cachedFeed = await cacheService.getCachedFeed(for: url),
           !await cacheService.isCacheExpired(for: url) {
            return cachedFeed
        }
        
        do {
            let feed = try await networkService.fetchCatalogFeed(from: url)
            
            // Cache the feed
            await cacheService.cacheFeed(feed, for: url)
            
            return feed
        } catch {
            // If network fails, try to return cached feed even if expired
            if let cachedFeed = await cacheService.getCachedFeed(for: url) {
                return cachedFeed
            }
            throw error
        }
    }
    
    /// Search catalog using OpenSearch template
    func searchCatalog(searchTemplate: String, query: String, page: Int = 1) async throws -> CatalogSearchResult {
        let searchURL = try buildSearchURL(template: searchTemplate, query: query, page: page)
        
        // For search, we'll create a simplified search result from the catalog feed
        let feed = try await fetchCatalogFeed(from: searchURL)
        
        return CatalogSearchResult(
            query: query,
            totalResults: feed.books.count, // This is approximate - OPDS doesn't always provide total
            startIndex: (page - 1) * 20,
            itemsPerPage: 20,
            books: feed.books,
            facetGroups: feed.facetGroups,
            nextURL: feed.nextURL,
            previousURL: feed.previousURL
        )
    }
    
    /// Fetch OpenSearch description
    func fetchOpenSearchDescription(from url: URL) async throws -> OpenSearchDescription {
        // Check cache first
        if let cached = await cacheService.getCachedSearchDescription(for: url) {
            return cached
        }
        
        let request = URLRequest(url: url)
        let (data, _) = try await networkService.performDataRequest(request)
        
        let description = try await CatalogFeedParser.parseOpenSearchDescription(data: data)
        
        // Cache the description
        await cacheService.cacheSearchDescription(description, for: url)
        
        return description
    }
    
    /// Prefetch next page for pagination
    func prefetchNextPage(from feed: CatalogFeed) async {
        guard let nextURL = feed.nextURL else { return }
        
        Task {
            do {
                _ = try await fetchCatalogFeed(from: nextURL)
            } catch {
                // Prefetch failures are silent
                Log.info(#file, "Prefetch failed for \(nextURL): \(error.localizedDescription)")
            }
        }
    }
    
    /// Clear all caches
    func clearCache() async {
        await cacheService.clearAll()
    }
    
    /// Get cache statistics
    func getCacheStatistics() async -> CatalogCacheStatistics {
        await cacheService.getStatistics()
    }
    
    // MARK: - Private Methods
    
    private func buildSearchURL(template: String, query: String, page: Int) throws -> URL {
        // Replace OpenSearch template parameters
        let pageSize = 20
        let startIndex = (page - 1) * pageSize
        
        var urlString = template
            .replacingOccurrences(of: "{searchTerms}", with: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            .replacingOccurrences(of: "{startIndex?}", with: "\(startIndex)")
            .replacingOccurrences(of: "{count?}", with: "\(pageSize)")
            .replacingOccurrences(of: "{startPage?}", with: "\(page)")
        
        // Handle optional parameters by removing them if not replaced
        urlString = urlString.replacingOccurrences(of: "{startIndex}", with: "\(startIndex)")
        urlString = urlString.replacingOccurrences(of: "{count}", with: "\(pageSize)")
        urlString = urlString.replacingOccurrences(of: "{startPage}", with: "\(page)")
        
        guard let url = URL(string: urlString) else {
            throw CatalogError.invalidSearchTemplate
        }
        
        return url
    }
}

// MARK: - Cache Service

@MainActor
class CatalogCacheService {
    
    static let shared = CatalogCacheService()
    
    private var feedCache: [URL: CachedFeed] = [:]
    private var searchDescriptionCache: [URL: OpenSearchDescription] = [:]
    private let cacheExpirationInterval: TimeInterval = 10 * 60 // 10 minutes
    private let maxCacheSize = 50
    
    private struct CachedFeed {
        let feed: CatalogFeed
        let timestamp: Date
    }
    
    private init() {}
    
    func getCachedFeed(for url: URL) -> CatalogFeed? {
        feedCache[url]?.feed
    }
    
    func cacheFeed(_ feed: CatalogFeed, for url: URL) {
        feedCache[url] = CachedFeed(feed: feed, timestamp: Date())
        manageCacheSize()
    }
    
    func isCacheExpired(for url: URL) -> Bool {
        guard let cached = feedCache[url] else { return true }
        return Date().timeIntervalSince(cached.timestamp) > cacheExpirationInterval
    }
    
    func getCachedSearchDescription(for url: URL) -> OpenSearchDescription? {
        searchDescriptionCache[url]
    }
    
    func cacheSearchDescription(_ description: OpenSearchDescription, for url: URL) {
        searchDescriptionCache[url] = description
    }
    
    func clearAll() {
        feedCache.removeAll()
        searchDescriptionCache.removeAll()
    }
    
    func getStatistics() -> CatalogCacheStatistics {
        let totalFeeds = feedCache.count
        let expiredFeeds = feedCache.values.filter { Date().timeIntervalSince($0.timestamp) > cacheExpirationInterval }.count
        
        return CatalogCacheStatistics(
            totalCachedFeeds: totalFeeds,
            expiredFeeds: expiredFeeds,
            totalCachedSearchDescriptions: searchDescriptionCache.count,
            cacheHitRate: 0.0 // TODO: Implement proper hit rate tracking
        )
    }
    
    private func manageCacheSize() {
        guard feedCache.count > maxCacheSize else { return }
        
        // Remove oldest entries
        let sortedEntries = feedCache.sorted { $0.value.timestamp < $1.value.timestamp }
        let entriesToRemove = sortedEntries.prefix(feedCache.count - maxCacheSize)
        
        for (url, _) in entriesToRemove {
            feedCache.removeValue(forKey: url)
        }
    }
}

// MARK: - Cache Statistics

struct CatalogCacheStatistics {
    let totalCachedFeeds: Int
    let expiredFeeds: Int
    let totalCachedSearchDescriptions: Int
    let cacheHitRate: Double
    
    var activeCachedFeeds: Int {
        totalCachedFeeds - expiredFeeds
    }
} 