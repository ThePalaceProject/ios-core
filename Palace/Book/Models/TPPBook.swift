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
let AuthorLinksKey = "author-links"
let AuthorsKey = "authors"
let CategoriesKey = "categories"
let DistributorKey = "distributor"
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
      contributors: entry.contributors,
      bookDuration: entry.duration,
      imageCache: ImageCache.shared
    )
  }

  @objc convenience init?(dictionary: [String: Any]) {
    guard let categoryStrings = dictionary[CategoriesKey] as? [String],
          let identifier = dictionary[IdentifierKey] as? String,
          let title = dictionary[TitleKey] as? String else {
      return nil
    }

    let acquisitions: [TPPOPDSAcquisition] = (dictionary[AcquisitionsKey] as? [[String: Any]] ?? []).compactMap {
      TPPOPDSAcquisition(dictionary: $0)
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

    guard let updated = NSDate(iso8601DateString: dictionary[UpdatedKey] as? String ?? "") as? Date else { return nil }

    self.init(
      acquisitions: acquisitions,
      authors: authors,
      categoryStrings: categoryStrings,
      distributor: dictionary[DistributorKey] as? String,
      identifier: identifier,
      imageURL: URL(string: dictionary[ImageURLKey] as? String ?? ""),
      imageThumbnailURL: URL(string: dictionary[ImageThumbnailURLKey] as? String ?? ""),
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
      previewLink: (dictionary[PreviewURLKey] as? [AnyHashable: Any]).flatMap { TPPOPDSAcquisition(dictionary: $0) },
      seriesURL: URL(string: dictionary[SeriesLinkKey] as? String ?? ""),
      revokeURL: revokeURL,
      reportURL: reportURL,
      timeTrackingURL: URL(string: dictionary[TimeTrackingURLURLKey] as? String ?? ""),
      contributors: nil,
      bookDuration: nil,
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
      imageCache: self.imageCache
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
      UpdatedKey: updated.rfc339String as Any,
      TimeTrackingURLURLKey: timeTrackingURL?.absoluteString as Any
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
    acquisitions.first(where: {
      !TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
        forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
        allowedRelations: TPPOPDSAcquisitionRelationSet.sample,
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

    defaultAcquisition?.availability.matchUnavailable(
      nil,
      limited: { limited in
        if let until = limited.until, until.timeIntervalSinceNow > 0 { date = until }
      },
      unlimited: nil,
      reserved: nil,
      ready: { ready in
        if let until = ready.until, until.timeIntervalSinceNow > 0 { date = until }
      }
    )
    
    return date
  }
  
  @objc func getReservationDetails() -> ReservationDetails {
    var untilDate: Date?
    let reservationDetails = ReservationDetails()
    
    defaultAcquisition?.availability.matchUnavailable(
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
        
        reservationDetails.copiesAvailable = Int(reserved.copiesTotal)
        
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
    defaultAcquisition?.availability.matchUnavailable(nil, limited: { limited in
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
    }, reserved: nil)
    
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
        // Books with only indirect acquisitions (catalog navigation entries) are expected
        // They're not meant to be borrowed directly, just navigation to more detailed entries
        Log.debug(#file, "📖 [CONTENT TYPE] No default acquisition for book: \(title) - likely a catalog navigation entry")
        Log.debug(#file, "  All acquisitions: \(acquisitions.map { "type=\($0.type), relation=\($0.relation)" }.joined(separator: ", "))")
        return .unsupported
      }
    
      Log.debug(#file, "📖 [CONTENT TYPE] Determining content type for book: \(title) (ID: \(identifier))")
      Log.debug(#file, "  Distributor: \(distributor ?? "nil")")
      Log.debug(#file, "  Default acquisition type: \(acquisition.type)")
      Log.debug(#file, "  Default acquisition relation: \(acquisition.relation)")
      
      let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
        forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
        allowedRelations: NYPLOPDSAcquisitionRelationSetAll,
        acquisitions: [acquisition]
      )
      
      Log.debug(#file, "  Found \(paths.count) supported acquisition paths")
      for (index, path) in paths.enumerated() {
        Log.debug(#file, "    Path \(index + 1): types=[\(path.types.joined(separator: " → "))]")
      }
      
      let contentTypes = paths.compactMap { path -> TPPBookContentType? in
        let lastType = path.types.last
        let contentType = TPPBookContentType.from(mimeType: lastType)
        Log.debug(#file, "    MIME '\(lastType ?? "nil")' → \(TPPBookContentTypeConverter.stringValue(of: contentType))")
        return contentType
      }
      
      let finalType = contentTypes.first(where: { $0 != .unsupported }) ?? .unsupported
      Log.debug(#file, "  ✅ Final content type: \(TPPBookContentTypeConverter.stringValue(of: finalType))")
    
      if finalType == .unsupported {
        Log.error(#file, "  ❌ Book is UNSUPPORTED - no valid content type found!")
        Log.error(#file, "  All acquisition types: \(acquisitions.map { $0.type }.joined(separator: ", "))")
      }
    
    return finalType
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
    let userAuthRequired = TPPUserAccount.sharedAccount().authDefinition?.needsAuth ?? false
    return self.defaultAcquisitionIfOpenAccess == nil && userAuthRequired
  }
}

extension TPPBook {
  private static let coverRegistry = TPPBookCoverRegistry.shared
  
  func fetchCoverImage() {
      let simpleKey = identifier
      let coverKey = "\(identifier)_cover"
      
      if let img = imageCache.get(for: simpleKey) ?? imageCache.get(for: coverKey) {
        DispatchQueue.main.async {
          self.coverImage = img
          self.updateDominantColor(using: img)
        }
        return
      }

      guard !isCoverLoading else { return }
      
      DispatchQueue.main.async {
        self.isCoverLoading = true
      }

      TPPBookCoverRegistryBridge.shared.coverImageForBook(self) { [weak self] image in
        guard let self = self else { return }
        let final = image ?? self.thumbnailImage

        DispatchQueue.main.async {
          self.coverImage = final
          if let img = final {
            self.imageCache.set(img, for: self.identifier)
            self.imageCache.set(img, for: coverKey)
            self.updateDominantColor(using: img)
          }
          self.isCoverLoading = false
        }
      }
    }

    func fetchThumbnailImage() {
      let simpleKey = identifier
      let thumbnailKey = "\(identifier)_thumbnail"
      
      if let img = imageCache.get(for: simpleKey) ?? imageCache.get(for: thumbnailKey) {
        DispatchQueue.main.async {
          self.thumbnailImage = img
        }
        return
      }

      guard !isThumbnailLoading else { return }
      
      DispatchQueue.main.async {
        self.isThumbnailLoading = true
      }

      TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(self) { [weak self] image in
        guard let self = self else { return }

        DispatchQueue.main.async {
          self.thumbnailImage = image
          if let img = image {
            self.imageCache.set(img, for: self.identifier)
            self.imageCache.set(img, for: thumbnailKey)
            if self.coverImage == nil {
              self.updateDominantColor(using: img)
            }
          }
          self.isThumbnailLoading = false
        }
      }
    }
  
  func clearCachedImages() {
    imageCache.remove(for: identifier)
    imageCache.remove(for: "\(identifier)_cover")
    imageCache.remove(for: "\(identifier)_thumbnail")
    DispatchQueue.main.async {
      self.coverImage = nil
      self.thumbnailImage = nil
      self.dominantUIColor = .gray
    }
  }
}

extension TPPBook {
  var wrappedCoverImage: UIImage? {
    coverImage
  }
  
  @objc public class func ordinalString(for n: Int) -> String {
    return n.ordinal()
  }
}

// MARK: - Dominant Color (async, off main thread)
private extension TPPBook {
  private static let colorProcessingQueue = DispatchQueue(label: "org.thepalaceproject.dominantcolor", qos: .utility)
  private static let sharedCIContext: CIContext = {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      return CIContext()
    }
    return CIContext(options: [
      .workingColorSpace: colorSpace,
      .outputColorSpace: colorSpace,
      .useSoftwareRenderer: false
    ])
  }()
  
  func updateDominantColor(using image: UIImage) {
    let inputImage = image
    Self.colorProcessingQueue.async { [weak self] in
      guard let self = self else { return }

      autoreleasepool {
        // Skip on low-memory devices to prevent crashes
        let deviceMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        guard deviceMemoryMB >= 1024 else {
          Log.debug(#file, "Skipping dominant color extraction on low-memory device (\(deviceMemoryMB)MB)")
          DispatchQueue.main.async { self.dominantUIColor = .gray }
          return
        }
        
        // Validate input image
        guard inputImage.size.width > 0, inputImage.size.height > 0 else {
          Log.warn(#file, "Invalid image size for dominant color extraction: \(inputImage.size)")
          DispatchQueue.main.async { self.dominantUIColor = .gray }
          return
        }
        
        guard let cgImage = inputImage.cgImage else {
          Log.warn(#file, "No CGImage available for dominant color extraction")
          DispatchQueue.main.async { self.dominantUIColor = .gray }
          return
        }
        
        // Check for corrupted or invalid images
        guard cgImage.width > 0, cgImage.height > 0, cgImage.bitsPerPixel > 0 else {
          Log.warn(#file, "Invalid CGImage properties: width=\(cgImage.width), height=\(cgImage.height), bpp=\(cgImage.bitsPerPixel)")
          DispatchQueue.main.async { self.dominantUIColor = .gray }
          return
        }
        
        let maxDimension: CGFloat = 500
        let scaledImage: UIImage
        
        let imageSize = inputImage.size
        let maxSide = max(imageSize.width, imageSize.height)
        
        if maxSide > maxDimension {
          let scale = maxDimension / maxSide
          let newSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
          
          guard newSize.width > 0, newSize.height > 0, Int(newSize.width) > 0, Int(newSize.height) > 0 else {
            Log.warn(#file, "Invalid scaled size for dominant color: \(newSize)")
            DispatchQueue.main.async { self.dominantUIColor = .gray }
            return
          }
          
          // Use CGContext for thread-safe image resizing (UIGraphicsBeginImageContextWithOptions is NOT thread-safe)
          // Always use sRGB - source images may be CMYK, grayscale, or other formats that don't support alpha
          let colorSpace = CGColorSpaceCreateDeviceRGB()
          
          // Use premultiplied alpha which is universally supported by CGContext with RGB color space
          let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
          
          guard let context = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
          ) else {
            Log.warn(#file, "Failed to create CGContext for dominant color resize")
            DispatchQueue.main.async { self.dominantUIColor = .gray }
            return
          }
          
          context.interpolationQuality = .medium
          context.draw(cgImage, in: CGRect(origin: .zero, size: newSize))
          
          guard let resizedCGImage = context.makeImage() else {
            Log.warn(#file, "Failed to create resized CGImage for dominant color")
            DispatchQueue.main.async { self.dominantUIColor = .gray }
            return
          }
          
          scaledImage = UIImage(cgImage: resizedCGImage, scale: 1.0, orientation: inputImage.imageOrientation)
        } else {
          scaledImage = inputImage
        }
        
        guard let ciImage = CIImage(image: scaledImage) else {
          Log.debug(#file, "Failed to create CIImage from UIImage for book: \(self.identifier)")
          DispatchQueue.main.async { self.dominantUIColor = .gray }
          return
        }

        let extent = ciImage.extent
        guard !extent.isEmpty, extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
          Log.debug(#file, "CIImage has invalid extent for book: \(self.identifier) - \(extent)")
          DispatchQueue.main.async { self.dominantUIColor = .gray }
          return
        }

        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = extent

        guard let outputImage = filter.outputImage else {
          Log.debug(#file, "Failed to generate output image from filter for book: \(self.identifier)")
          DispatchQueue.main.async { self.dominantUIColor = .gray }
          return
        }
        
        guard !outputImage.extent.isEmpty else {
          Log.debug(#file, "Filter output image has empty extent for book: \(self.identifier)")
          DispatchQueue.main.async { self.dominantUIColor = .gray }
          return
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
          Log.debug(#file, "Failed to create sRGB color space for book: \(self.identifier)")
          DispatchQueue.main.async { self.dominantUIColor = .gray }
          return
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        
        // Wrap render in Objective-C exception handler since CoreImage can crash
        let renderBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard renderBounds.width > 0, renderBounds.height > 0 else {
          Log.warn(#file, "Invalid render bounds")
          DispatchQueue.main.async { self.dominantUIColor = .gray }
          return
        }
        
        do {
          Self.sharedCIContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: renderBounds,
            format: .RGBA8,
            colorSpace: colorSpace
          )
          
          let color = UIColor(
            red: CGFloat(bitmap[0]) / 255.0,
            green: CGFloat(bitmap[1]) / 255.0,
            blue: CGFloat(bitmap[2]) / 255.0,
            alpha: CGFloat(bitmap[3]) / 255.0
          )

          DispatchQueue.main.async {
            self.dominantUIColor = color
          }
        } catch {
          Log.warn(#file, "Failed to extract dominant color for \(self.identifier): \(error.localizedDescription)")
          DispatchQueue.main.async {
            self.dominantUIColor = .gray
          }
        }
      }
    }
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
