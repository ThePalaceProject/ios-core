//
//  TPPBookMock.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 8/31/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

enum DistributorType: String {
  case OPDSCatalog = "application/atom+xml;type=entry;profile=opds-catalog"
  case AdobeAdept = "application/vnd.adobe.adept+xml"
  case BearerToken = "application/vnd.librarysimplified.bearer-token+json"
  case EpubZip = "application/epub+zip"
  case Findaway = "application/vnd.librarysimplified.findaway.license+json"
  case OpenAccessAudiobook = "application/audiobook+json"
  case OpenAccessPDF = "application/pdf"
  case FeedbooksAudiobook = "application/audiobook+json;profile=\"http://www.feedbooks.com/audiobooks/access-restriction\""
  case OctetStream = "application/octet-stream"
  case OverdriveAudiobook = "application/vnd.overdrive.circulation.api+json;profile=audiobook"
  case ReadiumLCP = "application/vnd.readium.lcp.license.v1.0+json"
  case PDFLCP = "application/pdf+lcp"
  case AudiobookLCP = "application/audiobook+lcp"
  case AudiobookZip = "application/audiobook+zip"
  case Biblioboard = "application/json"
  
  static func randomIdentifier() -> String {
    return UUID().uuidString
  }
}

struct TPPBookMocker {
  
  /// Creates a mock book with RANDOM data - suitable for unit tests
  static func mockBook(distributorType: DistributorType) -> TPPBook {
    let configType = distributorType.rawValue
    
    // Randomly generated values for other fields
    let identifier = DistributorType.randomIdentifier()
    let emptyUrl = URL(string: "http://example.com/\(identifier)")!
    
    let fakeAcquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: configType,
      hrefURL: emptyUrl,
      indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
      availability: TPPOPDSAcquisitionAvailabilityUnlimited.init()
    )
    
    let title = "Title \(identifier.prefix(8))"
    let author = "Author \(identifier.prefix(8))"
    
    // Create image cache with pre-generated TenPrint cover
    let imageCache = MockImageCache()
    let cover = MockImageCache.generateTenPrintCover(title: title, author: author)
    imageCache.set(cover, for: identifier, expiresIn: nil)
    
    let fakeBook = TPPBook(
      acquisitions: [fakeAcquisition],
      authors: [TPPBookAuthor(authorName: author, relatedBooksURL: nil)],
      categoryStrings: ["Category \(identifier)"],
      distributor: "Distributor \(identifier)",
      identifier: identifier,
      imageURL: emptyUrl,
      imageThumbnailURL: emptyUrl,
      published: Date.init(),
      publisher: "Publisher \(identifier)",
      subtitle: "Subtitle \(identifier)",
      summary: "Summary \(identifier)",
      title: title,
      updated: Date.init(),
      annotationsURL: emptyUrl,
      analyticsURL: emptyUrl,
      alternateURL: emptyUrl,
      relatedWorksURL: emptyUrl,
      previewLink: fakeAcquisition,
      seriesURL: emptyUrl,
      revokeURL: emptyUrl,
      reportURL: emptyUrl,
      timeTrackingURL: emptyUrl,
      contributors: [:],
      bookDuration: nil,
      imageCache: imageCache
    )
    
    // Pre-set cover image directly for synchronous snapshot testing
    fakeBook.coverImage = cover
    fakeBook.thumbnailImage = cover
    
    return fakeBook
  }
  
  // MARK: - Simple Mock Book for Unit Tests
  
  /// Creates a simple mock book with configurable title, authors, and updated date
  static func mockBook(
    title: String,
    authors: String? = nil,
    updated: Date = Date()
  ) -> TPPBook {
    let identifier = UUID().uuidString
    let url = URL(string: "http://example.com/\(identifier)")!
    
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: DistributorType.EpubZip.rawValue,
      hrefURL: url,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    
    let authorsList: [TPPBookAuthor]
    if let authors = authors {
      authorsList = [TPPBookAuthor(authorName: authors, relatedBooksURL: nil)]
    } else {
      authorsList = []
    }
    
    return TPPBook(
      acquisitions: [acquisition],
      authors: authorsList,
      categoryStrings: ["Fiction"],
      distributor: "Test",
      identifier: identifier,
      imageURL: url,
      imageThumbnailURL: url,
      published: Date(),
      publisher: "Test Publisher",
      subtitle: nil,
      summary: "Test summary",
      title: title,
      updated: updated,
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: nil,
      revokeURL: nil,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: [:],
      bookDuration: nil,
      imageCache: MockImageCache()
    )
  }
  
  // MARK: - Deterministic Books for Snapshot Testing
  
  /// Fixed reference date for consistent snapshots
  private static let snapshotDate = Date(timeIntervalSince1970: 1704067200) // Jan 1, 2024
  private static let snapshotURL = URL(string: "https://example.com/snapshot")!
  
  /// Creates a mock EPUB book with FIXED data - suitable for snapshot tests
  static func snapshotEPUB() -> TPPBook {
    createSnapshotBook(
      identifier: "snapshot-epub-001",
      title: "The Great Gatsby",
      author: "F. Scott Fitzgerald",
      distributorType: .EpubZip
    )
  }
  
  /// Creates a mock Audiobook with FIXED data - suitable for snapshot tests
  static func snapshotAudiobook() -> TPPBook {
    createSnapshotBook(
      identifier: "snapshot-audiobook-001",
      title: "Pride and Prejudice",
      author: "Jane Austen",
      distributorType: .OpenAccessAudiobook,
      duration: "12:00:00" // 12 hours
    )
  }
  
  /// Creates a mock PDF book with FIXED data - suitable for snapshot tests
  static func snapshotPDF() -> TPPBook {
    createSnapshotBook(
      identifier: "snapshot-pdf-001",
      title: "1984",
      author: "George Orwell",
      distributorType: .OpenAccessPDF
    )
  }
  
  /// Creates a mock book on hold with FIXED data - suitable for snapshot tests
  static func snapshotHoldBook() -> TPPBook {
    let title = "To Kill a Mockingbird"
    let author = "Harper Lee"
    let identifier = "snapshot-hold-001"
    
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: DistributorType.EpubZip.rawValue,
      hrefURL: snapshotURL,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityReserved(
        holdPosition: 3,
        copiesTotal: 5,
        since: snapshotDate,
        until: snapshotDate.addingTimeInterval(86400 * 14)
      )
    )
    
    // Create image cache with pre-generated TenPrint cover
    let imageCache = MockImageCache()
    let cover = MockImageCache.generateTenPrintCover(title: title, author: author)
    imageCache.set(cover, for: identifier, expiresIn: nil)
    
    let book = TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: author, relatedBooksURL: nil)],
      categoryStrings: ["Fiction", "Classic"],
      distributor: "Library",
      identifier: identifier,
      imageURL: snapshotURL,
      imageThumbnailURL: snapshotURL,
      published: snapshotDate,
      publisher: "HarperCollins",
      subtitle: "A Novel",
      summary: "A classic novel about justice and racial inequality.",
      title: title,
      updated: snapshotDate,
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: nil,
      revokeURL: snapshotURL,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: [:],
      bookDuration: nil,
      imageCache: imageCache
    )
    
    // Pre-set cover image directly for synchronous snapshot testing
    book.coverImage = cover
    book.thumbnailImage = cover
    
    return book
  }
  
  /// Creates a snapshot book with customizable properties
  private static func createSnapshotBook(
    identifier: String,
    title: String,
    author: String,
    distributorType: DistributorType,
    duration: String? = nil
  ) -> TPPBook {
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: distributorType.rawValue,
      hrefURL: snapshotURL,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    
    // Create image cache with pre-generated TenPrint cover
    let imageCache = MockImageCache()
    let cover = MockImageCache.generateTenPrintCover(title: title, author: author)
    imageCache.set(cover, for: identifier, expiresIn: nil)
    
    let book = TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: author, relatedBooksURL: nil)],
      categoryStrings: ["Fiction"],
      distributor: "Open Library",
      identifier: identifier,
      imageURL: snapshotURL,
      imageThumbnailURL: snapshotURL,
      published: snapshotDate,
      publisher: "Penguin Classics",
      subtitle: nil,
      summary: "A timeless classic.",
      title: title,
      updated: snapshotDate,
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: nil,
      revokeURL: snapshotURL,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: [:],
      bookDuration: duration,
      imageCache: imageCache
    )
    
    // Pre-set cover image directly for synchronous snapshot testing
    book.coverImage = cover
    book.thumbnailImage = cover
    
    return book
  }
}
