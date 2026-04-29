//
//  OPDS2PublicationExtended.swift
//  Palace
//
//  Extended OPDS2 Publication model with full book metadata
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import PalaceLogging

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
        var indirectAcqs = convertIndirectAcquisitions(link.properties?.indirectAcquisition)

        // OPDS 2 feeds may omit indirectAcquisition in link properties.
        // When the link type is an intermediate/fulfillment type, synthesize
        // the expected indirect acquisition chain so Palace recognizes the format.
        if indirectAcqs.isEmpty {
            indirectAcqs = Self.synthesizeIndirectAcquisitions(forType: type)
        }

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

    /// When OPDS 2 links omit indirectAcquisition, infer the content types
    /// from the link type so TPPOPDSAcquisitionPath can find a supported path.
    private static func synthesizeIndirectAcquisitions(forType type: String) -> [TPPOPDSIndirectAcquisition] {
        let contentTypes: [String]
        switch type {
        case "application/vnd.librarysimplified.bearer-token+json",
             "application/atom+xml;type=entry;profile=opds-catalog",
             "application/opds-publication+json":
            // Common fulfillment types — the final content could be EPUB, PDF, or audiobook
            contentTypes = [
                "application/epub+zip",
                "application/pdf",
                "application/audiobook+json",
                "audio/mpeg"
            ]
        case "application/vnd.readium.lcp.license.v1.0+json":
            contentTypes = [
                "application/epub+zip",
                "application/pdf",
                "application/audiobook+lcp"
            ]
        default:
            return []
        }
        return contentTypes.map {
            TPPOPDSIndirectAcquisition(type: $0, indirectAcquisitions: [])
        }
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

        // Drop publications whose only formats this client can't render
        // (e.g. Palace Bookshelf books offered solely as text/html
        // streaming-media — iOS has no in-app web reader). Other Palace
        // clients can show these; a future "Open in browser" action could
        // bring them back in. For now they would otherwise appear in the
        // catalog with no actionable buttons.
        let supportedTypes = TPPOPDSAcquisitionPath.supportedTypes()
        let hasOpenablePath = acquisitions.contains { acq in
            !TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
                forAllowedTypes: supportedTypes,
                allowedRelations: TPPOPDSAcquisitionRelationSetDefaultAcquisition,
                acquisitions: [acq]
            ).isEmpty
        }
        guard hasOpenablePath else {
            let acqDump = Self.summarize(acquisitions: acquisitions)
            Log.info(#file, "[OPDS2-DIAG] Publication '\(metadata.title)' (\(identifier)) — no supported acquisition path, skipping. \(acqDump)")
            return nil
        }

        Log.info(#file, "[OPDS2-DIAG] Converting publication '\(metadata.title)' (\(identifier)) — " +
            "\(acquisitions.count) acquisitions, " +
            "relations=[\(acquisitions.map { NYPLOPDSAcquisitionRelationString($0.relation) }.joined(separator: ", "))]")

        // Extract images
        let imageURLs = OPDS2BookBridge.extractImageURLs(from: images)

        // Extract special links
        let specialLinks = OPDS2BookBridge.extractSpecialLinks(from: links)

        let authors = metadata.author?.map {
            TPPBookAuthor(authorName: $0.name, relatedBooksURL: $0.links?.first?.hrefURL)
        }

        return TPPBook(
            acquisitions: acquisitions,
            authors: authors,
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: imageURLs.image,
            imageThumbnailURL: imageURLs.thumbnail,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: metadata.description?.stringByDecodingHTMLEntities,
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

    /// One-line dump of an acquisition list for diagnostic logs.
    static func summarize(acquisitions: [TPPOPDSAcquisition]) -> String {
        let entries = acquisitions.map { acq -> String in
            let indirects = acq.indirectAcquisitions.map { $0.type }.joined(separator: ", ")
            return "{type=\(acq.type), rel=\(NYPLOPDSAcquisitionRelationString(acq.relation)), indirects=[\(indirects)]}"
        }.joined(separator: "; ")
        return "acquisitions=[\(entries)]"
    }
}

// MARK: - Full Publication Model

/// Complete OPDS2 Publication with all metadata fields

// MARK: - OPDS2FullPublication → TPPBook bridge (kept in app target — references TPPBook)
extension OPDS2FullPublication {
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

        // See note in OPDS2Publication.toBook() — drop publications whose
        // only formats this client cannot render.
        let supportedTypes = TPPOPDSAcquisitionPath.supportedTypes()
        let hasOpenablePath = acquisitions.contains { acq in
            !TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
                forAllowedTypes: supportedTypes,
                allowedRelations: TPPOPDSAcquisitionRelationSetDefaultAcquisition,
                acquisitions: [acq]
            ).isEmpty
        }
        guard hasOpenablePath else {
            let acqDump = OPDS2Publication.summarize(acquisitions: acquisitions)
            Log.info(#file, "[OPDS2-DIAG] Full publication '\(metadata.title)' (\(identifier)) — no supported acquisition path, skipping. \(acqDump)")
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
            summary: metadata.description?.stringByDecodingHTMLEntities,
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
