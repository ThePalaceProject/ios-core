//
//  OPDS2CatalogsFeed.swift
//  The Palace Project
//
//  Created by Benjamin Anderman on 5/10/19.
//  Copyright © 2019 NYPL Labs. All rights reserved.
//

import Foundation

public struct OPDS2CatalogsFeed: Codable, Sendable {
    public struct Metadata: Codable, Sendable {
        public let adobe_vendor_id: String?
        public let title: String
        /// Total number of items across all pages (from crawlable endpoint)
        public let numberOfItems: Int?

        public init(adobe_vendor_id: String?, title: String, numberOfItems: Int? = nil) {
            self.adobe_vendor_id = adobe_vendor_id
            self.title = title
            self.numberOfItems = numberOfItems
        }
    }

    public let catalogs: [OPDS2Publication]
    public let links: [OPDS2Link]
    public let metadata: Metadata
    public let facets: [OPDS2FacetGroup]?

    public init(
        catalogs: [OPDS2Publication],
        links: [OPDS2Link],
        metadata: Metadata,
        facets: [OPDS2FacetGroup]?
    ) {
        self.catalogs = catalogs
        self.links = links
        self.metadata = metadata
        self.facets = facets
    }

    /// URL for the next page of results (pagination)
    public var nextPageURL: URL? {
        links.first { $0.rel == "next" }?.hrefURL
    }

    /// Formatters for `updated` dates, built once and never mutated afterwards.
    /// Apple's DateFormatter reference ("Thread Safety") documents it as
    /// thread-safe on iOS 7+ and 64-bit macOS 10.9+, so concurrent decodes can
    /// share them. Registry dates are whole seconds, so the plain format goes first.
    private static let plainDateFormatter = makeDateFormatter("yyyy-MM-dd'T'HH:mm:ssXXXXX")
    private static let fractionalDateFormatter = makeDateFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX")

    private static func makeDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    /// Parses a registry `updated` value. A string that matches the plain
    /// format never matches the fractional one, so the order does not change
    /// any result (pinned by OPDS2CatalogsFeedDateDecodingTests).
    private static func parseDate(_ dateStr: String) -> Date? {
        plainDateFormatter.date(from: dateStr) ?? fractionalDateFormatter.date(from: dateStr)
    }

    static public func fromData(_ data: Data) throws -> OPDS2CatalogsFeed {
        enum DateError: String, Error {
            case invalidDate
        }

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .custom({ (decoder) -> Date in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            guard let date = parseDate(dateStr) else {
                throw DateError.invalidDate
            }
            return date
        })

        return try jsonDecoder.decode(OPDS2CatalogsFeed.self, from: data)
    }
}
