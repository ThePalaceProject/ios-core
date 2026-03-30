//
//  OPDS2Publication.swift
//  The Palace Project
//
//  Created by Benjamin Anderman on 5/10/19.
//  Copyright © 2019 NYPL Labs. All rights reserved.
//

import Foundation

struct OPDS2Publication: Codable, Equatable, Sendable {
    struct Metadata: Codable, Equatable, Sendable {
        let updated: Date?
        let description: String?
        let id: String
        let title: String

        private enum CodingKeys: String, CodingKey {
            case updated, description, id, title
            case atId = "@id"
            case identifier
        }

        init(updated: Date? = nil, description: String? = nil, id: String, title: String) {
            self.updated = updated
            self.description = description
            self.id = id
            self.title = title
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            updated = try container.decodeIfPresent(Date.self, forKey: .updated)

            // id can come as "id", "@id", or "identifier"
            if let val = try? container.decode(String.self, forKey: .id) {
                id = val
            } else if let val = try? container.decode(String.self, forKey: .atId) {
                id = val
            } else if let val = try? container.decode(String.self, forKey: .identifier) {
                id = val
            } else {
                id = UUID().uuidString
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(updated, forKey: .updated)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }

    let links: [OPDS2Link]
    let metadata: Metadata
    let images: [OPDS2Link]?
}

private let imageType = "image/png"

extension OPDS2Publication {
    var imageURL: URL? {
        guard let image = images?.first(where: { $0.type == imageType }) else {
            return nil
        }
        return URL(string: image.href)
    }

    var thumbnailURL: URL? {
        guard let thumbnail = images?.first(where: { $0.type == imageType && ($0.rel ?? "").contains("thumbnail") }) else {
            return nil
        }
        return URL(string: thumbnail.href)
    }

    var coverURL: URL? {
        guard let cover = images?.first(where: { $0.type == imageType && ($0.rel ?? "").contains("cover") }) else {
            return nil
        }
        return URL(string: cover.href)
    }
}
