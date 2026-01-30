//
//  OPDS2Link.swift
//  The Palace Project
//
//  Created by Benjamin Anderman on 5/10/19.
//  Copyright © 2019 NYPL Labs. All rights reserved.
//
//  Enhanced for OPDS2 modernization - 2026
//

import Foundation

// MARK: - OPDS2 Link

public struct OPDS2Link: Codable, Equatable, Sendable, Identifiable {
  public let href: String
  public let type: String?
  public let rel: String?
  public let templated: Bool?
  public let title: String?
  public let height: Int?
  public let width: Int?
  public let bitrate: Double?
  public let duration: Double?
  public let language: String?
  public let alternate: [OPDS2Link]?
  public let children: [OPDS2Link]?
  public let properties: OPDS2LinkProperties?
  
  // Legacy support
  public let displayNames: [OPDS2InternationalVariable]?
  public let descriptions: [OPDS2InternationalVariable]?
  
  // MARK: - Identifiable
  
  public var id: String { href }
  
  // MARK: - Computed Properties
  
  public var hrefURL: URL? {
    URL(string: href)
  }
  
  /// Check if this is an acquisition link
  public var isAcquisition: Bool {
    rel?.contains("acquisition") == true
  }
  
  /// Check if this is an open access link
  public var isOpenAccess: Bool {
    rel == "http://opds-spec.org/acquisition/open-access"
  }
  
  /// Check if this is a borrow link
  public var isBorrow: Bool {
    rel == "http://opds-spec.org/acquisition/borrow"
  }
  
  /// Check if this is a sample/preview link
  public var isSample: Bool {
    rel == "http://opds-spec.org/acquisition/sample" ||
    rel == "preview"
  }
  
  /// Check if this is an image link
  public var isImage: Bool {
    type?.hasPrefix("image/") == true ||
    rel?.contains("image") == true ||
    rel?.contains("thumbnail") == true ||
    rel?.contains("cover") == true
  }
  
  // MARK: - Initialization
  
  public init(
    href: String,
    type: String? = nil,
    rel: String? = nil,
    templated: Bool? = nil,
    title: String? = nil,
    height: Int? = nil,
    width: Int? = nil,
    bitrate: Double? = nil,
    duration: Double? = nil,
    language: String? = nil,
    alternate: [OPDS2Link]? = nil,
    children: [OPDS2Link]? = nil,
    properties: OPDS2LinkProperties? = nil,
    displayNames: [OPDS2InternationalVariable]? = nil,
    descriptions: [OPDS2InternationalVariable]? = nil
  ) {
    self.href = href
    self.type = type
    self.rel = rel
    self.templated = templated
    self.title = title
    self.height = height
    self.width = width
    self.bitrate = bitrate
    self.duration = duration
    self.language = language
    self.alternate = alternate
    self.children = children
    self.properties = properties
    self.displayNames = displayNames
    self.descriptions = descriptions
  }
}

// MARK: - Link Properties

public struct OPDS2LinkProperties: Codable, Equatable, Sendable {
  public let numberOfItems: Int?
  public let price: OPDS2Price?
  public let indirectAcquisition: [OPDS2IndirectAcquisition]?
  public let availability: OPDS2Availability?
  public let copies: OPDS2Copies?
  public let holds: OPDS2Holds?
  
  public init(
    numberOfItems: Int? = nil,
    price: OPDS2Price? = nil,
    indirectAcquisition: [OPDS2IndirectAcquisition]? = nil,
    availability: OPDS2Availability? = nil,
    copies: OPDS2Copies? = nil,
    holds: OPDS2Holds? = nil
  ) {
    self.numberOfItems = numberOfItems
    self.price = price
    self.indirectAcquisition = indirectAcquisition
    self.availability = availability
    self.copies = copies
    self.holds = holds
  }
}

// MARK: - Price

public struct OPDS2Price: Codable, Equatable, Sendable {
  public let currency: String
  public let value: Double
  
  public init(currency: String, value: Double) {
    self.currency = currency
    self.value = value
  }
}

// MARK: - Indirect Acquisition

public struct OPDS2IndirectAcquisition: Codable, Equatable, Sendable {
  public let type: String
  public let child: [OPDS2IndirectAcquisition]?
  
  public init(type: String, child: [OPDS2IndirectAcquisition]? = nil) {
    self.type = type
    self.child = child
  }
}

// MARK: - Availability

public struct OPDS2Availability: Codable, Equatable, Sendable {
  public let state: String
  public let since: Date?
  public let until: Date?
  
  public var isAvailable: Bool {
    state == "available"
  }
  
  public var isUnavailable: Bool {
    state == "unavailable"
  }
  
  public var isReserved: Bool {
    state == "reserved"
  }
  
  public var isReady: Bool {
    state == "ready"
  }
  
  public init(state: String, since: Date? = nil, until: Date? = nil) {
    self.state = state
    self.since = since
    self.until = until
  }
}

// MARK: - Copies

public struct OPDS2Copies: Codable, Equatable, Sendable {
  public let total: Int?
  public let available: Int?
  
  public init(total: Int? = nil, available: Int? = nil) {
    self.total = total
    self.available = available
  }
}

// MARK: - Holds

public struct OPDS2Holds: Codable, Equatable, Sendable {
  public let total: Int?
  public let position: Int?
  
  public init(total: Int? = nil, position: Int? = nil) {
    self.total = total
    self.position = position
  }
}

// MARK: - International Variable (Legacy Support)

public struct OPDS2InternationalVariable: Codable, Equatable, Sendable {
  public let language: String
  public let value: String
  
  public init(language: String, value: String) {
    self.language = language
    self.value = value
  }
}
