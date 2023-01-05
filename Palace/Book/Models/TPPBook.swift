//
//  TPPBook.swift
//  Palace
//
//  Created by Maurice Carrier on 9/16/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

let DeprecatedAcquisitionKey: String = "acquisition"
let DeprecatedAvailableCopiesKey: String = "available-copies"
let DeprecatedAvailableUntilKey: String = "available-until"
let DeprecatedAvailabilityStatusKey: String = "availability-status"
let DeprecatedHoldsPositionKey: String = "holds-position"
let DeprecatedTotalCopiesKey: String = "total-copies"

let AcquisitionsKey: String = "acquisitions"
let AlternateURLKey: String = "alternate"
let AnalyticsURLKey: String = "analytics"
let AnnotationsURLKey: String = "annotations"
let AuthorLinksKey: String = "author-links"
let AuthorsKey: String = "authors"
let CategoriesKey: String = "categories"
let DistributorKey: String = "distributor"
let IdentifierKey: String = "id"
let ImageThumbnailURLKey: String = "image-thumbnail"
let ImageURLKey: String = "image"
let PublishedKey: String = "published"
let PublisherKey: String = "publisher"
let RelatedURLKey: String = "related-works-url"
let PreviewURLKey: String = "preview-url"
let ReportURLKey: String = "report-url"
let RevokeURLKey: String = "revoke-url"
let SeriesLinkKey: String = "series-link"
let SubtitleKey: String = "subtitle"
let SummaryKey: String = "summary"
let TitleKey: String = "title"
let UpdatedKey: String = "updated"

@objc class TPPBook: NSObject {
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
  @objc var contributors: [String: Any]?
  @objc var bookTokenLock: NSRecursiveLock
  
  static let SimplifiedScheme = "http://librarysimplified.org/terms/genres/Simplified/"
  
  static func categoryStringsFromCategories(categories: [TPPOPDSCategory]) -> [String] {
    categories.filter { $0.scheme == nil || ($0.scheme?.absoluteString ?? "") == SimplifiedScheme }.map { $0.label ?? $0.term }
  }
  
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
    contributors: [String: Any]?
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
    self.contributors = contributors
    self.bookTokenLock = NSRecursiveLock()
  }

  /// @brief Factory method to build a TPPBook object from an OPDS feed entry.
  ///
  /// @param entry An OPDS entry to base the book on.
  ///
  /// @return @p nil if the entry does not contain non-nil values for the
  /// @p acquisitions, @p categories, @p identifier, @p title, @p updated
  /// properties.
  @objc convenience init?(entry: TPPOPDSEntry?) {
    guard let entry = entry else {
      Log.debug(#file, ("Failed to create book with nil entry."))
      return nil
    }

    var revoke, image, imageThumbnail, report: URL?
    let authors = entry.authorStrings.enumerated().map { (index, element) in
      TPPBookAuthor(
        authorName: (element as? String) ?? "",
        relatedBooksURL: entry.authorLinks.count > index ? entry.authorLinks[index].href : nil
      )
    }

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
        return
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
      contributors: entry.contributors
    )
  }
  
  /// @brief This is the designated initializer.
  ///
  /// @discussion Returns @p nil if either one of the values for the following
  /// keys is nil: @p "categories", @p "id", @p "title", @p "updated". In all other cases
  /// an non-nil instance is returned.
  ///
  /// @param dictionary A JSON-style key-value pair string dictionary.
  @objc convenience init?(dictionary: [String: Any]) {
    guard let categoryStrings = dictionary[CategoriesKey] as? [String],
        let identifier = dictionary[IdentifierKey] as? String,
        let title = dictionary[TitleKey] as? String
    else {
     return nil
    }

    var acquisitions = [TPPOPDSAcquisition]()

    if let acquisitionDictionaries: [[String: Any]] = dictionary[AcquisitionsKey] as? [[String: Any]] {
      acquisitions = acquisitionDictionaries.compactMap {
        return TPPOPDSAcquisition(dictionary: $0)
      }
    }
    
    var authors = [TPPBookAuthor]()
    
    var authorStrings = [String]()
    if let authorObject = dictionary[AuthorsKey] as? [[String]], let values = authorObject.first {
      authorStrings = values
    } else if let authorObject = dictionary[AuthorsKey] as? [String] {
      authorStrings = authorObject
    }
    var authorLinkStrings = [String]()
    if let authorLinkObject = dictionary[AuthorLinksKey] as? [[String]], let values = authorLinkObject.first {
      authorLinkStrings = values
    } else if let authorLinkObject = dictionary[AuthorLinksKey] as? [String] {
      authorLinkStrings = authorLinkObject
    }

    authors = authorStrings.enumerated().map { (index, name) in
      TPPBookAuthor(
        authorName: name,
        relatedBooksURL: authorLinkStrings.count > index ? URL(string: authorLinkStrings[index]) : nil
      )
    }
    
    
    var revokeURL = URL(string: dictionary[RevokeURLKey] as? String ?? "")
    var reportURL = URL(string: dictionary[ReportURLKey] as? String ?? "")

    if dictionary[DeprecatedAcquisitionKey] != nil {
      acquisitions = [TPPOPDSAcquisition]()

      revokeURL = URL(string: (dictionary[DeprecatedAcquisitionKey] as? [String: String])?["revoke"] ?? "")
      reportURL = URL(string: (dictionary[DeprecatedAcquisitionKey] as? [String: String])?["report"] ?? "")
      
      let availabilityStatus = dictionary[DeprecatedAvailabilityStatusKey] as? String
      let holdsPositionString = dictionary[DeprecatedHoldsPositionKey] as? String
      var holdsPosition: Int?
      if let holdsPositioningString = holdsPositionString {
        holdsPosition = Int(holdsPositioningString)
      }

      var availableCopies: Int?
      if let availableCopiesString = dictionary[DeprecatedAvailableCopiesKey] as? String {
        availableCopies = Int(availableCopiesString)
      }

      var totalCopies: Int?
      if let totalCopiesString = dictionary[DeprecatedTotalCopiesKey] as? String {
        totalCopies = Int(totalCopiesString)
      }
      
      var until: Date?
      if let untilString = dictionary[DeprecatedAvailableUntilKey] as? String {
        until = NSDate(rfc3339String: untilString) as? Date
      }
    
      var availability: TPPOPDSAcquisitionAvailability = TPPOPDSAcquisitionAvailabilityUnlimited()
      
      switch availabilityStatus {
      case "available":
        if availableCopies == NSNotFound {
          break
        } else {
          availability = TPPOPDSAcquisitionAvailabilityLimited(
            copiesAvailable: UInt(availableCopies ?? NSNotFound),
            copiesTotal: UInt(totalCopies ?? NSNotFound),
            since: until,
            until: until
          )
        }
      case "unavailable":
        availability = TPPOPDSAcquisitionAvailabilityUnavailable(
          copiesHeld: UInt(availableCopies ?? NSNotFound),
          copiesTotal: UInt(totalCopies ?? NSNotFound)
        )
      case "reserved":
        availability = TPPOPDSAcquisitionAvailabilityReserved(
          holdPosition: UInt(holdsPosition ?? NSNotFound),
          copiesTotal: UInt(totalCopies ?? NSNotFound),
          since: until,
          until: until
        )
      case "ready":
        availability = TPPOPDSAcquisitionAvailabilityReady(since: until, until: until)
      default:
        break
      }
      
      let applicationEPUBZIP = ContentTypeEpubZip
      let genericURL = URL(string: (dictionary[DeprecatedAcquisitionKey] as? [String: String])?["generic"] ?? "")
      if let genericURL = genericURL {
        acquisitions.append(TPPOPDSAcquisition(
          relation: .generic,
          type: applicationEPUBZIP,
          hrefURL: genericURL,
          indirectAcquisitions: [],
          availability: availability)
        )
      }
      
      let borrowURL = URL(string: (dictionary[DeprecatedAcquisitionKey] as? [String: String])?["borrow"] ?? "")
      if let borrowURL = borrowURL {
        acquisitions.append(TPPOPDSAcquisition(
          relation: .borrow,
          type: applicationEPUBZIP,
          hrefURL: borrowURL,
          indirectAcquisitions: [],
          availability: availability)
        )
      }
      
      let openAccessURL = URL(string: (dictionary[DeprecatedAcquisitionKey] as? [String: String])?["open-access"] ?? "")
      if let openAccessURL = openAccessURL {
        acquisitions.append(TPPOPDSAcquisition(
          relation: .openAccess,
          type: applicationEPUBZIP,
          hrefURL: openAccessURL,
          indirectAcquisitions: [],
          availability: availability)
        )
      }
      
      let sampleURL = URL(string: (dictionary[DeprecatedAcquisitionKey] as? [String: String])?["sample"] ?? "")
      if let sampleURL = sampleURL {
        acquisitions.append(TPPOPDSAcquisition(
          relation: .sample,
          type: applicationEPUBZIP,
          hrefURL: sampleURL,
          indirectAcquisitions: [],
          availability: availability)
        )
      }
    }

    guard let updated = NSDate(iso8601DateString: (dictionary[UpdatedKey] as? String ?? "")) as? Date else { return nil }

    self.init(
      acquisitions: acquisitions,
      authors: authors,
      categoryStrings: categoryStrings,
      distributor: dictionary[DistributorKey] as? String,
      identifier: identifier,
      imageURL: dictionary[ImageURLKey] as? URL,
      imageThumbnailURL: dictionary[ImageThumbnailURLKey] as? URL,
      published: dictionary[PublishedKey] as? Date,
      publisher: dictionary[PublisherKey] as? String,
      subtitle: dictionary[SubtitleKey] as? String,
      summary: dictionary[SummaryKey] as? String,
      title: title,
      updated: updated,
      annotationsURL: URL(string: dictionary[AnnotationsURLKey] as? String ?? ""),
      analyticsURL: URL(string: dictionary[AnalyticsURLKey] as? String ?? ""),
      alternateURL: URL(string: dictionary[AlternateURLKey] as? String ?? ""),
      relatedWorksURL: URL(string: dictionary[RelatedURLKey] as? String ?? ""),
      previewLink: dictionary[PreviewURLKey] as? TPPOPDSAcquisition,
      seriesURL: URL(string: dictionary[SeriesLinkKey] as? String ?? ""),
      revokeURL: revokeURL,
      reportURL: reportURL,
      contributors: nil
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
      contributors: book.contributors
    )
  }

  @objc func dictionaryRepresentation() -> [String: Any] {
    let acquisitions = self.acquisitions.map { $0.dictionaryRepresentation() }
    
    return [
      AcquisitionsKey: acquisitions,
      AlternateURLKey: alternateURL?.absoluteString ?? "",
      AnnotationsURLKey: annotationsURL?.absoluteString ?? "",
      AnalyticsURLKey: analyticsURL?.absoluteString ?? "",
      AuthorLinksKey: authorLinkArray ?? [],
      AuthorsKey: authorNameArray ?? [],
      CategoriesKey: categoryStrings as Any,
      DistributorKey: distributor as Any,
      IdentifierKey: identifier,
      ImageURLKey: imageURL?.absoluteString as Any,
      ImageThumbnailURLKey: imageThumbnailURL?.absoluteString as Any,
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
      UpdatedKey: updated.rfc339String as Any
    ]
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

  /// @discussion
  /// A compatibility method to allow the app to continue to function until the
  /// user interface and other components support handling multiple valid
  /// acquisition possibilities. Its use should be avoided wherever possible and
  /// it will eventually be removed.
  ///
  /// @seealso @b https://jira.nypl.org/browse/SIMPLY-2588
  ///
  /// @return An acquisition leading to an EPUB or @c nil.
  @objc var defaultAcquisition: TPPOPDSAcquisition? {
    guard acquisitions.count > 0 else {
      Log.debug("", "ERROR: No acquisitions found when computing a default. This is an OPDS violation.")
      return nil
    }

    // Return first valid acquisition link
    for acquisition in acquisitions {
      let path = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
        forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
        allowedRelations: TPPOPDSAcquisitionRelationSetDefaultAcquisition,
        acquisitions: [acquisition]
      )

      if !path.isEmpty {
        return acquisition
      }
    }
  
    return nil
  }

  /// Sample acquisition
  @objc var sampleAcquisition: TPPOPDSAcquisition? {
    var acquisition: TPPOPDSAcquisition? = previewLink

    acquisitions.forEach {
      let path = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
        forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
        allowedRelations: TPPOPDSAcquisitionRelationSet.sample,
        acquisitions: [$0]
      )

      if !path.isEmpty {
        acquisition = $0
      }
    }
  
    return acquisition
  }

  /// @discussion
  /// A compatibility method to allow the app to continue to function until the
  /// user interface and other components support handling multiple valid
  /// acquisition possibilities. Its use should be avoided wherever possible and
  /// it will eventually be removed.
  ///
  /// @seealso @b https://jira.nypl.org/browse/SIMPLY-2588
  ///
  /// @return The default acquisition leading to an EPUB if it has a borrow
  /// relation, else @c nil.
  @objc var defaultAcquisitionIfBorrow: TPPOPDSAcquisition? {
    guard let acquisition = defaultAcquisition else { return nil }
    return acquisition.relation == .borrow ? acquisition : nil
  }

  /// @discussion
  /// A compatibility method to allow the app to continue to function until the
  /// user interface and other components support handling multiple valid
  /// acquisition possibilities. Its use should be avoided wherever possible and
  /// it will eventually be removed.
  ///
  /// @seealso @b https://jira.nypl.org/browse/SIMPLY-2588
  ///
  /// @return The default acquisition leading to an EPUB if it has an open access
  /// relation, else @c nil.
  @objc var defaultAcquisitionIfOpenAccess: TPPOPDSAcquisition? {
    guard let acquisition = defaultAcquisition else { return nil }
    return acquisition.relation == .openAccess ? acquisition : nil
  }

  /// @discussion
  /// Assigns the book content type based on the inner-most type listed
  /// in the acquistion path. If multiple acquisition paths exist, default
  /// to epub+zip before moving down to other supported types. The UI
  /// does not yet support more than one supported type.
  ///
  /// @seealso @b https://jira.nypl.org/browse/SIMPLY-2588
  ///
  /// @return The default TPPBookContentType
  @objc var defaultBookContentType: TPPBookContentType {
    guard let acquisition = defaultAcquisition else {
      return .unsupported
    }

    let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
      forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
      allowedRelations: NYPLOPDSAcquisitionRelationSetAll,
      acquisitions: [acquisition])

    var defaultType: TPPBookContentType = .unsupported

    paths.forEach {
      let finalTypeString = $0.types.last
      let contentType = TPPBookContentType.from(mimeType: finalTypeString)
      
      if contentType == TPPBookContentType.epub {
        defaultType = contentType
        return
      }

      if defaultType == .unsupported {
        defaultType = contentType
      }
    }
    
    return defaultType
  }
}

extension TPPBook: Identifiable {}
