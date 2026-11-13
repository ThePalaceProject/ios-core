//
//  TPPLCPLicense.swift
//  Palace
//
//  Created by Vladimir Fedorov on 01.11.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

#if LCP

import Foundation
import PalaceNetwork
import ReadiumShared

struct TPPLCPLicenseLink: Codable {
    let rel: String?
    let href: String?
    let type: String?
    let title: String?
    let length: Int?
    let hash: String?
}

enum TPPLCPLicenseRel: String {
    case publication
}

// TODO: Convert to Codable struct once TPPMyBookDownloadCenter is rewritten in Swift.

/// LCP License representation.
/// This class is used to get license identifier to use after fulfillment is done.
@objc class TPPLCPLicense: NSObject, Codable {
    /// License ID
    private var id: String

    let links: [TPPLCPLicenseLink]

    /// When the licence was issued; nil when the field is absent or unreadable.
    /// Lenient on purpose: an open or fulfilment that reads a licence must not
    /// start failing over a field only PP-5440 uses.
    let issued: Date?

    private enum CodingKeys: String, CodingKey {
        case id, links, issued
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        links = try container.decode([TPPLCPLicenseLink].self, forKey: .links)
        let issuedString = (try? container.decodeIfPresent(String.self, forKey: .issued)) ?? nil
        issued = issuedString.flatMap(Self.date(fromISO8601:))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(links, forKey: .links)
    }

    private static func date(fromISO8601 string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Objective-C visible identifier
    @objc var identifier: String {
        id
    }

    /// Initializes with license URL
    @objc init?(url: URL) {
        if let data = try? Data(contentsOf: url),
           let license = try? JSONDecoder().decodeGuarded(TPPLCPLicense.self, from: data) {
            self.id = license.id
            self.links = license.links
            self.issued = license.issued
        } else {
            return nil
        }
    }

    /// Returns first link with the specified `rel`.
    /// - Parameter rel: `rel` value.
    /// - Returns: First link, if available, `nil` if no link with the provided `rel` found.
    func firstLink(withRel rel: TPPLCPLicenseRel) -> TPPLCPLicenseLink? {
        links.filter({ $0.rel == rel.rawValue }).first
    }
}

#endif
