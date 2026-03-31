//
//  OPDS2PublicationExtended.swift
//  Palace
//
//  Extended OPDS2 Publication model with full book metadata
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

// MARK: - OPDS2 → TPPBook Bridge Utilities

/// Shared bridge logic for converting OPDS2 links to TPPOPDSAcquisition objects
enum OPDS2BookBridge {

    /// OPDS acquisition relation URL prefix
    private static let acquisitionPrefix = "http://opds-spec.org/acquisition"

    /// Map an OPDS2 rel string to TPPOPDSAcquisitionRelation
    static func relation(from rel: String?) -> TPPOPDSAcquisitionRelation? {
        switch rel {
        case "http://opds-spec.org/acquisition":
            return .generic
        case "http://opds-spec.org/acquisition/open-access":
            return .openAccess
        case "http://opds-spec.org/acquisition/borrow":
            return .borrow
        case "http://opds-spec.org/acquisition/buy":
            return .buy
        case "http://opds-spec.org/acquisition/sample":
            return .sample
        case "http://opds-spec.org/acquisition/subscribe":
            return .subscribe
        case "preview":
            return .sample
        default:
            // Check if it's any other acquisition rel (but not revoke/issues)
            if let rel = rel, rel.hasPrefix(acquisitionPrefix),
               !rel.contains("revoke"), !rel.contains("issues") {
                return .generic
            }
            return nil
        }
    }

    /// Convert OPDS2 indirect acquisitions to TPPOPDSIndirectAcquisition objects
    static func convertIndirectAcquisitions(_ opds2: [OPDS2IndirectAcquisition]?) -> [TPPOPDSIndirectAcquisition] {
        guard let opds2 = opds2 else { return [] }
        return opds2.map { indirect in
            TPPOPDSIndirectAcquisition(
                type: indirect.type,
                indirectAcquisitions: convertIndirectAcquisitions(indirect.child)
            )
        }
    }

    /// Convert OPDS2 availability + copies + holds into a TPPOPDSAcquisitionAvailability
    static func convertAvailability(
        availability: OPDS2Availability?,
        copies: OPDS2Copies?,
        holds: OPDS2Holds?
    ) -> any TPPOPDSAcquisitionAvailability {
        guard let availability = availability else {
            return TPPOPDSAcquisitionAvailabilityUnlimited()
        }

        switch availability.state {
        case "unavailable":
            return TPPOPDSAcquisitionAvailabilityUnavailable(
                copiesHeld: UInt(holds?.total ?? 0),
                copiesTotal: UInt(copies?.total ?? 0)
            )

        case "available":
            if let copies = copies {
                return TPPOPDSAcquisitionAvailabilityLimited(
                    copiesAvailable: UInt(copies.available ?? 0),
                    copiesTotal: UInt(copies.total ?? 0),
                    since: availability.since,
                    until: availability.until
                )
            }
            return TPPOPDSAcquisitionAvailabilityUnlimited()

        case "reserved":
            return TPPOPDSAcquisitionAvailabilityReserved(
                holdPosition: UInt(max(holds?.position ?? 1, 1)),
                copiesTotal: UInt(copies?.total ?? 0),
                since: availability.since,
                until: availability.until
            )

        case "ready":
            return TPPOPDSAcquisitionAvailabilityReady(
                since: availability.since,
                until: availability.until
            )

        default:
            Log.warn(#file, "Unknown OPDS2 availability state: \(availability.state)")
            return TPPOPDSAcquisitionAvailabilityUnlimited()
        }
    }

    /// Convert an OPDS2Link to a TPPOPDSAcquisition if it is an acquisition link
    static func convertAcquisition(from link: OPDS2Link) -> TPPOPDSAcquisition? {
        guard let rel = relation(from: link.rel) else { return nil }
        guard let url = link.hrefURL else {
            Log.warn(#file, "OPDS2 acquisition link has invalid href: \(link.href)")
            return nil
        }

        let type = link.type ?? "application/octet-stream"
        let indirectAcqs = convertIndirectAcquisitions(link.properties?.indirectAcquisition)
        let availability = convertAvailability(
            availability: link.properties?.availability,
            copies: link.properties?.copies,
            holds: link.properties?.holds
        )

        return TPPOPDSAcquisition(
            relation: rel,
            type: type,
            hrefURL: url,
            indirectAcquisitions: indirectAcqs,
            availability: availability
        )
    }

    /// Extract image URLs from OPDS2 images array
    static func extractImageURLs(from images: [OPDS2Link]?) -> (image: URL?, thumbnail: URL?) {
        guard let images = images else { return (nil, nil) }

        let imageURL = images.first { $0.rel == "http://opds-spec.org/image" }?.hrefURL
            ?? images.first { $0.rel == nil || $0.rel?.isEmpty == true }?.hrefURL
            ?? images.first?.hrefURL

        let thumbnailURL = images.first { $0.rel == "http://opds-spec.org/image/thumbnail" }?.hrefURL
            ?? images.first {
                $0.rel?.contains("thumbnail") == true
            }?.hrefURL

        return (imageURL, thumbnailURL)
    }

    /// Extract special (non-acquisition) links from an OPDS2 link array
    static func extractSpecialLinks(from links: [OPDS2Link]) -> (
        alternate: URL?,
        related: URL?,
        revoke: URL?,
        report: URL?,
        annotations: URL?,
        analytics: URL?,
        timeTracking: URL?
    ) {
        var alternate: URL?
        var related: URL?
        var revoke: URL?
        var report: URL?
        var annotations: URL?
        var analytics: URL?
        var timeTracking: URL?

        for link in links {
            switch link.rel {
            case "alternate":
                alternate = link.hrefURL
            case "related":
                related = link.hrefURL
            case "http://opds-spec.org/acquisition/revoke":
                revoke = link.hrefURL
            case "issues", "http://opds-spec.org/acquisition/issues":
                report = link.hrefURL
            case "http://www.w3.org/ns/oa#annotationService":
                annotations = link.hrefURL
            case "http://palaceproject.io/terms/timeTracking":
                timeTracking = link.hrefURL
            default:
                break
            }
        }

        // Analytics URL derived from alternate link (matching OPDS1 behavior)
        if let alt = alternate {
            analytics = alt
        }

        return (alternate, related, revoke, report, annotations, analytics, timeTracking)
    }
}

// MARK: - OPDS2Publication → TPPBook

extension OPDS2Publication {

    /// Convert OPDS2 Publication to TPPBook for compatibility
    /// This bridges OPDS2 to the existing book infrastructure
    func toBook() -> TPPBook? {
        let identifier = metadata.id

        // Convert acquisition links
        var acquisitions: [TPPOPDSAcquisition] = []
        var previewAcquisition: TPPOPDSAcquisition?

        for link in links {
            if link.rel == "preview" || link.rel == "http://opds-spec.org/acquisition/sample" {
                if let acq = OPDS2BookBridge.convertAcquisition(from: link) {
                    previewAcquisition = acq
                    // Also include samples in main acquisitions
                    if link.rel != "preview" {
                        acquisitions.append(acq)
                    }
                }
            } else if let acq = OPDS2BookBridge.convertAcquisition(from: link) {
                acquisitions.append(acq)
            }
        }

        guard !acquisitions.isEmpty else {
            Log.info(#file, "[OPDS2-DIAG] Publication '\(metadata.title)' (\(identifier)) — no acquisition links, skipping")
            return nil
        }

        Log.info(#file, "[OPDS2-DIAG] Converting publication '\(metadata.title)' (\(identifier)) — " +
            "\(acquisitions.count) acquisitions, " +
            "relations=[\(acquisitions.map { NYPLOPDSAcquisitionRelationString($0.relation) }.joined(separator: ", "))]")

        // Extract images
        let imageURLs = OPDS2BookBridge.extractImageURLs(from: images)

        // Extract special links
        let specialLinks = OPDS2BookBridge.extractSpecialLinks(from: links)

        return TPPBook(
            acquisitions: acquisitions,
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: imageURLs.image,
            imageThumbnailURL: imageURLs.thumbnail,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: metadata.description,
            title: metadata.title,
            updated: metadata.updated ?? Date(),
            annotationsURL: specialLinks.annotations,
            analyticsURL: specialLinks.analytics,
            alternateURL: specialLinks.alternate,
            relatedWorksURL: specialLinks.related,
            previewLink: previewAcquisition,
            seriesURL: nil,
            revokeURL: specialLinks.revoke,
            reportURL: specialLinks.report,
            timeTrackingURL: specialLinks.timeTracking,
            contributors: nil,
            bookDuration: nil,
            imageCache: ImageCache.shared
        )
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

    // MARK: - TPPBook Conversion

    /// Convert OPDS2 Full Publication to TPPBook with complete metadata
    func toBook() -> TPPBook? {
        let identifier = metadata.identifier

        // Convert acquisition links
        var acquisitions: [TPPOPDSAcquisition] = []
        var previewAcquisition: TPPOPDSAcquisition?

        for link in links {
            if link.rel == "preview" || link.rel == "http://opds-spec.org/acquisition/sample" {
                if let acq = OPDS2BookBridge.convertAcquisition(from: link) {
                    previewAcquisition = acq
                    if link.rel != "preview" {
                        acquisitions.append(acq)
                    }
                }
            } else if let acq = OPDS2BookBridge.convertAcquisition(from: link) {
                acquisitions.append(acq)
            }
        }

        guard !acquisitions.isEmpty else {
            Log.info(#file, "[OPDS2-DIAG] Full publication '\(metadata.title)' (\(identifier)) — no acquisition links, skipping")
            return nil
        }

        Log.info(#file, "[OPDS2-DIAG] Converting full publication '\(metadata.title)' (\(identifier)) — " +
            "\(acquisitions.count) acquisitions, " +
            "authors=\(metadata.author?.count ?? 0), " +
            "subjects=\(metadata.subject?.count ?? 0)")

        // Map authors
        let authors = metadata.author?.map { contributor in
            TPPBookAuthor(
                authorName: contributor.name,
                relatedBooksURL: contributor.links?.first?.hrefURL
            )
        }

        // Map subjects to category strings
        let categoryStrings = metadata.subject?.map { $0.name }

        // Map narrators to contributors dictionary
        var contributors: [String: Any]?
        if let narrators = metadata.narrator, !narrators.isEmpty {
            contributors = ["nrt": narrators.map { $0.name }]
        }

        // Map duration
        var bookDuration: String?
        if let duration = metadata.duration {
            let hours = Int(duration) / 3600
            let minutes = (Int(duration) % 3600) / 60
            if hours > 0 {
                bookDuration = "\(hours):\(String(format: "%02d", minutes)):00"
            } else {
                bookDuration = "\(minutes):00"
            }
        }

        // Extract images
        let imageURLs = OPDS2BookBridge.extractImageURLs(from: images)

        // Extract special links
        let specialLinks = OPDS2BookBridge.extractSpecialLinks(from: links)

        return TPPBook(
            acquisitions: acquisitions,
            authors: authors,
            categoryStrings: categoryStrings,
            distributor: nil,
            identifier: identifier,
            imageURL: imageURLs.image,
            imageThumbnailURL: imageURLs.thumbnail,
            published: metadata.published,
            publisher: metadata.publisher,
            subtitle: metadata.subtitle,
            summary: metadata.description,
            title: metadata.title,
            updated: metadata.modified ?? Date(),
            annotationsURL: specialLinks.annotations,
            analyticsURL: specialLinks.analytics,
            alternateURL: specialLinks.alternate,
            relatedWorksURL: specialLinks.related,
            previewLink: previewAcquisition,
            seriesURL: nil,
            revokeURL: specialLinks.revoke,
            reportURL: specialLinks.report,
            timeTrackingURL: specialLinks.timeTracking,
            contributors: contributors,
            bookDuration: bookDuration,
            imageCache: ImageCache.shared
        )
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

    // MARK: - Memberwise Init

    public init(
        identifier: String,
        title: String,
        sortAs: String? = nil,
        subtitle: String? = nil,
        modified: Date? = nil,
        published: Date? = nil,
        language: String? = nil,
        description: String? = nil,
        author: [OPDS2Contributor]? = nil,
        translator: [OPDS2Contributor]? = nil,
        editor: [OPDS2Contributor]? = nil,
        narrator: [OPDS2Contributor]? = nil,
        contributor: [OPDS2Contributor]? = nil,
        publisher: String? = nil,
        imprint: String? = nil,
        subject: [OPDS2Subject]? = nil,
        duration: Double? = nil,
        numberOfPages: Int? = nil,
        belongsTo: OPDS2BelongsTo? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.sortAs = sortAs
        self.subtitle = subtitle
        self.modified = modified
        self.published = published
        self.language = language
        self.description = description
        self.author = author
        self.translator = translator
        self.editor = editor
        self.narrator = narrator
        self.contributor = contributor
        self.publisher = publisher
        self.imprint = imprint
        self.subject = subject
        self.duration = duration
        self.numberOfPages = numberOfPages
        self.belongsTo = belongsTo
    }

    // MARK: - Codable

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
