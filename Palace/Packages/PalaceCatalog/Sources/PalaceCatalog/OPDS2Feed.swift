//
//  OPDS2Feed.swift
//  Palace
//
//  Created for Palace Project modernization.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - OPDS2 Feed Model

/// Complete OPDS 2.0 Feed representation
/// Supports both catalog feeds and publication feeds with full navigation
public struct OPDS2Feed: Codable, Equatable, Sendable {

    // MARK: - Core Properties

    public let metadata: OPDS2FeedMetadata
    public let links: [OPDS2Link]?
    public let publications: [OPDS2Publication]?
    public let navigation: [OPDS2NavigationLink]?
    public let groups: [OPDS2Group]?
    public let facets: [OPDS2FacetGroup]?

    // MARK: - Computed Properties

    public var title: String { metadata.title }
    public var id: String? { metadata.identifier }

    /// URL for the next page of results
    public var nextPageURL: URL? {
        links?.first { $0.rel == "next" }?.hrefURL
    }

    /// URL for the previous page
    public var previousPageURL: URL? {
        links?.first { $0.rel == "previous" }?.hrefURL
    }

    /// URL for search
    public var searchURL: URL? {
        links?.first { $0.rel == "search" }?.hrefURL
    }

    /// Self URL
    public var selfURL: URL? {
        links?.first { $0.rel == "self" }?.hrefURL
    }

    /// Start URL (root of catalog)
    public var startURL: URL? {
        links?.first { $0.rel == "start" }?.hrefURL
    }

    // MARK: - Feed Type Detection

    public var isNavigationFeed: Bool {
        navigation != nil && !navigation!.isEmpty
    }

    public var isPublicationFeed: Bool {
        publications != nil && !publications!.isEmpty
    }

    public var isGroupedFeed: Bool {
        groups != nil && !groups!.isEmpty
    }

    // MARK: - Initialization

    public init(
        metadata: OPDS2FeedMetadata,
        links: [OPDS2Link]? = nil,
        publications: [OPDS2Publication]? = nil,
        navigation: [OPDS2NavigationLink]? = nil,
        groups: [OPDS2Group]? = nil,
        facets: [OPDS2FacetGroup]? = nil
    ) {
        self.metadata = metadata
        self.links = links
        self.publications = publications
        self.navigation = navigation
        self.groups = groups
        self.facets = facets
    }
}

// MARK: - Feed Metadata

public struct OPDS2FeedMetadata: Codable, Equatable, Sendable {
    public let title: String
    public let identifier: String?
    public let subtitle: String?
    public let modified: Date?
    public let description: String?
    public let numberOfItems: Int?
    public let itemsPerPage: Int?
    public let currentPage: Int?

    private enum CodingKeys: String, CodingKey {
        case title
        case identifier
        case subtitle
        case modified
        case description
        case numberOfItems
        case itemsPerPage
        case currentPage
    }

    public init(
        title: String,
        identifier: String? = nil,
        subtitle: String? = nil,
        modified: Date? = nil,
        description: String? = nil,
        numberOfItems: Int? = nil,
        itemsPerPage: Int? = nil,
        currentPage: Int? = nil
    ) {
        self.title = title
        self.identifier = identifier
        self.subtitle = subtitle
        self.modified = modified
        self.description = description
        self.numberOfItems = numberOfItems
        self.itemsPerPage = itemsPerPage
        self.currentPage = currentPage
    }
}

// MARK: - Navigation Link

public struct OPDS2NavigationLink: Codable, Equatable, Sendable, Identifiable {
    public let href: String
    public let title: String
    public let rel: String?
    public let type: String?

    public var id: String { href }

    public var hrefURL: URL? {
        URL(string: href)
    }

    public init(href: String, title: String, rel: String? = nil, type: String? = nil) {
        self.href = href
        self.title = title
        self.rel = rel
        self.type = type
    }
}

// MARK: - Group (for grouped feeds)

public struct OPDS2Group: Codable, Equatable, Sendable, Identifiable {
    public let metadata: OPDS2GroupMetadata
    public let links: [OPDS2Link]?
    public let publications: [OPDS2Publication]?
    public let navigation: [OPDS2NavigationLink]?

    public var id: String { metadata.title }
    public var title: String { metadata.title }

    /// URL for "more" items in this group
    public var moreURL: URL? {
        links?.first { $0.rel == "self" || $0.rel == "subsection" }?.hrefURL
    }

    public init(
        metadata: OPDS2GroupMetadata,
        links: [OPDS2Link]? = nil,
        publications: [OPDS2Publication]? = nil,
        navigation: [OPDS2NavigationLink]? = nil
    ) {
        self.metadata = metadata
        self.links = links
        self.publications = publications
        self.navigation = navigation
    }
}

public struct OPDS2GroupMetadata: Codable, Equatable, Sendable {
    public let title: String
    public let numberOfItems: Int?

    public init(title: String, numberOfItems: Int? = nil) {
        self.title = title
        self.numberOfItems = numberOfItems
    }
}

// MARK: - Facet Group

public struct OPDS2FacetGroup: Codable, Equatable, Sendable, Identifiable {
    public let metadata: OPDS2FacetGroupMetadata
    public let links: [OPDS2FacetLink]

    public var id: String { metadata.title }
    public var title: String { metadata.title }

    public init(metadata: OPDS2FacetGroupMetadata, links: [OPDS2FacetLink]) {
        self.metadata = metadata
        self.links = links
    }
}

public struct OPDS2FacetGroupMetadata: Codable, Equatable, Sendable {
    public let title: String
    /// Facet group type URI (e.g. "http://palaceproject.io/terms/rel/sort")
    /// Encoded as `@type` in the JSON response from the registry.
    public let type: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case type
        case atType = "@type"
    }

    public init(title: String, type: String? = nil) {
        self.title = title
        self.type = type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        // Try "type" first, then "@type"
        type = try container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .atType)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(type, forKey: .type)
    }
}

public struct OPDS2FacetLink: Codable, Equatable, Sendable, Identifiable {
    public let href: String
    public let title: String
    public let rel: String?
    public let type: String?
    public let properties: OPDS2FacetProperties?

    public var id: String { href }

    public var hrefURL: URL? {
        URL(string: href)
    }

    public var isActive: Bool {
        properties?.numberOfItems != nil
    }

    public init(
        href: String,
        title: String,
        rel: String? = nil,
        type: String? = nil,
        properties: OPDS2FacetProperties? = nil
    ) {
        self.href = href
        self.title = title
        self.rel = rel
        self.type = type
        self.properties = properties
    }
}

public struct OPDS2FacetProperties: Codable, Equatable, Sendable {
    public let numberOfItems: Int?

    public init(numberOfItems: Int? = nil) {
        self.numberOfItems = numberOfItems
    }
}

// MARK: - JSON Decoder Configuration

public extension OPDS2Feed {

    /// Creates a JSONDecoder configured for OPDS 2.0 date formats
    static public func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()

        // OPDS 2.0 uses ISO 8601 dates
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try with fractional seconds first
            if let date = formatter.date(from: dateString) {
                return date
            }

            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }

            // Try RFC 3339 format
            let rfc3339Formatter = DateFormatter()
            rfc3339Formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            rfc3339Formatter.locale = Locale(identifier: "en_US_POSIX")
            rfc3339Formatter.timeZone = TimeZone(secondsFromGMT: 0)

            if let date = rfc3339Formatter.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date string \(dateString)"
            )
        }

        return decoder
    }

    /// Parse OPDS2 feed from JSON data
    static public func from(data: Data) throws -> OPDS2Feed {
        try makeDecoder().decode(OPDS2Feed.self, from: data)
    }
}
