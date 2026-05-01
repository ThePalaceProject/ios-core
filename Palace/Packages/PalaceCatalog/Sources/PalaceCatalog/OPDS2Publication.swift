//
//  OPDS2Publication.swift
//  The Palace Project
//
//  Created by Benjamin Anderman on 5/10/19.
//  Copyright © 2019 NYPL Labs. All rights reserved.
//

import Foundation

public struct OPDS2Publication: Codable, Equatable, Sendable {
    public struct Metadata: Codable, Equatable, Sendable {
        public let updated: Date?
        public let description: String?
        public let id: String
        public let title: String
        public let author: [OPDS2Contributor]?
        public let narrator: [OPDS2Contributor]?

        private enum CodingKeys: String, CodingKey {
            case updated, description, id, title, author, narrator
            case atId = "@id"
            case identifier
        }

        public init(updated: Date? = nil, description: String? = nil, id: String, title: String, author: [OPDS2Contributor]? = nil, narrator: [OPDS2Contributor]? = nil) {
            self.updated = updated
            self.description = description
            self.id = id
            self.title = title
            self.author = author
            self.narrator = narrator
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            updated = try container.decodeIfPresent(Date.self, forKey: .updated)

            // CM feeds send `author` as either a JSON array or a single
            // object/string. Try array first, then fall back to a single
            // contributor so lean lane publications don't silently lose the
            // author name.
            if let list = try? container.decodeIfPresent([OPDS2Contributor].self, forKey: .author) {
                author = list
            } else if let single = try? container.decodeIfPresent(OPDS2Contributor.self, forKey: .author) {
                author = [single]
            } else {
                author = nil
            }

            // Narrator follows the same array-or-single shape — PP-4230
            // regression was that we never decoded this field at all on the
            // lightweight publication, so audiobook details lost the narrator
            // row whenever a feed served the lean publication shape.
            if let list = try? container.decodeIfPresent([OPDS2Contributor].self, forKey: .narrator) {
                narrator = list
            } else if let single = try? container.decodeIfPresent(OPDS2Contributor.self, forKey: .narrator) {
                narrator = [single]
            } else {
                narrator = nil
            }

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

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(updated, forKey: .updated)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(author, forKey: .author)
            try container.encodeIfPresent(narrator, forKey: .narrator)
        }
    }

    public let links: [OPDS2Link]
    public let metadata: Metadata
    public let images: [OPDS2Link]?

    public init(links: [OPDS2Link], metadata: Metadata, images: [OPDS2Link]? = nil) {
        self.links = links
        self.metadata = metadata
        self.images = images
    }
}

private let imageType = "image/png"

public extension OPDS2Publication {
    public var imageURL: URL? {
        guard let image = images?.first(where: { $0.type == imageType }) else {
            return nil
        }
        return URL(string: image.href)
    }

    public var thumbnailURL: URL? {
        guard let thumbnail = images?.first(where: { $0.type == imageType && ($0.rel ?? "").contains("thumbnail") }) else {
            return nil
        }
        return URL(string: thumbnail.href)
    }

    public var coverURL: URL? {
        guard let cover = images?.first(where: { $0.type == imageType && ($0.rel ?? "").contains("cover") }) else {
            return nil
        }
        return URL(string: cover.href)
    }
}
