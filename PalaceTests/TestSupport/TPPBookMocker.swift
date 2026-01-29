//
//  TPPBookMocker.swift
//  PalaceTests
//
//  Factory methods for creating test books with various configurations.
//  This file extends the existing TPPBookMock.swift with additional convenience
//  methods for the test coverage initiative.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

// MARK: - TPPBookMocker Extensions

extension TPPBookMocker {

  // MARK: - Factory Method with State

  /// Creates a mock book with a specific identifier, state, and optional customizations.
  /// This is the primary factory method for unit tests requiring specific book states.
  /// - Parameters:
  ///   - id: Unique identifier for the book
  ///   - state: The book state (used for registry, not stored on book itself)
  ///   - title: Book title (defaults to generated value)
  ///   - author: Book author (defaults to "Test Author")
  ///   - distributorType: Content type for acquisitions
  /// - Returns: A configured TPPBook instance
  static func book(
    id: String,
    state: TPPBookState = .unregistered,
    title: String? = nil,
    author: String = "Test Author",
    distributorType: DistributorType = .EpubZip
  ) -> TPPBook {
    let bookTitle = title ?? "Book \(id.prefix(8))"
    let acquisitionUrl = URL(string: "http://example.com/\(id)")!

    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: distributorType.rawValue,
      hrefURL: acquisitionUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let imageCache = MockImageCache()
    let cover = MockImageCache.generateTenPrintCover(title: bookTitle, author: author)
    imageCache.set(cover, for: id, expiresIn: nil)

    let book = TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: author, relatedBooksURL: nil)],
      categoryStrings: ["Fiction"],
      distributor: "Test Distributor",
      identifier: id,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "Test Publisher",
      subtitle: nil,
      summary: "Test summary for \(bookTitle)",
      title: bookTitle,
      updated: Date(),
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
      imageCache: imageCache
    )

    book.coverImage = cover
    book.thumbnailImage = cover

    return book
  }

  // MARK: - Batch Book Creation

  /// Creates multiple mock books with sequential identifiers.
  /// Useful for testing list views, pagination, and bulk operations.
  /// - Parameters:
  ///   - count: Number of books to create
  ///   - prefix: Prefix for book identifiers (default: "book")
  ///   - distributorType: Content type for all books
  /// - Returns: Array of TPPBook instances
  static func books(
    count: Int,
    prefix: String = "book",
    distributorType: DistributorType = .EpubZip
  ) -> [TPPBook] {
    (0..<count).map { index in
      book(
        id: "\(prefix)-\(String(format: "%03d", index))",
        title: "Test Book \(index + 1)",
        distributorType: distributorType
      )
    }
  }

  /// Creates a mixed collection of books with different types.
  /// Useful for testing heterogeneous book lists.
  /// - Parameter count: Total number of books (distributed among types)
  /// - Returns: Array containing EPUBs, audiobooks, and PDFs
  static func mixedBooks(count: Int) -> [TPPBook] {
    var books: [TPPBook] = []
    let typesCount = 3

    for i in 0..<count {
      let type: DistributorType
      switch i % typesCount {
      case 0: type = .EpubZip
      case 1: type = .OpenAccessAudiobook
      case 2: type = .OpenAccessPDF
      default: type = .EpubZip
      }

      books.append(book(
        id: "mixed-\(String(format: "%03d", i))",
        title: "Mixed Book \(i + 1)",
        distributorType: type
      ))
    }

    return books
  }

  // MARK: - Availability-Specific Books

  /// Creates a book that is available to borrow (has "borrow" relation).
  static func borrowableBook(
    id: String = "borrowable-001",
    title: String = "Borrowable Book"
  ) -> TPPBook {
    let acquisitionUrl = URL(string: "http://example.com/borrow/\(id)")!

    let acquisition = TPPOPDSAcquisition(
      relation: .borrow,
      type: DistributorType.EpubZip.rawValue,
      hrefURL: acquisitionUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let imageCache = MockImageCache()
    let cover = MockImageCache.generateTenPrintCover(title: title, author: "Test Author")
    imageCache.set(cover, for: id, expiresIn: nil)

    let book = TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: "Test Author", relatedBooksURL: nil)],
      categoryStrings: ["Fiction"],
      distributor: "Library",
      identifier: id,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "Test Publisher",
      subtitle: nil,
      summary: "A book available to borrow",
      title: title,
      updated: Date(),
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
      imageCache: imageCache
    )

    book.coverImage = cover
    book.thumbnailImage = cover

    return book
  }

  /// Creates an open access book (free, no DRM).
  static func openAccessBook(
    id: String = "open-access-001",
    title: String = "Open Access Book"
  ) -> TPPBook {
    let acquisitionUrl = URL(string: "http://example.com/open/\(id)")!

    let acquisition = TPPOPDSAcquisition(
      relation: .openAccess,
      type: DistributorType.EpubZip.rawValue,
      hrefURL: acquisitionUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let imageCache = MockImageCache()
    let cover = MockImageCache.generateTenPrintCover(title: title, author: "Public Domain")
    imageCache.set(cover, for: id, expiresIn: nil)

    let book = TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: "Public Domain", relatedBooksURL: nil)],
      categoryStrings: ["Classics"],
      distributor: "Open Library",
      identifier: id,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "Public Domain",
      subtitle: nil,
      summary: "A free open access book",
      title: title,
      updated: Date(),
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
      imageCache: imageCache
    )

    book.coverImage = cover
    book.thumbnailImage = cover

    return book
  }

  // MARK: - DRM-Specific Books

  /// Creates a book with Adobe DRM acquisition path.
  static func adobeDRMBook(
    id: String = "adobe-drm-001",
    title: String = "Adobe DRM Book"
  ) -> TPPBook {
    mockBook(identifier: id, title: title, distributorType: .AdobeAdept)
  }

  /// Creates a book with LCP DRM acquisition path.
  static func lcpBook(
    id: String = "lcp-001",
    title: String = "LCP Book"
  ) -> TPPBook {
    mockBook(identifier: id, title: title, distributorType: .ReadiumLCP)
  }

  /// Creates a book with Findaway audiobook DRM.
  static func findawayBook(
    id: String = "findaway-001",
    title: String = "Findaway Audiobook"
  ) -> TPPBook {
    let acquisitionUrl = URL(string: "http://example.com/findaway/\(id)")!

    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: DistributorType.Findaway.rawValue,
      hrefURL: acquisitionUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let imageCache = MockImageCache()
    let cover = MockImageCache.generateTenPrintCover(title: title, author: "Audiobook Author")
    imageCache.set(cover, for: id, expiresIn: nil)

    let book = TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: "Audiobook Author", relatedBooksURL: nil)],
      categoryStrings: ["Fiction"],
      distributor: "Findaway",
      identifier: id,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "Audio Publisher",
      subtitle: nil,
      summary: "A Findaway audiobook",
      title: title,
      updated: Date(),
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: nil,
      revokeURL: nil,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: ["nrt": ["John Narrator"]],
      bookDuration: "08:30:00",
      imageCache: imageCache
    )

    book.coverImage = cover
    book.thumbnailImage = cover

    return book
  }

  // MARK: - Books with Specific Metadata

  /// Creates a book with multiple authors.
  static func multiAuthorBook(
    id: String = "multi-author-001",
    title: String = "Multi-Author Book",
    authors: [String] = ["Author One", "Author Two", "Author Three"]
  ) -> TPPBook {
    let acquisitionUrl = URL(string: "http://example.com/\(id)")!

    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: DistributorType.EpubZip.rawValue,
      hrefURL: acquisitionUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let bookAuthors = authors.map { TPPBookAuthor(authorName: $0, relatedBooksURL: nil) }

    let imageCache = MockImageCache()
    let cover = MockImageCache.generateTenPrintCover(title: title, author: authors.first ?? "Unknown")
    imageCache.set(cover, for: id, expiresIn: nil)

    let book = TPPBook(
      acquisitions: [acquisition],
      authors: bookAuthors,
      categoryStrings: ["Fiction"],
      distributor: "Test",
      identifier: id,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "Test Publisher",
      subtitle: nil,
      summary: "A book with multiple authors",
      title: title,
      updated: Date(),
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
      imageCache: imageCache
    )

    book.coverImage = cover
    book.thumbnailImage = cover

    return book
  }

  /// Creates a book that is part of a series.
  static func seriesBook(
    id: String = "series-001",
    title: String = "Series Book",
    seriesURL: URL = URL(string: "http://example.com/series/1")!
  ) -> TPPBook {
    let acquisitionUrl = URL(string: "http://example.com/\(id)")!

    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: DistributorType.EpubZip.rawValue,
      hrefURL: acquisitionUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let imageCache = MockImageCache()
    let cover = MockImageCache.generateTenPrintCover(title: title, author: "Series Author")
    imageCache.set(cover, for: id, expiresIn: nil)

    let book = TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: "Series Author", relatedBooksURL: nil)],
      categoryStrings: ["Fiction", "Series"],
      distributor: "Test",
      identifier: id,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "Test Publisher",
      subtitle: "Book 1 of the Series",
      summary: "First book in an exciting series",
      title: title,
      updated: Date(),
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: seriesURL,
      revokeURL: nil,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: [:],
      bookDuration: nil,
      imageCache: imageCache
    )

    book.coverImage = cover
    book.thumbnailImage = cover

    return book
  }

  // MARK: - Audiobook with Duration

  /// Creates an audiobook with specified duration string.
  /// - Parameters:
  ///   - id: Book identifier
  ///   - title: Book title
  ///   - duration: Duration string (e.g., "12:30:00" for 12.5 hours)
  ///   - narrators: Array of narrator names
  static func audiobook(
    id: String = "audiobook-001",
    title: String = "Test Audiobook",
    duration: String = "10:00:00",
    narrators: [String] = ["John Narrator"]
  ) -> TPPBook {
    let acquisitionUrl = URL(string: "http://example.com/audio/\(id)")!

    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: DistributorType.OpenAccessAudiobook.rawValue,
      hrefURL: acquisitionUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let imageCache = MockImageCache()
    let cover = MockImageCache.generateTenPrintCover(title: title, author: "Audiobook Author")
    imageCache.set(cover, for: id, expiresIn: nil)

    let book = TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: "Audiobook Author", relatedBooksURL: nil)],
      categoryStrings: ["Fiction", "Audiobook"],
      distributor: "Audio Publisher",
      identifier: id,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "Audio Publisher",
      subtitle: nil,
      summary: "An audiobook with narration",
      title: title,
      updated: Date(),
      annotationsURL: nil,
      analyticsURL: nil,
      alternateURL: nil,
      relatedWorksURL: nil,
      previewLink: nil,
      seriesURL: nil,
      revokeURL: nil,
      reportURL: nil,
      timeTrackingURL: nil,
      contributors: ["nrt": narrators],
      bookDuration: duration,
      imageCache: imageCache
    )

    book.coverImage = cover
    book.thumbnailImage = cover

    return book
  }
}
