//
//  OPDS2PublicationExtended.swift
//  Palace
//
//  Extended OPDS2 Publication model with full book metadata
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

// MARK: - Extended Publication Metadata

extension OPDS2Publication {
  
  /// Convert OPDS2 Publication to TPPBook for compatibility
  /// This enables gradual migration while maintaining existing UI
  func toBook() -> TPPBook? {
    // Create a minimal TPPBook from OPDS2 data
    // This bridges OPDS2 to the existing book infrastructure
    
    guard let identifier = metadata.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
      return nil
    }
    
    // Find acquisition links
    let acquisitionLinks = links.filter { link in
      link.rel?.contains("acquisition") == true ||
      link.rel == "http://opds-spec.org/acquisition" ||
      link.rel == "http://opds-spec.org/acquisition/borrow" ||
      link.rel == "http://opds-spec.org/acquisition/open-access"
    }
    
    guard !acquisitionLinks.isEmpty else {
      return nil
    }
    
    // Build dictionary for TPPBook initialization
    var bookDict: [String: Any] = [
      "id": identifier,
      "title": metadata.title,
      "updated": ISO8601DateFormatter().string(from: metadata.updated)
    ]
    
    if let description = metadata.description {
      bookDict["summary"] = description
    }
    
    // Add images
    if let imageURL = coverURL ?? imageURL ?? thumbnailURL {
      bookDict["image"] = imageURL.absoluteString
    }
    
    if let thumbURL = thumbnailURL {
      bookDict["thumbnail"] = thumbURL.absoluteString
    }
    
    // Add acquisition links
    var acquisitionDicts: [[String: Any]] = []
    for link in acquisitionLinks {
      var acqDict: [String: Any] = [
        "href": link.href,
        "rel": link.rel ?? "http://opds-spec.org/acquisition"
      ]
      if let type = link.type {
        acqDict["type"] = type
      }
      acquisitionDicts.append(acqDict)
    }
    bookDict["links"] = acquisitionDicts
    
    // Try to create TPPBook - this requires bridging to ObjC
    // For now, return nil and use the OPDS2 publication directly
    // Full integration will be added when CatalogViewModel is updated
    return nil
  }
}

// MARK: - Full Publication Model

/// Complete OPDS2 Publication with all metadata fields
struct OPDS2FullPublication: Codable, Equatable, Sendable, Identifiable {
  public let metadata: OPDS2FullMetadata
  public let links: [OPDS2Link]
  public let images: [OPDS2Link]?
  
  public var id: String { metadata.identifier }
  
  // MARK: - Image URLs
  
  public var imageURL: URL? {
    images?.first { $0.rel == nil || $0.rel == "http://opds-spec.org/image" }?.hrefURL
  }
  
  public var thumbnailURL: URL? {
    images?.first { $0.rel?.contains("thumbnail") == true }?.hrefURL ??
    images?.first { $0.width != nil && $0.width! < 200 }?.hrefURL
  }
  
  public var coverURL: URL? {
    images?.first { $0.rel?.contains("cover") == true }?.hrefURL ??
    images?.first { $0.width != nil && $0.width! >= 200 }?.hrefURL
  }
  
  // MARK: - Acquisition Links
  
  public var acquisitionLinks: [OPDS2Link] {
    links.filter { link in
      link.rel?.contains("acquisition") == true
    }
  }
  
  public var borrowLink: OPDS2Link? {
    links.first { $0.rel == "http://opds-spec.org/acquisition/borrow" }
  }
  
  public var openAccessLink: OPDS2Link? {
    links.first { $0.rel == "http://opds-spec.org/acquisition/open-access" }
  }
  
  public var sampleLink: OPDS2Link? {
    links.first { $0.rel == "http://opds-spec.org/acquisition/sample" ||
                  $0.rel == "preview" }
  }
  
  // MARK: - Content Type
  
  public var isAudiobook: Bool {
    acquisitionLinks.contains { link in
      link.type?.contains("audiobook") == true
    }
  }
  
  public var isEPUB: Bool {
    acquisitionLinks.contains { link in
      link.type?.contains("epub") == true
    }
  }
  
  public var isPDF: Bool {
    acquisitionLinks.contains { link in
      link.type?.contains("pdf") == true
    }
  }
}

// MARK: - Full Metadata

struct OPDS2FullMetadata: Codable, Equatable, Sendable {
  public let identifier: String
  public let title: String
  public let sortAs: String?
  public let subtitle: String?
  public let modified: Date?
  public let published: Date?
  public let language: String?
  public let description: String?
  public let author: [OPDS2Contributor]?
  public let translator: [OPDS2Contributor]?
  public let editor: [OPDS2Contributor]?
  public let narrator: [OPDS2Contributor]?
  public let contributor: [OPDS2Contributor]?
  public let publisher: String?
  public let imprint: String?
  public let subject: [OPDS2Subject]?
  public let duration: Double?
  public let numberOfPages: Int?
  public let belongsTo: OPDS2BelongsTo?
  
  private enum CodingKeys: String, CodingKey {
    case identifier = "@id"
    case title
    case sortAs
    case subtitle
    case modified
    case published
    case language
    case description
    case author
    case translator
    case editor
    case narrator
    case contributor
    case publisher
    case imprint
    case subject
    case duration
    case numberOfPages
    case belongsTo
  }
  
  // Alternate decoding for different JSON structures
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    
    // Handle identifier with multiple possible keys
    if let id = try? container.decode(String.self, forKey: .identifier) {
      identifier = id
    } else if let altContainer = try? decoder.container(keyedBy: AlternateCodingKeys.self),
              let id = try? altContainer.decode(String.self, forKey: .id) {
      identifier = id
    } else {
      identifier = UUID().uuidString
    }
    
    title = try container.decode(String.self, forKey: .title)
    sortAs = try container.decodeIfPresent(String.self, forKey: .sortAs)
    subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    modified = try container.decodeIfPresent(Date.self, forKey: .modified)
    published = try container.decodeIfPresent(Date.self, forKey: .published)
    language = try container.decodeIfPresent(String.self, forKey: .language)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    author = try container.decodeIfPresent([OPDS2Contributor].self, forKey: .author)
    translator = try container.decodeIfPresent([OPDS2Contributor].self, forKey: .translator)
    editor = try container.decodeIfPresent([OPDS2Contributor].self, forKey: .editor)
    narrator = try container.decodeIfPresent([OPDS2Contributor].self, forKey: .narrator)
    contributor = try container.decodeIfPresent([OPDS2Contributor].self, forKey: .contributor)
    publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
    imprint = try container.decodeIfPresent(String.self, forKey: .imprint)
    subject = try container.decodeIfPresent([OPDS2Subject].self, forKey: .subject)
    duration = try container.decodeIfPresent(Double.self, forKey: .duration)
    numberOfPages = try container.decodeIfPresent(Int.self, forKey: .numberOfPages)
    belongsTo = try container.decodeIfPresent(OPDS2BelongsTo.self, forKey: .belongsTo)
  }
  
  private enum AlternateCodingKeys: String, CodingKey {
    case id
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(identifier, forKey: .identifier)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(sortAs, forKey: .sortAs)
    try container.encodeIfPresent(subtitle, forKey: .subtitle)
    try container.encodeIfPresent(modified, forKey: .modified)
    try container.encodeIfPresent(published, forKey: .published)
    try container.encodeIfPresent(language, forKey: .language)
    try container.encodeIfPresent(description, forKey: .description)
    try container.encodeIfPresent(author, forKey: .author)
    try container.encodeIfPresent(translator, forKey: .translator)
    try container.encodeIfPresent(editor, forKey: .editor)
    try container.encodeIfPresent(narrator, forKey: .narrator)
    try container.encodeIfPresent(contributor, forKey: .contributor)
    try container.encodeIfPresent(publisher, forKey: .publisher)
    try container.encodeIfPresent(imprint, forKey: .imprint)
    try container.encodeIfPresent(subject, forKey: .subject)
    try container.encodeIfPresent(duration, forKey: .duration)
    try container.encodeIfPresent(numberOfPages, forKey: .numberOfPages)
    try container.encodeIfPresent(belongsTo, forKey: .belongsTo)
  }
}

// MARK: - Contributor

struct OPDS2Contributor: Codable, Equatable, Sendable {
  public let name: String
  public let sortAs: String?
  public let identifier: String?
  public let links: [OPDS2Link]?
  
  public init(name: String, sortAs: String? = nil, identifier: String? = nil, links: [OPDS2Link]? = nil) {
    self.name = name
    self.sortAs = sortAs
    self.identifier = identifier
    self.links = links
  }
  
  // Handle both string and object representations
  public init(from decoder: Decoder) throws {
    if let container = try? decoder.singleValueContainer(),
       let nameString = try? container.decode(String.self) {
      name = nameString
      sortAs = nil
      identifier = nil
      links = nil
    } else {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      name = try container.decode(String.self, forKey: .name)
      sortAs = try container.decodeIfPresent(String.self, forKey: .sortAs)
      identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
      links = try container.decodeIfPresent([OPDS2Link].self, forKey: .links)
    }
  }
  
  private enum CodingKeys: String, CodingKey {
    case name, sortAs, identifier, links
  }
}

// MARK: - Subject

struct OPDS2Subject: Codable, Equatable, Sendable {
  public let name: String
  public let sortAs: String?
  public let scheme: String?
  public let code: String?
  
  public init(name: String, sortAs: String? = nil, scheme: String? = nil, code: String? = nil) {
    self.name = name
    self.sortAs = sortAs
    self.scheme = scheme
    self.code = code
  }
  
  // Handle both string and object representations
  public init(from decoder: Decoder) throws {
    if let container = try? decoder.singleValueContainer(),
       let nameString = try? container.decode(String.self) {
      name = nameString
      sortAs = nil
      scheme = nil
      code = nil
    } else {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      name = try container.decode(String.self, forKey: .name)
      sortAs = try container.decodeIfPresent(String.self, forKey: .sortAs)
      scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
      code = try container.decodeIfPresent(String.self, forKey: .code)
    }
  }
  
  private enum CodingKeys: String, CodingKey {
    case name, sortAs, scheme, code
  }
}

// MARK: - BelongsTo (Series/Collection)

struct OPDS2BelongsTo: Codable, Equatable, Sendable {
  public let series: [OPDS2Collection]?
  public let collection: [OPDS2Collection]?
  
  public init(series: [OPDS2Collection]? = nil, collection: [OPDS2Collection]? = nil) {
    self.series = series
    self.collection = collection
  }
}

struct OPDS2Collection: Codable, Equatable, Sendable {
  public let name: String
  public let sortAs: String?
  public let identifier: String?
  public let position: Double?
  public let links: [OPDS2Link]?
  
  public init(
    name: String,
    sortAs: String? = nil,
    identifier: String? = nil,
    position: Double? = nil,
    links: [OPDS2Link]? = nil
  ) {
    self.name = name
    self.sortAs = sortAs
    self.identifier = identifier
    self.position = position
    self.links = links
  }
}
