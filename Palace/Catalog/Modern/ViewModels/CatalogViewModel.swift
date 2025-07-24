//
//  CatalogViewModel.swift
//  Palace
//
//  Created by Palace Modernization on Catalog Renovation
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import SwiftUI

/// Main ViewModel for catalog functionality
@MainActor
class CatalogViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var currentFeed: CatalogFeed?
    @Published var navigationState = CatalogNavigationState.initial
    @Published var isLoading = false
    @Published var error: CatalogError?
    @Published var searchResults: CatalogSearchResult?
    @Published var openSearchDescription: OpenSearchDescription?
    
    // MARK: - Private Properties
    
    private let networkService = NetworkService.shared
    private let catalogService = CatalogService.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Cache
    private var feedCache: [URL: CatalogFeed] = [:]
    private let maxCacheSize = 20
    
    // MARK: - Initialization
    
    init() {
        setupBindings()
        loadInitialCatalog()
    }
    
    // MARK: - Public Methods
    
    /// Load catalog from URL
    func loadCatalog(from url: URL, title: String? = nil) async {
        await MainActor.run {
            isLoading = true
            error = nil
        }
        
        do {
            // Check cache first
            if let cachedFeed = feedCache[url] {
                await updateCurrentFeed(cachedFeed, url: url, title: title)
                return
            }
            
            let feed = try await catalogService.fetchCatalogFeed(from: url)
            await updateCurrentFeed(feed, url: url, title: title)
            
            // Cache the feed
            await MainActor.run {
                cacheManager(url: url, feed: feed)
            }
            
            // Load search description if available
            if let searchURL = feed.searchURL {
                await loadSearchDescription(from: searchURL)
            }
            
        } catch {
            await handleError(error)
        }
        
        await MainActor.run {
            isLoading = false
        }
    }
    
    /// Search catalog
    func searchCatalog(query: String, page: Int = 1) async {
        guard let searchURL = openSearchDescription?.searchTemplate,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await handleError(CatalogError.noSearchAvailable)
            return
        }
        
        await MainActor.run {
            isLoading = true
            error = nil
        }
        
        do {
            let results = try await catalogService.searchCatalog(
                searchTemplate: searchURL,
                query: query,
                page: page
            )
            
            await MainActor.run {
                searchResults = results
            }
            
        } catch {
            await handleError(error)
        }
        
        await MainActor.run {
            isLoading = false
        }
    }
    
    /// Navigate to a specific catalog section
    func navigateToSection(url: URL, title: String) async {
        await addBreadcrumb(title: title, url: url)
        await loadCatalog(from: url, title: title)
    }
    
    /// Navigate back to previous section
    func navigateBack() async {
        guard navigationState.canGoBack,
              let previousBreadcrumb = navigationState.breadcrumbs.dropLast().last else {
            return
        }
        
        await removeBreadcrumb()
        await loadCatalog(from: previousBreadcrumb.url, title: previousBreadcrumb.title)
    }
    
    /// Refresh current catalog
    func refresh() async {
        guard let currentURL = navigationState.currentURL else {
            await loadInitialCatalog()
            return
        }
        
        // Clear cache for current URL
        await MainActor.run {
            feedCache.removeValue(forKey: currentURL)
        }
        
        await loadCatalog(from: currentURL, title: navigationState.title)
    }
    
    /// Clear search results
    func clearSearch() {
        searchResults = nil
    }
    
    /// Apply facet filter
    func applyFacet(_ facet: CatalogFacet) async {
        guard let url = facet.href else { return }
        await navigateToSection(url: url, title: facet.label)
    }
    
    // MARK: - Private Methods
    
    private func setupBindings() {
        // Bind network loading state
        networkService.loadingStatePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: \.isLoading, on: self)
            .store(in: &cancellables)
    }
    
    private func loadInitialCatalog() {
        Task {
            guard let mainFeedURL = TPPSettings.shared().accountMainFeedURL else {
                await handleError(CatalogError.networkError("No main feed URL configured"))
                return
            }
            
            await loadCatalog(from: mainFeedURL, title: "Catalog")
        }
    }
    
    private func updateCurrentFeed(_ feed: CatalogFeed, url: URL, title: String?) async {
        await MainActor.run {
            currentFeed = feed
            navigationState = CatalogNavigationState(
                currentURL: url,
                title: title ?? feed.title,
                canGoBack: !navigationState.breadcrumbs.isEmpty,
                breadcrumbs: navigationState.breadcrumbs
            )
        }
    }
    
    private func addBreadcrumb(title: String, url: URL) async {
        await MainActor.run {
            let breadcrumb = CatalogBreadcrumb(
                id: UUID().uuidString,
                title: title,
                url: url
            )
            
            var newBreadcrumbs = navigationState.breadcrumbs
            newBreadcrumbs.append(breadcrumb)
            
            navigationState = CatalogNavigationState(
                currentURL: navigationState.currentURL,
                title: navigationState.title,
                canGoBack: true,
                breadcrumbs: newBreadcrumbs
            )
        }
    }
    
    private func removeBreadcrumb() async {
        await MainActor.run {
            var newBreadcrumbs = navigationState.breadcrumbs
            newBreadcrumbs.removeLast()
            
            navigationState = CatalogNavigationState(
                currentURL: navigationState.currentURL,
                title: navigationState.title,
                canGoBack: !newBreadcrumbs.isEmpty,
                breadcrumbs: newBreadcrumbs
            )
        }
    }
    
    private func loadSearchDescription(from url: URL) async {
        do {
            let description = try await catalogService.fetchOpenSearchDescription(from: url)
            await MainActor.run {
                openSearchDescription = description
            }
        } catch {
            // Search description is optional, don't show error
            Log.info(#file, "Failed to load search description: \(error.localizedDescription)")
        }
    }
    
    private func handleError(_ error: Error) async {
        await MainActor.run {
            if let catalogError = error as? CatalogError {
                self.error = catalogError
            } else {
                self.error = CatalogError.networkError(error.localizedDescription)
            }
        }
    }
    
    private func cacheManager(url: URL, feed: CatalogFeed) {
        feedCache[url] = feed
        
        // Simple LRU cache management
        if feedCache.count > maxCacheSize {
            let oldestKey = feedCache.keys.first
            if let key = oldestKey {
                feedCache.removeValue(forKey: key)
            }
        }
    }
}

// MARK: - Computed Properties

extension CatalogViewModel {
    
    /// Whether search is available
    var canSearch: Bool {
        openSearchDescription != nil
    }
    
    /// Current feed lanes (for grouped feeds)
    var lanes: [CatalogLane] {
        currentFeed?.lanes ?? []
    }
    
    /// Current feed books (for ungrouped feeds)
    var books: [TPPBook] {
        currentFeed?.books ?? []
    }
    
    /// Current feed facet groups
    var facetGroups: [CatalogFacetGroup] {
        currentFeed?.facetGroups ?? []
    }
    
    /// Current feed entry points
    var entryPoints: [CatalogFacet] {
        currentFeed?.entryPoints ?? []
    }
    
    /// Whether current feed is grouped (has lanes)
    var isGroupedFeed: Bool {
        currentFeed?.isGrouped ?? false
    }
    
    /// Whether we have search results
    var hasSearchResults: Bool {
        searchResults != nil
    }
    
    /// Current search query
    var currentSearchQuery: String? {
        searchResults?.query
    }
} 