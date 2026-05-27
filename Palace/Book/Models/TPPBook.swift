//
//  TPPBook.swift
//  Palace
//
//  Created by Maurice Carrier on 9/16/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import PalaceLogging
import PalaceCatalog

let DeprecatedAcquisitionKey = "acquisition"
let DeprecatedAvailableCopiesKey = "available-copies"
let DeprecatedAvailableUntilKey = "available-until"
let DeprecatedAvailabilityStatusKey = "availability-status"
let DeprecatedHoldsPositionKey = "holds-position"
let DeprecatedTotalCopiesKey = "total-copies"

let AcquisitionsKey = "acquisitions"
let AlternateURLKey = "alternate"
let AnalyticsURLKey = "analytics"
let AnnotationsURLKey = "annotations"
let AudienceKey = "audience"
let AuthorLinksKey = "author-links"
let AuthorsKey = "authors"
let CategoriesKey = "categories"
let DistributorKey = "distributor"
let LanguageKey = "language"
let IdentifierKey = "id"
let ImageThumbnailURLKey = "image-thumbnail"
let ImageURLKey = "image"
let PublishedKey = "published"
let PublisherKey = "publisher"
let RelatedURLKey = "related-works-url"
let PreviewURLKey = "preview-url"
let ReportURLKey = "report-url"
let RevokeURLKey = "revoke-url"
let SeriesLinkKey = "series-link"
let SubtitleKey = "subtitle"
let SummaryKey = "summary"
let TitleKey = "title"
let UpdatedKey = "updated"
let TimeTrackingURLURLKey = "time-tracking-url"

public class TPPBook: NSObject, ObservableObject {
    @objc var acquisitions: [TPPOPDSAcquisition]
    @objc var bookAuthors: [TPPBookAuthor]?
    @objc var categoryStrings: [String]?
    @objc var distributor: String?
    @objc var identifier: String
    @objc var imageURL: URL?
    @objc var imageThumbnailURL: URL?
    @objc var published: Date?
    @objc var publisher: String?
    @objc var subtitle: String?
    @objc var summary: String?
    @objc var title: String
    @objc var updated: Date
    @objc var annotationsURL: URL?
    @objc var analyticsURL: URL?
    @objc var alternateURL: URL?
    @objc var relatedWorksURL: URL?
    @objc var previewLink: TPPOPDSAcquisition?
    @objc var seriesURL: URL?
    @objc var revokeURL: URL?
    @objc var reportURL: URL?
    @objc var timeTrackingURL: URL?
    @objc var contributors: [String: Any]?
    @objc var bookTokenQueue: DispatchQueue
    @objc var bookDuration: String?

    /// Patron audience, e.g. "Adult", "Young Adult", "Children". Sourced
    /// from `<category scheme="schema.org/audience">` and surfaced as its
    /// own row in the book detail INFORMATION section (PP-4046).
    @objc var audience: String?

    /// Language code (BCP-47 / ISO 639) sourced from `<dcterms:language>`.
    /// Use ``displayLanguage`` for a localized name (PP-4046).
    @objc var language: String?

    @Published var coverImage: UIImage?
    @Published var thumbnailImage: UIImage?
    @Published var isCoverLoading: Bool = false
    @Published var isThumbnailLoading: Bool = false
    @Published var dominantUIColor: UIColor = .gray

    static let SimplifiedScheme = "http://librarysimplified.org/terms/genres/Simplified/"

    static func categoryStringsFromCategories(categories: [TPPOPDSCategory]) -> [String] {
        categories.compactMap { $0.scheme == nil || $0.scheme?.absoluteString == SimplifiedScheme ? $0.label ?? $0.term : nil }
    }

    @objc var isAudiobook: Bool {
        defaultBookContentType == .audiobook
    }

    @objc var hasDuration: Bool {
        !(bookDuration?.isEmpty ?? true)
    }

    let imageCache: ImageCacheType

    init(
        acquisitions: [TPPOPDSAcquisition],
        authors: [TPPBookAuthor]?,
        categoryStrings: [String]?,
        distributor: String?,
        identifier: String,
        imageURL: URL?,
        imageThumbnailURL: URL?,
        published: Date?,
        publisher: String?,
        subtitle: String?,
        summary: String?,
        title: String,
        updated: Date,
        annotationsURL: URL?,
        analyticsURL: URL?,
        alternateURL: URL?,
        relatedWorksURL: URL?,
        previewLink: TPPOPDSAcquisition?,
        seriesURL: URL?,
        revokeURL: URL?,
        reportURL: URL?,
        timeTrackingURL: URL?,
        contributors: [String: Any]?,
        bookDuration: String?,
        audience: String? = nil,
        language: String? = nil,
        imageCache: ImageCacheType
    ) {
        self.acquisitions = acquisitions
        self.bookAuthors = authors
        self.categoryStrings = categoryStrings
        self.distributor = distributor
        self.identifier = identifier
        self.imageURL = imageURL
        self.imageThumbnailURL = imageThumbnailURL
        self.published = published
        self.publisher = publisher
        self.subtitle = subtitle
        self.summary = summary
        self.title = title
        self.updated = updated
        self.annotationsURL = annotationsURL
        self.analyticsURL = analyticsURL
        self.alternateURL = alternateURL
        self.relatedWorksURL = relatedWorksURL
        self.previewLink = previewLink
        self.seriesURL = seriesURL
        self.revokeURL = revokeURL
        self.reportURL = reportURL
        self.timeTrackingURL = timeTrackingURL
        self.contributors = contributors
        self.bookTokenQueue = DispatchQueue(label: "TPPBook.bookTokenQueue.\(identifier)")
        self.bookDuration = bookDuration
        self.audience = audience
        self.language = language
        self.imageCache = imageCache

        super.init()
        self.fetchThumbnailImage()
        self.fetchCoverImage()
    }

    @objc convenience init?(entry: TPPOPDSEntry?) {
        guard let entry = entry else {
            Log.debug(#file, ("Failed to create book with nil entry."))
            return nil
        }

        let authors = entry.authorStrings.enumerated().map { index, element in
            TPPBookAuthor(
                authorName: (element as? String) ?? "",
                relatedBooksURL: index < entry.authorLinks.count ? entry.authorLinks[index].href : nil
            )
        }

        var image: URL?
        var imageThumbnail: URL?
        var report: URL?
        var revoke: URL?

        (entry.links as? [TPPOPDSLink])?.forEach {
            switch $0.rel {
            case TPPOPDSRelationAcquisitionRevoke:
                revoke = $0.href
            case TPPOPDSRelationImage:
                image = $0.href
            case TPPOPDSRelationImageThumbnail:
                imageThumbnail = $0.href
            case TPPOPDSRelationAcquisitionIssues:
                report = $0.href
            default:
                break
            }
        }

        self.init(
            acquisitions: entry.acquisitions,
            authors: authors,
            categoryStrings: Self.categoryStringsFromCategories(categories: entry.categories),
            distributor: entry.providerName,
            identifier: entry.identifier,
            imageURL: image,
            imageThumbnailURL: imageThumbnail,
            published: entry.published,
            publisher: entry.publisher,
            subtitle: entry.alternativeHeadline,
            summary: entry.summary,
            title: entry.title,
            updated: entry.updated,
            annotationsURL: entry.annotations?.href,
            analyticsURL: entry.analytics,
            alternateURL: entry.alternate?.href,
            relatedWorksURL: entry.relatedWorks?.href,
            previewLink: entry.previewLink,
            seriesURL: entry.seriesLink?.href,
            revokeURL: revoke,
            reportURL: report,
            timeTrackingURL: entry.timeTrackingLink?.href,
            contributors: entry.contributors as? [String: Any],
            bookDuration: entry.duration,
            audience: entry.audience,
            language: entry.language,
            imageCache: ImageCache.shared
        )
    }

    @objc convenience init?(dictionary: [String: Any]) {
        // Hard requirements: a book is meaningless without id + title. Everything
        // else has a sensible default — be forgiving on read so a single malformed
        // field doesn't wipe a downloaded book from the registry on reload.
        // Log each missing field separately so we can diagnose registry drift.
        guard let identifier = dictionary[IdentifierKey] as? String, !identifier.isEmpty else {
            Log.error(#file, "TPPBook(dictionary:): missing or empty IdentifierKey — dropping")
            return nil
        }
        guard let title = dictionary[TitleKey] as? String, !title.isEmpty else {
            Log.error(#file, "TPPBook(dictionary:): missing or empty TitleKey for id='\(identifier)' — dropping")
            return nil
        }

        // Optional fields: salvage the book if these are missing or malformed.
        let categoryStrings = dictionary[CategoriesKey] as? [String] ?? []
        if dictionary[CategoriesKey] != nil, !(dictionary[CategoriesKey] is [String]) {
            Log.warn(#file, "TPPBook(dictionary:): CategoriesKey present but not [String] for id='\(identifier)' — defaulting to []")
        }

        let acquisitions: [TPPOPDSAcquisition] = (dictionary[AcquisitionsKey] as? [[String: Any]] ?? []).compactMap {
            TPPOPDSAcquisition.acquisition(withDictionary: $0 as NSDictionary)
        }

        let authorStrings: [String] = {
            if let authorObject = dictionary[AuthorsKey] as? [[String]], let values = authorObject.first {
                return values
            } else if let authorObject = dictionary[AuthorsKey] as? [String] {
                return authorObject
            } else {
                return []
            }
        }()

        let authorLinkStrings: [String] = {
            if let authorLinkObject = dictionary[AuthorLinksKey] as? [[String]], let values = authorLinkObject.first {
                return values
            } else if let authorLinkObject = dictionary[AuthorLinksKey] as? [String] {
                return authorLinkObject
            } else {
                return []
            }
        }()

        let authors = authorStrings.enumerated().map { index, name in
            TPPBookAuthor(
                authorName: name,
                relatedBooksURL: index < authorLinkStrings.count ? URL(string: authorLinkStrings[index]) : nil
            )
        }

        let revokeURL = URL(string: dictionary[RevokeURLKey] as? String ?? "")
        let reportURL = URL(string: dictionary[ReportURLKey] as? String ?? "")

        // UpdatedKey is written by `dictionaryRepresentation()` via `updated.rfc339String`
        // (full RFC 3339 datetime). Parse via RFC 3339 first (matches the writer),
        // then fall back to ISO 8601 date-only for legacy records or OPDS feeds that
        // store a bare "2024-09-15". If both fail, log the malformed value and fall
        // through to Date.distantPast so the book still loads — losing the timestamp
        // is preferable to losing the downloaded book.
        let updatedString = dictionary[UpdatedKey] as? String ?? ""
        let updated: Date
        if let parsed = (NSDate.date(withRFC3339String: updatedString)
                         ?? NSDate.date(withISO8601DateString: updatedString)) as Date? {
            updated = parsed
        } else {
            if updatedString.isEmpty {
                Log.warn(#file, "TPPBook(dictionary:): UpdatedKey missing or empty for id='\(identifier)' — using .distantPast")
            } else {
                Log.warn(#file, "TPPBook(dictionary:): UpdatedKey value '\(updatedString)' matched neither RFC 3339 nor ISO 8601 date-only for id='\(identifier)' — using .distantPast")
            }
            updated = .distantPast
        }

        self.init(
            acquisitions: acquisitions,
            authors: authors,
            categoryStrings: categoryStrings,
            distributor: dictionary[DistributorKey] as? String,
            identifier: identifier,
            imageURL: URL(string: dictionary[ImageURLKey] as? String ?? ""),
            imageThumbnailURL: URL(string: dictionary[ImageThumbnailURLKey] as? String ?? ""),
            published: (dictionary[PublishedKey] as? String).flatMap { Date.rfc1123DateFormatter.date(from: $0) } ?? (dictionary[PublishedKey] as? Date),
            publisher: dictionary[PublisherKey] as? String,
            subtitle: dictionary[SubtitleKey] as? String,
            summary: dictionary[SummaryKey] as? String,
            title: title,
            updated: updated,
            annotationsURL: URL(string: dictionary[AnnotationsURLKey] as? String ?? ""),
            analyticsURL: URL(string: dictionary[AnalyticsURLKey] as? String ?? ""),
            alternateURL: URL(string: dictionary[AlternateURLKey] as? String ?? ""),
            relatedWorksURL: URL(string: dictionary[RelatedURLKey] as? String ?? ""),
            previewLink: (dictionary[PreviewURLKey] as? NSDictionary).flatMap { TPPOPDSAcquisition.acquisition(withDictionary: $0) },
            seriesURL: URL(string: dictionary[SeriesLinkKey] as? String ?? ""),
            revokeURL: revokeURL,
            reportURL: reportURL,
            timeTrackingURL: URL(string: dictionary[TimeTrackingURLURLKey] as? String ?? ""),
            contributors: nil,
            bookDuration: nil,
            audience: dictionary[AudienceKey] as? String,
            language: dictionary[LanguageKey] as? String,
            imageCache: ImageCache.shared
        )
    }

    @objc func bookWithMetadata(from book: TPPBook) -> TPPBook {
        TPPBook(
            acquisitions: self.acquisitions,
            authors: book.bookAuthors,
            categoryStrings: book.categoryStrings,
            distributor: book.distributor,
            identifier: self.identifier,
            imageURL: book.imageURL,
            imageThumbnailURL: book.imageThumbnailURL,
            published: book.published,
            publisher: book.publisher,
            subtitle: book.subtitle,
            summary: book.summary,
            title: book.title,
            updated: book.updated,
            annotationsURL: book.annotationsURL,
            analyticsURL: book.analyticsURL,
            alternateURL: book.alternateURL,
            relatedWorksURL: book.relatedWorksURL,
            previewLink: book.previewLink,
            seriesURL: book.seriesURL,
            revokeURL: self.revokeURL,
            reportURL: self.reportURL,
            timeTrackingURL: self.timeTrackingURL,
            contributors: book.contributors,
            bookDuration: book.bookDuration,
            audience: book.audience,
            language: book.language,
            imageCache: self.imageCache
        )
    }

    /// Returns a book that adopts `fresh`'s state-carrying fields (acquisitions,
    /// availability-driven `updated`) but keeps `self`'s metadata wherever
    /// `fresh`'s is empty. Designed for the sync() reconciliation path, where
    /// the Palace Circulation Manager's loans feed has been observed to return
    /// entries with missing `<author>`/`<summary>`/`<category>` elements for
    /// some books on some calls — without this guard, a lean response would
    /// overwrite a previously-enriched registry record and the MyBooks cell
    /// would lose its author line until a catalog visit re-filled it.
    ///
    /// - Parameter fresh: The incoming book from the loans feed (authoritative
    ///                    for availability and acquisitions).
    /// - Returns: A book with fresh state and preserved-non-empty metadata.
    @objc func mergingPreservingMetadata(from fresh: TPPBook) -> TPPBook {
        func preferNonEmpty(_ a: String?, _ b: String?) -> String? {
            if let a, !a.isEmpty { return a }
            return b
        }
        func preferNonEmpty<T>(_ a: [T]?, _ b: [T]?) -> [T]? {
            if let a, !a.isEmpty { return a }
            return b
        }

        let merged = TPPBook(
            acquisitions: fresh.acquisitions,
            authors: preferNonEmpty(fresh.bookAuthors, self.bookAuthors),
            categoryStrings: preferNonEmpty(fresh.categoryStrings, self.categoryStrings),
            distributor: preferNonEmpty(fresh.distributor, self.distributor),
            identifier: self.identifier,
            imageURL: fresh.imageURL ?? self.imageURL,
            imageThumbnailURL: fresh.imageThumbnailURL ?? self.imageThumbnailURL,
            published: fresh.published ?? self.published,
            publisher: preferNonEmpty(fresh.publisher, self.publisher),
            subtitle: preferNonEmpty(fresh.subtitle, self.subtitle),
            summary: preferNonEmpty(fresh.summary, self.summary),
            title: fresh.title.isEmpty ? self.title : fresh.title,
            updated: fresh.updated,
            annotationsURL: fresh.annotationsURL ?? self.annotationsURL,
            analyticsURL: fresh.analyticsURL ?? self.analyticsURL,
            alternateURL: fresh.alternateURL ?? self.alternateURL,
            relatedWorksURL: fresh.relatedWorksURL ?? self.relatedWorksURL,
            previewLink: fresh.previewLink ?? self.previewLink,
            seriesURL: fresh.seriesURL ?? self.seriesURL,
            revokeURL: fresh.revokeURL ?? self.revokeURL,
            reportURL: fresh.reportURL ?? self.reportURL,
            timeTrackingURL: fresh.timeTrackingURL ?? self.timeTrackingURL,
            contributors: fresh.contributors ?? self.contributors,
            bookDuration: fresh.bookDuration ?? self.bookDuration,
            audience: preferNonEmpty(fresh.audience, self.audience),
            language: preferNonEmpty(fresh.language, self.language),
            imageCache: self.imageCache
        )
        // Carry the resolved images onto the merged instance so the view
        // doesn't flash a skeleton for one frame while fetchCoverImage
        // re-hydrates them asynchronously — TPPBook.init dispatches the
        // cache-hit assignment through DispatchQueue.main.async, which is
        // just late enough for SwiftUI to render a nil image first.
        merged.coverImage = self.coverImage ?? fresh.coverImage
        merged.thumbnailImage = self.thumbnailImage ?? fresh.thumbnailImage
        return merged
    }

    @objc func dictionaryRepresentation() -> [String: Any] {
        let acquisitions = self.acquisitions.map { $0.dictionaryRepresentation() }

        return [
            AcquisitionsKey: acquisitions,
            AlternateURLKey: alternateURL?.absoluteString ?? "",
            AnnotationsURLKey: annotationsURL?.absoluteString ?? "",
            AnalyticsURLKey: analyticsURL?.absoluteString ?? "",
            AudienceKey: audience as Any,
            AuthorLinksKey: authorLinkArray ?? [],
            AuthorsKey: authorNameArray ?? [],
            CategoriesKey: categoryStrings as Any,
            DistributorKey: distributor as Any,
            IdentifierKey: identifier,
            ImageURLKey: imageURL?.absoluteString as Any,
            ImageThumbnailURLKey: imageThumbnailURL?.absoluteString as Any,
            LanguageKey: language as Any,
            PublishedKey: published?.rfc1123String as Any,
            PublisherKey: publisher as Any,
            RelatedURLKey: relatedWorksURL?.absoluteString as Any,
            ReportURLKey: reportURL?.absoluteString as Any,
            RevokeURLKey: revokeURL?.absoluteString as Any,
            SeriesLinkKey: seriesURL?.absoluteString as Any,
            PreviewURLKey: previewLink?.dictionaryRepresentation() as Any,
            SubtitleKey: subtitle as Any,
            SummaryKey: summary as Any,
            TitleKey: title as Any,
            UpdatedKey: updated.rfc339String as Any,
            TimeTrackingURLURLKey: timeTrackingURL?.absoluteString as Any
        ]
    }

    /// Localized human-readable language name for `language` (e.g. "en" → "English"
    /// in English locales, "Anglais" in French). Falls back to the raw code if
    /// Foundation has no localization for it.
    @objc var displayLanguage: String? {
        guard let code = language, !code.isEmpty else { return nil }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    @objc var authorNameArray: [String]? {
        bookAuthors?.compactMap { $0.name }
    }

    @objc var authorLinkArray: [String]? {
        bookAuthors?.compactMap { $0.relatedBooksURL?.absoluteString }
    }

    @objc var authors: String? {
        authorNameArray?.joined(separator: "; ")
    }

    @objc var categories: String? {
        categoryStrings?.joined(separator: "; ")
    }

    @objc var narrators: String? {
        (contributors?["nrt"] as? [String])?.joined(separator: "; ")
    }

    @objc var defaultAcquisition: TPPOPDSAcquisition? {
        acquisitions.first(where: {
            !TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
                forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
                allowedRelations: TPPOPDSAcquisitionRelationSetDefaultAcquisition,
                acquisitions: [$0]
            ).isEmpty
        })
    }

    @objc var sampleAcquisition: TPPOPDSAcquisition? {
        let sampleAndPreview: TPPOPDSAcquisitionRelationSet = [.sample, .preview]
        return acquisitions.first(where: {
            !TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
                forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
                allowedRelations: sampleAndPreview.rawValue,
                acquisitions: [$0]
            ).isEmpty
        }) ?? previewLink
    }

    @objc var isExpired: Bool {
        guard let date = getExpirationDate() else { return false }
        return date < Date()
    }

    @objc func getExpirationDate() -> Date? {
        var date: Date?

        defaultAcquisition?.availability.match(unavailable:
            nil,
            limited: { limited in
                if let until = limited.until { date = until }
            },
            unlimited: nil,
            reserved: nil,
            ready: { ready in
                if let until = ready.until { date = until }
            }
        )

        return date
    }

    @objc func getReservationDetails() -> ReservationDetails {
        var untilDate: Date?
        let reservationDetails = ReservationDetails()

        defaultAcquisition?.availability.match(unavailable: 
            nil,
            limited: nil,
            unlimited: nil,
            reserved: { reserved in
                if reserved.holdPosition > 0 {
                    reservationDetails.holdPosition = Int(reserved.holdPosition)
                }
                if let until = reserved.until, until.timeIntervalSinceNow > 0 {
                    untilDate = until
                }

                let total = reserved.copiesTotal
                if total != UInt(TPPOPDSAcquisitionAvailabilityCopiesUnknown) && total <= UInt(Int.max) {
                    reservationDetails.copiesAvailable = Int(total)
                }

            },
            ready: { ready in
                if let until = ready.until, until.timeIntervalSinceNow > 0 {
                    untilDate = until
                }
            }
        )

        // Convert untilDate into a readable format
        if let untilDate = untilDate {
            let now = Date()
            let calendar = Calendar.current
            let components = calendar.dateComponents([.day], from: now, to: untilDate)

            if let days = components.day {
                reservationDetails.remainingTime = days
                reservationDetails.timeUnit = "day\(days == 1 ? "" : "s")"
            }
        }

        return reservationDetails
    }

    func getAvailabilityDetails() -> AvailabilityDetails {
        var details = AvailabilityDetails()
        defaultAcquisition?.availability.match(unavailable: nil, limited: { limited in
            if let sinceDate = limited.since {
                let (value, unit) = sinceDate.timeUntil()
                details.availableSince = "\(value) \(unit)"
            }

            if let untilDate = limited.until, untilDate.timeIntervalSinceNow > 0 {
                let (value, unit) = untilDate.timeUntil()
                details.availableUntil = "\(value) \(unit)"
            }
        }, unlimited: { unlimited in
            if let sinceDate = unlimited.since {
                let (value, unit) = sinceDate.timeUntil()
                details.availableSince = "\(value) \(unit)"
            }

            if let untilDate = unlimited.until, untilDate.timeIntervalSinceNow > 0 {
                let (value, unit) = untilDate.timeUntil()
                details.availableUntil = "\(value) \(unit)"
            }
        }, reserved: nil, ready: nil)

        return details
    }

    @objc var defaultAcquisitionIfBorrow: TPPOPDSAcquisition? {
        defaultAcquisition?.relation == .borrow ? defaultAcquisition : nil
    }

    @objc var defaultAcquisitionIfOpenAccess: TPPOPDSAcquisition? {
        defaultAcquisition?.relation == .openAccess ? defaultAcquisition : nil
    }

    @objc var defaultBookContentType: TPPBookContentType {
        guard let acquisition = defaultAcquisition else {
            return .unsupported
        }

        let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
            forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
            allowedRelations: NYPLOPDSAcquisitionRelationSetAll,
            acquisitions: [acquisition]
        )

        let contentTypes = paths.compactMap { path -> TPPBookContentType? in
            TPPBookContentType.from(mimeType: path.types.last)
        }

        return contentTypes.first(where: { $0 != .unsupported }) ?? .unsupported
    }

    /// PP-3649: Whether this book requires Adobe DRM activation before download.
    /// Used by MyBooksDownloadCenter to perform on-demand device activation.
    @objc var requiresAdobeDRM: Bool {
        guard let acquisition = defaultAcquisition else { return false }
        let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
            forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
            allowedRelations: NYPLOPDSAcquisitionRelationSetAll,
            acquisitions: [acquisition]
        )
        return paths.contains { path in
            path.types.contains(ContentTypeAdobeAdept)
        }
    }

    /// True when any DRM scheme protects this book (Adobe ACS or Readium LCP,
    /// across EPUB/PDF/audiobook content). Readers use this to gate the system
    /// text-selection edit menu — DRM titles do not surface Copy/Cut/Paste/etc.
    /// Walks the full nested acquisition chain so license types two levels
    /// deep are still detected (cf. PP-4407 acquisition-chain regression).
    @objc var isDRMProtected: Bool {
        guard let acquisition = defaultAcquisition else { return false }
        let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
            forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
            allowedRelations: NYPLOPDSAcquisitionRelationSetAll,
            acquisitions: [acquisition]
        )
        return paths.contains { path in
            path.types.contains(ContentTypeAdobeAdept) ||
            path.types.contains(ContentTypeReadiumLCP) ||
            path.types.contains(ContentTypePDFLCP) ||
            path.types.contains(ContentTypeAudiobookLCP)
        }
    }
}

extension TPPBook: Identifiable {}
extension TPPBook: Comparable {
    public static func < (lhs: TPPBook, rhs: TPPBook) -> Bool {
        lhs.identifier < rhs.identifier
    }
}

extension TPPBook: @unchecked Sendable {}

extension TPPBook {
    func requiresAuthForReturnOrDeletion() -> Bool {
        let userAuthRequired = AppContainer.production().accountsManager.currentUserAccount.authDefinition?.needsAuth ?? false
        return self.defaultAcquisitionIfOpenAccess == nil && userAuthRequired
    }
}

@objcMembers
public class ReservationDetails: NSObject {
    public var holdPosition: Int = 0
    public var remainingTime: Int = 0
    public var timeUnit: String = ""
    public var copiesAvailable: Int = 0
}

struct AvailabilityDetails {
    var availableSince: String?
    var availableUntil: String?
}
