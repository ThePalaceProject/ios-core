//
//  CatalogModels.swift
//  Palace
//
//  Created by Palace Modernization on Catalog Renovation
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - Core Catalog Models

/// Represents a catalog feed from OPDS
struct CatalogFeed: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let type: FeedType
    let links: [CatalogLink]
    let entries: [CatalogEntry]
    let facetGroups: [CatalogFacetGroup]
    let entryPoints: [CatalogFacet]
    let searchURL: URL?
    let nextURL: URL?
    let previousURL: URL?
    let selfURL: URL?
    let updated: Date?
    
    enum FeedType: String, Codable {
        case acquisitionGrouped = "acquisition-grouped"
        case acquisitionUngrouped = "acquisition-ungrouped"
        case navigation = "navigation"
        case invalid = "invalid"
    }
    
    var isGrouped: Bool {
        type == .acquisitionGrouped
    }
    
    var lanes: [CatalogLane] {
        guard isGrouped else { return [] }
        return entries.compactMap { entry in
            CatalogLane(
                id: entry.id,
                title: entry.title,
                books: entry.books,
                subsectionURL: entry.links.first(where: { $0.rel == "subsection" })?.href
            )
        }
    }
    
    var books: [TPPBook] {
        entries.flatMap { $0.books }
    }
}

/// Represents a single entry in a catalog feed
struct CatalogEntry: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String?
    let content: String?
    let updated: Date?
    let published: Date?
    let links: [CatalogLink]
    let categories: [CatalogCategory]
    let authors: [CatalogAuthor]
    
    /// Books associated with this entry (for lanes)
    var books: [TPPBook] {
        // This would be populated by the parser based on the entry content
        // For now, return empty array - actual implementation would parse OPDS entry
        []
    }
}

/// Represents a link in catalog feeds
struct CatalogLink: Codable, Hashable {
    let href: URL
    let rel: String?
    let type: String?
    let title: String?
    let templated: Bool?
    
    var isTemplated: Bool {
        templated ?? false
    }
}

/// Represents a category/genre
struct CatalogCategory: Codable, Hashable {
    let term: String
    let label: String?
    let scheme: String?
}

/// Represents an author
struct CatalogAuthor: Codable, Hashable {
    let name: String
    let uri: URL?
}

/// Represents a catalog lane (grouped feed section)
struct CatalogLane: Identifiable, Hashable {
    let id: String
    let title: String
    let books: [TPPBook]
    let subsectionURL: URL?
    
    var hasMore: Bool {
        subsectionURL != nil
    }
}

// MARK: - Facets and Filtering

/// Represents a group of related facets
struct CatalogFacetGroup: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let facets: [CatalogFacet]
}

/// Represents a single facet for filtering
struct CatalogFacet: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let href: URL?
    let isActive: Bool
    let count: Int?
    
    init(id: String, label: String, href: URL? = nil, isActive: Bool = false, count: Int? = nil) {
        self.id = id
        self.label = label
        self.href = href
        self.isActive = isActive
        self.count = count
    }
}

// MARK: - Search Models

/// Represents search results
struct CatalogSearchResult: Codable {
    let query: String
    let totalResults: Int
    let startIndex: Int
    let itemsPerPage: Int
    let books: [TPPBook]
    let facetGroups: [CatalogFacetGroup]
    let nextURL: URL?
    let previousURL: URL?
    
    var hasNextPage: Bool {
        nextURL != nil
    }
    
    var hasPreviousPage: Bool {
        previousURL != nil
    }
    
    var currentPage: Int {
        (startIndex / itemsPerPage) + 1
    }
    
    var totalPages: Int {
        (totalResults + itemsPerPage - 1) / itemsPerPage
    }
}

/// Represents search parameters
struct CatalogSearchParameters: Hashable {
    let query: String
    let page: Int
    let pageSize: Int
    let filters: [String: String]
    
    init(query: String, page: Int = 1, pageSize: Int = 20, filters: [String: String] = [:]) {
        self.query = query
        self.page = page
        self.pageSize = pageSize
        self.filters = filters
    }
}

// MARK: - Navigation Models

/// Represents catalog navigation state
struct CatalogNavigationState: Hashable {
    let currentURL: URL?
    let title: String?
    let canGoBack: Bool
    let breadcrumbs: [CatalogBreadcrumb]
    
    static let initial = CatalogNavigationState(
        currentURL: nil,
        title: nil,
        canGoBack: false,
        breadcrumbs: []
    )
}

/// Represents a breadcrumb in navigation
struct CatalogBreadcrumb: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
}

// MARK: - Open Search Description

/// Represents OpenSearch description for catalog search
struct OpenSearchDescription: Codable {
    let shortName: String
    let description: String
    let urls: [OpenSearchURL]
    let contact: String?
    let tags: String?
    let longName: String?
    
    struct OpenSearchURL: Codable {
        let template: String
        let type: String
        let rel: String?
        
        var isSearchTemplate: Bool {
            type.contains("atom") && rel?.contains("results") == true
        }
    }
    
    var searchTemplate: String? {
        urls.first(where: { $0.isSearchTemplate })?.template
    }
}

// MARK: - Error Models

/// Represents catalog-specific errors
enum CatalogError: LocalizedError, Equatable {
    case invalidFeedType
    case parsingError(String)
    case networkError(String)
    case noSearchAvailable
    case invalidSearchTemplate
    
    var errorDescription: String? {
        switch self {
        case .invalidFeedType:
            return "Invalid catalog feed type"
        case .parsingError(let message):
            return "Failed to parse catalog: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .noSearchAvailable:
            return "Search is not available for this catalog"
        case .invalidSearchTemplate:
            return "Invalid search template"
        }
    }
} 