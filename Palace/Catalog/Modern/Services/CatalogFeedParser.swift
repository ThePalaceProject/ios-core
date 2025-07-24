//
//  CatalogFeedParser.swift
//  Palace
//
//  Created by Palace Modernization on Catalog Renovation
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Modern parser for OPDS feeds
actor CatalogFeedParser {
    
    // MARK: - Public Methods
    
    /// Parse OPDS feed data into modern CatalogFeed model
    static func parse(data: Data) async throws -> CatalogFeed {
        let parser = CatalogFeedParser()
        return try await parser.parseInternal(data: data)
    }
    
    // MARK: - Private Implementation
    
    private func parseInternal(data: Data) throws -> CatalogFeed {
        // First, try to parse using existing TPPXML and TPPOPDSFeed
        guard let xml = TPPXML(data: data) else {
            throw CatalogError.parsingError("Invalid XML data")
        }
        
        guard let opdsFeed = TPPOPDSFeed(xml: xml) else {
            throw CatalogError.parsingError("Invalid OPDS feed")
        }
        
        // Convert legacy model to modern model
        return try convertLegacyFeed(opdsFeed)
    }
    
    private func convertLegacyFeed(_ legacy: TPPOPDSFeed) throws -> CatalogFeed {
        let feedType = convertFeedType(legacy.type)
        
        let links = legacy.links.compactMap { link in
            convertLegacyLink(link)
        }
        
        let entries = legacy.entries.compactMap { entry in
            convertLegacyEntry(entry)
        }
        
        // Extract URLs from links
        let searchURL = links.first { $0.rel == "search" }?.href
        let nextURL = links.first { $0.rel == "next" }?.href
        let previousURL = links.first { $0.rel == "previous" }?.href
        let selfURL = links.first { $0.rel == "self" }?.href
        
        // Convert facets and entry points based on feed type
        let (facetGroups, entryPoints) = extractFacetsAndEntryPoints(from: legacy)
        
        return CatalogFeed(
            id: legacy.identifier ?? UUID().uuidString,
            title: legacy.title ?? "Catalog",
            subtitle: nil, // Legacy feed doesn't have subtitle
            type: feedType,
            links: links,
            entries: entries,
            facetGroups: facetGroups,
            entryPoints: entryPoints,
            searchURL: searchURL,
            nextURL: nextURL,
            previousURL: previousURL,
            selfURL: selfURL,
            updated: legacy.updated
        )
    }
    
    private func convertFeedType(_ legacyType: TPPOPDSFeedType) -> CatalogFeed.FeedType {
        switch legacyType {
        case .acquisitionGrouped:
            return .acquisitionGrouped
        case .acquisitionUngrouped:
            return .acquisitionUngrouped
        case .navigation:
            return .navigation
        case .invalid:
            return .invalid
        @unknown default:
            return .invalid
        }
    }
    
    private func convertLegacyLink(_ legacy: TPPOPDSLink) -> CatalogLink? {
        guard let href = legacy.href else { return nil }
        
        return CatalogLink(
            href: href,
            rel: legacy.rel,
            type: legacy.type,
            title: legacy.title,
            templated: nil // Legacy doesn't track this
        )
    }
    
    private func convertLegacyEntry(_ legacy: TPPOPDSEntry) -> CatalogEntry? {
        let links = legacy.links.compactMap { convertLegacyLink($0) }
        
        let categories = legacy.categories.map { category in
            CatalogCategory(
                term: category.term ?? "",
                label: category.label,
                scheme: category.scheme
            )
        }
        
        let authors = legacy.authors.map { author in
            CatalogAuthor(
                name: author.name ?? "",
                uri: author.uri
            )
        }
        
        return CatalogEntry(
            id: legacy.identifier ?? UUID().uuidString,
            title: legacy.title ?? "",
            summary: legacy.summary,
            content: legacy.content,
            updated: legacy.updated,
            published: legacy.published,
            links: links,
            categories: categories,
            authors: authors
        )
    }
    
    private func extractFacetsAndEntryPoints(from legacy: TPPOPDSFeed) -> ([CatalogFacetGroup], [CatalogFacet]) {
        var facetGroups: [CatalogFacetGroup] = []
        var entryPoints: [CatalogFacet] = []
        
        // For grouped feeds, extract entry points from entries
        if legacy.type == .acquisitionGrouped {
            // Convert legacy grouped feed to lanes and extract entry points
            if let groupedFeed = TPPCatalogGroupedFeed(opdsFeed: legacy) {
                entryPoints = groupedFeed.entryPoints.compactMap { legacyFacet in
                    convertLegacyFacet(legacyFacet)
                }
            }
        }
        
        // For ungrouped feeds, extract facet groups
        if legacy.type == .acquisitionUngrouped {
            if let ungroupedFeed = TPPCatalogUngroupedFeed(opdsFeed: legacy) {
                facetGroups = ungroupedFeed.facetGroups.compactMap { legacyGroup in
                    convertLegacyFacetGroup(legacyGroup)
                }
                
                entryPoints = ungroupedFeed.entryPoints.compactMap { legacyFacet in
                    convertLegacyFacet(legacyFacet)
                }
            }
        }
        
        return (facetGroups, entryPoints)
    }
    
    private func convertLegacyFacet(_ legacy: TPPCatalogFacet) -> CatalogFacet? {
        return CatalogFacet(
            id: legacy.href?.absoluteString ?? UUID().uuidString,
            label: legacy.title ?? "",
            href: legacy.href,
            isActive: legacy.isActive,
            count: nil // Legacy doesn't track count
        )
    }
    
    private func convertLegacyFacetGroup(_ legacy: TPPCatalogFacetGroup) -> CatalogFacetGroup? {
        let facets = legacy.facets.compactMap { convertLegacyFacet($0) }
        
        return CatalogFacetGroup(
            id: legacy.name ?? UUID().uuidString,
            label: legacy.name ?? "",
            facets: facets
        )
    }
}

// MARK: - OpenSearch Parser

extension CatalogFeedParser {
    
    /// Parse OpenSearch description XML
    static func parseOpenSearchDescription(data: Data) async throws -> OpenSearchDescription {
        let parser = CatalogFeedParser()
        return try await parser.parseOpenSearchInternal(data: data)
    }
    
    private func parseOpenSearchInternal(data: Data) throws -> OpenSearchDescription {
        // Use legacy parser for now, then convert
        var description: OpenSearchDescription?
        
        TPPOpenSearchDescription.withData(data) { legacyDescription in
            if let legacy = legacyDescription {
                description = self.convertLegacyOpenSearchDescription(legacy)
            }
        }
        
        guard let result = description else {
            throw CatalogError.parsingError("Failed to parse OpenSearch description")
        }
        
        return result
    }
    
    private func convertLegacyOpenSearchDescription(_ legacy: TPPOpenSearchDescription) -> OpenSearchDescription {
        let urls = [
            OpenSearchDescription.OpenSearchURL(
                template: legacy.searchTemplate,
                type: "application/atom+xml",
                rel: "results"
            )
        ]
        
        return OpenSearchDescription(
            shortName: "Search",
            description: "Search catalog",
            urls: urls,
            contact: nil,
            tags: nil,
            longName: nil
        )
    }
} 