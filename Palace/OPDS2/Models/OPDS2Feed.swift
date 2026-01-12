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
struct OPDS2Feed: Codable, Equatable, Sendable {
  
  // MARK: - Core Properties
  
  let metadata: OPDS2FeedMetadata
  let links: [OPDS2Link]
  let publications: [OPDS2Publication]?
  let navigation: [OPDS2NavigationLink]?
  let groups: [OPDS2Group]?
  let facets: [OPDS2FacetGroup]?
  
  // MARK: - Computed Properties
  
  var title: String { metadata.title }
  var id: String? { metadata.identifier }
  
  /// URL for the next page of results
  var nextPageURL: URL? {
    links.first { $0.rel == "next" }?.hrefURL
  }
  
  /// URL for the previous page
  var previousPageURL: URL? {
    links.first { $0.rel == "previous" }?.hrefURL
  }
  
  /// URL for search
  var searchURL: URL? {
    links.first { $0.rel == "search" }?.hrefURL
  }
  
  /// Self URL
  var selfURL: URL? {
    links.first { $0.rel == "self" }?.hrefURL
  }
  
  /// Start URL (root of catalog)
  var startURL: URL? {
    links.first { $0.rel == "start" }?.hrefURL
  }
  
  // MARK: - Feed Type Detection
  
  var isNavigationFeed: Bool {
    navigation != nil && !navigation!.isEmpty
  }
  
  var isPublicationFeed: Bool {
    publications != nil && !publications!.isEmpty
  }
  
  var isGroupedFeed: Bool {
    groups != nil && !groups!.isEmpty
  }
  
  // MARK: - Initialization
  
  init(
    metadata: OPDS2FeedMetadata,
    links: [OPDS2Link],
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

struct OPDS2FeedMetadata: Codable, Equatable, Sendable {
  let title: String
  let identifier: String?
  let subtitle: String?
  let modified: Date?
  let description: String?
  let numberOfItems: Int?
  let itemsPerPage: Int?
  let currentPage: Int?
  
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
  
  init(
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

struct OPDS2NavigationLink: Codable, Equatable, Sendable, Identifiable {
  let href: String
  let title: String
  let rel: String?
  let type: String?
  
  var id: String { href }
  
  var hrefURL: URL? {
    URL(string: href)
  }
  
  init(href: String, title: String, rel: String? = nil, type: String? = nil) {
    self.href = href
    self.title = title
    self.rel = rel
    self.type = type
  }
}

// MARK: - Group (for grouped feeds)

struct OPDS2Group: Codable, Equatable, Sendable, Identifiable {
  let metadata: OPDS2GroupMetadata
  let links: [OPDS2Link]?
  let publications: [OPDS2Publication]?
  let navigation: [OPDS2NavigationLink]?
  
  var id: String { metadata.title }
  var title: String { metadata.title }
  
  /// URL for "more" items in this group
  var moreURL: URL? {
    links?.first { $0.rel == "self" || $0.rel == "subsection" }?.hrefURL
  }
  
  init(
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

struct OPDS2GroupMetadata: Codable, Equatable, Sendable {
  let title: String
  let numberOfItems: Int?
  
  init(title: String, numberOfItems: Int? = nil) {
    self.title = title
    self.numberOfItems = numberOfItems
  }
}

// MARK: - Facet Group

struct OPDS2FacetGroup: Codable, Equatable, Sendable, Identifiable {
  let metadata: OPDS2FacetGroupMetadata
  let links: [OPDS2FacetLink]
  
  var id: String { metadata.title }
  var title: String { metadata.title }
  
  init(metadata: OPDS2FacetGroupMetadata, links: [OPDS2FacetLink]) {
    self.metadata = metadata
    self.links = links
  }
}

struct OPDS2FacetGroupMetadata: Codable, Equatable, Sendable {
  let title: String
  
  init(title: String) {
    self.title = title
  }
}

struct OPDS2FacetLink: Codable, Equatable, Sendable, Identifiable {
  let href: String
  let title: String
  let rel: String?
  let type: String?
  let properties: OPDS2FacetProperties?
  
  var id: String { href }
  
  var hrefURL: URL? {
    URL(string: href)
  }
  
  var isActive: Bool {
    properties?.numberOfItems != nil
  }
  
  init(
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

struct OPDS2FacetProperties: Codable, Equatable, Sendable {
  let numberOfItems: Int?
  
  init(numberOfItems: Int? = nil) {
    self.numberOfItems = numberOfItems
  }
}

// MARK: - JSON Decoder Configuration

extension OPDS2Feed {
  
  /// Creates a JSONDecoder configured for OPDS 2.0 date formats
  static func makeDecoder() -> JSONDecoder {
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
  static func from(data: Data) throws -> OPDS2Feed {
    try makeDecoder().decode(OPDS2Feed.self, from: data)
  }
}
