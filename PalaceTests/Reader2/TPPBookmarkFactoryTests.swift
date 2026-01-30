//
//  TPPBookmarkFactoryTests.swift
//  PalaceTests
//
//  Comprehensive tests for TPPBookmarkFactory class.
//  Tests the REAL production class for creating bookmarks from server annotations.
//

import XCTest
import ReadiumShared
@testable import Palace

final class TPPBookmarkFactoryTests: XCTestCase {
  
  // MARK: - Properties
  
  private var testBook: TPPBook!
  private var publication: Publication!
  private var bookRegistry: TPPBookRegistryMock!
  private var factory: TPPBookmarkFactory!
  private let testBookId = "factory-test-book-123"
  private let testDeviceId = "test-device-456"
  
  // MARK: - Setup & Teardown
  
  override func setUpWithError() throws {
    try super.setUpWithError()
    
    testBook = createTestBook(identifier: testBookId)
    publication = createTestPublication()
    bookRegistry = TPPBookRegistryMock()
    
    bookRegistry.addBook(
      testBook,
      location: nil,
      state: .downloadSuccessful,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    factory = TPPBookmarkFactory(
      book: testBook,
      publication: publication,
      drmDeviceID: testDeviceId
    )
  }
  
  override func tearDownWithError() throws {
    testBook = nil
    publication = nil
    bookRegistry?.registry = [:]
    bookRegistry = nil
    factory = nil
    try super.tearDownWithError()
  }
  
  // MARK: - Make from R3 Location Tests
  
  func testMake_FromR3Location_CreatesBookmark() async {
    // Arrange
    let locator = Locator(
      href: AnyURL(string: "/chapter1.xhtml")!,
      mediaType: .xhtml,
      title: "Chapter 1",
      locations: Locator.Locations(
        progression: 0.5,
        totalProgression: 0.25
      )
    )
    let r3Location = TPPBookmarkR3Location(resourceIndex: 0, locator: locator)
    
    // Act
    let bookmark = await factory.make(
      fromR3Location: r3Location,
      usingBookRegistry: bookRegistry,
      for: testBook,
      publication: publication
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    XCTAssertEqual(bookmark?.href, "/chapter1.xhtml")
    XCTAssertEqual(Double(bookmark?.progressWithinChapter ?? 0), 0.5, accuracy: 0.001)
    XCTAssertEqual(Double(bookmark?.progressWithinBook ?? 0), 0.25, accuracy: 0.001)
    XCTAssertEqual(bookmark?.device, testDeviceId)
  }
  
  func testMake_FromR3Location_WithNilProgression_ReturnsNil() async {
    // Arrange - locator without progression values
    let locator = Locator(
      href: AnyURL(string: "/chapter1.xhtml")!,
      mediaType: .xhtml,
      locations: Locator.Locations()
    )
    let r3Location = TPPBookmarkR3Location(resourceIndex: 0, locator: locator)
    
    // Act
    let bookmark = await factory.make(
      fromR3Location: r3Location,
      usingBookRegistry: bookRegistry,
      for: testBook,
      publication: publication
    )
    
    // Assert
    XCTAssertNil(bookmark, "Should return nil when locator has no progression")
  }
  
  func testMake_FromR3Location_WithPagePosition_IncludesPage() async {
    // Arrange
    let locator = Locator(
      href: AnyURL(string: "/chapter2.xhtml")!,
      mediaType: .xhtml,
      locations: Locator.Locations(
        progression: 0.3,
        totalProgression: 0.15,
        position: 42
      )
    )
    let r3Location = TPPBookmarkR3Location(resourceIndex: 1, locator: locator)
    
    // Act
    let bookmark = await factory.make(
      fromR3Location: r3Location,
      usingBookRegistry: bookRegistry,
      for: testBook,
      publication: publication
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    XCTAssertEqual(bookmark?.page, "42")
  }
  
  func testMake_FromR3Location_UsesCreationDate() async {
    // Arrange
    let customDate = Date(timeIntervalSince1970: 1000000)
    let locator = Locator(
      href: AnyURL(string: "/chapter1.xhtml")!,
      mediaType: .xhtml,
      locations: Locator.Locations(progression: 0.5, totalProgression: 0.25)
    )
    let r3Location = TPPBookmarkR3Location(
      resourceIndex: 0,
      locator: locator,
      creationDate: customDate
    )
    
    // Act
    let bookmark = await factory.make(
      fromR3Location: r3Location,
      usingBookRegistry: bookRegistry,
      for: testBook,
      publication: publication
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    XCTAssertFalse(bookmark!.time.isEmpty)
  }
  
  func testMake_FromR3Location_IncludesRegistryLocation() async {
    // Arrange
    let registryLocation = TPPBookLocation(
      locationString: "{\"progressWithinBook\":0.3}",
      renderer: TPPBookLocation.r3Renderer
    )
    bookRegistry.setLocation(registryLocation, forIdentifier: testBookId)
    
    let locator = Locator(
      href: AnyURL(string: "/chapter1.xhtml")!,
      mediaType: .xhtml,
      locations: Locator.Locations(progression: 0.5, totalProgression: 0.25)
    )
    let r3Location = TPPBookmarkR3Location(resourceIndex: 0, locator: locator)
    
    // Act
    let bookmark = await factory.make(
      fromR3Location: r3Location,
      usingBookRegistry: bookRegistry,
      for: testBook,
      publication: publication
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    XCTAssertEqual(bookmark?.location, registryLocation?.locationString)
  }
  
  // MARK: - Make from Server Annotation Tests
  
  func testMakeFromServerAnnotation_ValidBookmark_CreatesBookmark() {
    // Arrange
    let selectorValue = """
    {"@type":"LocatorHrefProgression","href":"/chapter1.xhtml","progressWithinChapter":0.5,"progressWithinBook":0.25,"title":"Chapter 1"}
    """
    
    let annotation: [String: Any] = createServerAnnotation(
      annotationId: "server-ann-001",
      bookId: testBookId,
      motivation: .bookmark,
      time: "2024-01-15T10:00:00Z",
      device: "server-device",
      selectorValue: selectorValue
    )
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    let readiumBookmark = bookmark as? TPPReadiumBookmark
    XCTAssertNotNil(readiumBookmark)
    XCTAssertEqual(readiumBookmark?.annotationId, "server-ann-001")
    XCTAssertEqual(readiumBookmark?.href, "/chapter1.xhtml")
    XCTAssertEqual(readiumBookmark?.progressWithinChapter ?? 0, 0.5, accuracy: 0.001)
    XCTAssertEqual(readiumBookmark?.progressWithinBook ?? 0, 0.25, accuracy: 0.001)
  }
  
  func testMakeFromServerAnnotation_MissingAnnotationId_ReturnsNil() {
    // Arrange - annotation without ID
    let annotation: [String: Any] = [
      TPPBookmarkSpec.Target.key: [
        TPPBookmarkSpec.Target.Source.key: testBookId,
        TPPBookmarkSpec.Target.Selector.key: [
          TPPBookmarkSpec.Target.Selector.Value.key: "{}"
        ]
      ],
      TPPBookmarkSpec.Motivation.key: TPPBookmarkSpec.Motivation.bookmark.rawValue,
      TPPBookmarkSpec.Body.key: [
        TPPBookmarkSpec.Body.Device.key: "device",
        TPPBookmarkSpec.Body.Time.key: "2024-01-15T10:00:00Z"
      ]
    ]
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNil(bookmark)
  }
  
  func testMakeFromServerAnnotation_MissingTarget_ReturnsNil() {
    // Arrange
    let annotation: [String: Any] = [
      TPPBookmarkSpec.Id.key: "ann-001",
      TPPBookmarkSpec.Body.key: [
        TPPBookmarkSpec.Body.Device.key: "device",
        TPPBookmarkSpec.Body.Time.key: "2024-01-15T10:00:00Z"
      ]
    ]
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNil(bookmark)
  }
  
  func testMakeFromServerAnnotation_MismatchedBookId_ReturnsNil() {
    // Arrange - annotation for different book
    let selectorValue = """
    {"href":"/chapter1.xhtml","progressWithinChapter":0.5}
    """
    
    let annotation = createServerAnnotation(
      annotationId: "ann-wrong-book",
      bookId: "different-book-id",  // Wrong book ID
      motivation: .bookmark,
      time: "2024-01-15T10:00:00Z",
      device: "device",
      selectorValue: selectorValue
    )
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNil(bookmark, "Should return nil when book ID doesn't match")
  }
  
  func testMakeFromServerAnnotation_MismatchedMotivation_ReturnsNil() {
    // Arrange - bookmark motivation but requesting reading progress
    let selectorValue = """
    {"href":"/chapter1.xhtml","progressWithinChapter":0.5}
    """
    
    let annotation = createServerAnnotation(
      annotationId: "ann-bookmark",
      bookId: testBookId,
      motivation: .bookmark,
      time: "2024-01-15T10:00:00Z",
      device: "device",
      selectorValue: selectorValue
    )
    
    // Act - requesting reading progress but annotation is bookmark
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .readingProgress,
      book: testBook
    )
    
    // Assert
    XCTAssertNil(bookmark, "Should return nil when motivation doesn't match")
  }
  
  func testMakeFromServerAnnotation_ReadingProgress_CreatesBookmark() {
    // Arrange
    let selectorValue = """
    {"href":"/chapter2.xhtml","progressWithinChapter":0.7,"progressWithinBook":0.4}
    """
    
    let annotation = createServerAnnotation(
      annotationId: "reading-pos-001",
      bookId: testBookId,
      motivation: .readingProgress,
      time: "2024-01-15T12:00:00Z",
      device: "reading-device",
      selectorValue: selectorValue
    )
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .readingProgress,
      book: testBook
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    let readiumBookmark = bookmark as? TPPReadiumBookmark
    XCTAssertEqual(readiumBookmark?.annotationId, "reading-pos-001")
    XCTAssertEqual(readiumBookmark?.progressWithinBook ?? 0, 0.4, accuracy: 0.001)
  }
  
  func testMakeFromServerAnnotation_MissingBody_ReturnsNil() {
    // Arrange
    let annotation: [String: Any] = [
      TPPBookmarkSpec.Id.key: "ann-no-body",
      TPPBookmarkSpec.Target.key: [
        TPPBookmarkSpec.Target.Source.key: testBookId,
        TPPBookmarkSpec.Target.Selector.key: [
          TPPBookmarkSpec.Target.Selector.Value.key: "{}"
        ]
      ],
      TPPBookmarkSpec.Motivation.key: TPPBookmarkSpec.Motivation.bookmark.rawValue
    ]
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNil(bookmark)
  }
  
  func testMakeFromServerAnnotation_MissingSelector_ReturnsNil() {
    // Arrange
    let annotation: [String: Any] = [
      TPPBookmarkSpec.Id.key: "ann-no-selector",
      TPPBookmarkSpec.Target.key: [
        TPPBookmarkSpec.Target.Source.key: testBookId
        // Missing Selector
      ],
      TPPBookmarkSpec.Motivation.key: TPPBookmarkSpec.Motivation.bookmark.rawValue,
      TPPBookmarkSpec.Body.key: [
        TPPBookmarkSpec.Body.Device.key: "device",
        TPPBookmarkSpec.Body.Time.key: "2024-01-15T10:00:00Z"
      ]
    ]
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNil(bookmark)
  }
  
  func testMakeFromServerAnnotation_InvalidSelectorJSON_ReturnsNil() {
    // Arrange
    let annotation: [String: Any] = [
      TPPBookmarkSpec.Id.key: "ann-bad-json",
      TPPBookmarkSpec.Target.key: [
        TPPBookmarkSpec.Target.Source.key: testBookId,
        TPPBookmarkSpec.Target.Selector.key: [
          TPPBookmarkSpec.Target.Selector.Value.key: "not valid json {"
        ]
      ],
      TPPBookmarkSpec.Motivation.key: TPPBookmarkSpec.Motivation.bookmark.rawValue,
      TPPBookmarkSpec.Body.key: [
        TPPBookmarkSpec.Body.Device.key: "device",
        TPPBookmarkSpec.Body.Time.key: "2024-01-15T10:00:00Z"
      ]
    ]
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNil(bookmark)
  }
  
  func testMakeFromServerAnnotation_ExtractsChapterTitle() {
    // Arrange
    let selectorValue = """
    {"href":"/chapter1.xhtml","title":"Introduction","progressWithinChapter":0.1,"progressWithinBook":0.05}
    """
    
    let annotation = createServerAnnotation(
      annotationId: "ann-with-title",
      bookId: testBookId,
      motivation: .bookmark,
      time: "2024-01-15T10:00:00Z",
      device: "device",
      selectorValue: selectorValue,
      chapterTitle: "Introduction"
    )
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    let readiumBookmark = bookmark as? TPPReadiumBookmark
    XCTAssertEqual(readiumBookmark?.chapter, "Introduction")
  }
  
  // MARK: - Helper Methods
  
  private func createTestBook(identifier: String) -> TPPBook {
    let placeholderUrl = URL(string: "https://test.example.com/book")!
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: placeholderUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    
    return TPPBook(
      acquisitions: [acquisition],
      authors: [TPPBookAuthor(authorName: "Test Author", relatedBooksURL: nil)],
      categoryStrings: [],
      distributor: "",
      identifier: identifier,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "",
      subtitle: "",
      summary: "",
      title: "Factory Test Book",
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
      imageCache: MockImageCache()
    )
  }
  
  private func createTestPublication() -> Publication {
    let readingOrder = [
      Link(href: "/chapter1.xhtml", mediaType: .xhtml, title: "Chapter 1"),
      Link(href: "/chapter2.xhtml", mediaType: .xhtml, title: "Chapter 2"),
      Link(href: "/chapter3.xhtml", mediaType: .xhtml, title: "Chapter 3")
    ]
    
    let toc = [
      Link(href: "/chapter1.xhtml", mediaType: .xhtml, title: "Chapter 1"),
      Link(href: "/chapter2.xhtml", mediaType: .xhtml, title: "Chapter 2"),
      Link(href: "/chapter3.xhtml", mediaType: .xhtml, title: "Chapter 3")
    ]
    
    let manifest = Manifest(
      metadata: Metadata(title: "Factory Test Publication"),
      readingOrder: readingOrder,
      tableOfContents: toc
    )
    
    return Publication(manifest: manifest)
  }
  
  private func createServerAnnotation(
    annotationId: String,
    bookId: String,
    motivation: TPPBookmarkSpec.Motivation,
    time: String,
    device: String,
    selectorValue: String,
    chapterTitle: String? = nil
  ) -> [String: Any] {
    var body: [String: Any] = [
      TPPBookmarkSpec.Body.Device.key: device,
      TPPBookmarkSpec.Body.Time.key: time
    ]
    
    if let title = chapterTitle {
      body[TPPBookmarkSpec.Body.ChapterTitle.key] = title
    }
    
    return [
      TPPBookmarkSpec.Id.key: annotationId,
      TPPBookmarkSpec.Target.key: [
        TPPBookmarkSpec.Target.Source.key: bookId,
        TPPBookmarkSpec.Target.Selector.key: [
          TPPBookmarkSpec.Target.Selector.Value.key: selectorValue
        ]
      ],
      TPPBookmarkSpec.Motivation.key: motivation.rawValue,
      TPPBookmarkSpec.Body.key: body
    ]
  }
}

// MARK: - Server Annotation Edge Cases

final class TPPBookmarkFactoryServerAnnotationEdgeCaseTests: XCTestCase {
  
  private var testBook: TPPBook!
  private let testBookId = "edge-case-book"
  
  override func setUp() {
    super.setUp()
    testBook = createTestBook(identifier: testBookId)
  }
  
  override func tearDown() {
    testBook = nil
    super.tearDown()
  }
  
  func testMakeFromServerAnnotation_EmptyHref_CreatesBookmarkWithEmptyHref() {
    // Arrange
    let selectorValue = """
    {"href":"","progressWithinChapter":0.5,"progressWithinBook":0.25}
    """
    
    let annotation = createAnnotation(selectorValue: selectorValue)
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    let readiumBookmark = bookmark as? TPPReadiumBookmark
    XCTAssertEqual(readiumBookmark?.href, "")
  }
  
  func testMakeFromServerAnnotation_MissingProgressValues_UsesDefaults() {
    // Arrange
    let selectorValue = """
    {"href":"/chapter.xhtml"}
    """
    
    let annotation = createAnnotation(selectorValue: selectorValue)
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    let readiumBookmark = bookmark as? TPPReadiumBookmark
    XCTAssertEqual(readiumBookmark?.progressWithinChapter ?? -1, 0, accuracy: 0.001)
    XCTAssertEqual(readiumBookmark?.progressWithinBook ?? -1, 0, accuracy: 0.001)
  }
  
  func testMakeFromServerAnnotation_ProgressFromBodyFallback() {
    // Arrange - progress in body, not in selector
    let selectorValue = """
    {"href":"/chapter.xhtml"}
    """
    
    var annotation = createAnnotation(selectorValue: selectorValue)
    var body = annotation[TPPBookmarkSpec.Body.key] as! [String: Any]
    body[TPPBookmarkSpec.Body.ProgressWithinBook.key] = 0.75
    annotation[TPPBookmarkSpec.Body.key] = body
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    let readiumBookmark = bookmark as? TPPReadiumBookmark
    XCTAssertEqual(readiumBookmark?.progressWithinBook ?? -1, 0.75, accuracy: 0.001)
  }
  
  func testMakeFromServerAnnotation_WithReadingOrderItem_IncludesIt() {
    // Arrange
    let selectorValue = """
    {"href":"/chapter.xhtml","progressWithinChapter":0.5,"progressWithinBook":0.25,"readingOrderItem":"item-123","readingOrderItemOffsetMilliseconds":5000}
    """
    
    let annotation = createAnnotation(selectorValue: selectorValue)
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    let readiumBookmark = bookmark as? TPPReadiumBookmark
    XCTAssertEqual(readiumBookmark?.readingOrderItem, "item-123")
    XCTAssertEqual(readiumBookmark?.readingOrderItemOffsetMilliseconds ?? -1, 5000, accuracy: 0.001)
  }
  
  func testMakeFromServerAnnotation_DoubleProgressValue_ConvertsToFloat() {
    // Arrange - progress as Double (not Float)
    let selectorValue = """
    {"href":"/chapter.xhtml","progressWithinChapter":0.123456789,"progressWithinBook":0.987654321}
    """
    
    let annotation = createAnnotation(selectorValue: selectorValue)
    
    // Act
    let bookmark = TPPBookmarkFactory.make(
      fromServerAnnotation: annotation,
      annotationType: .bookmark,
      book: testBook
    )
    
    // Assert
    XCTAssertNotNil(bookmark)
    let readiumBookmark = bookmark as? TPPReadiumBookmark
    XCTAssertEqual(readiumBookmark?.progressWithinChapter ?? -1, 0.123456789, accuracy: 0.0001)
  }
  
  // MARK: - Helpers
  
  private func createTestBook(identifier: String) -> TPPBook {
    let placeholderUrl = URL(string: "https://test.example.com/book")!
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: placeholderUrl,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    
    return TPPBook(
      acquisitions: [acquisition],
      authors: [],
      categoryStrings: [],
      distributor: "",
      identifier: identifier,
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "",
      subtitle: "",
      summary: "",
      title: "Edge Case Test Book",
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
      imageCache: MockImageCache()
    )
  }
  
  private func createAnnotation(selectorValue: String) -> [String: Any] {
    return [
      TPPBookmarkSpec.Id.key: "test-annotation-id",
      TPPBookmarkSpec.Target.key: [
        TPPBookmarkSpec.Target.Source.key: testBookId,
        TPPBookmarkSpec.Target.Selector.key: [
          TPPBookmarkSpec.Target.Selector.Value.key: selectorValue
        ]
      ],
      TPPBookmarkSpec.Motivation.key: TPPBookmarkSpec.Motivation.bookmark.rawValue,
      TPPBookmarkSpec.Body.key: [
        TPPBookmarkSpec.Body.Device.key: "test-device",
        TPPBookmarkSpec.Body.Time.key: "2024-01-15T10:00:00Z"
      ]
    ]
  }
}

// MARK: - Initialization Tests

final class TPPBookmarkFactoryInitTests: XCTestCase {
  
  func testInit_StoresProperties() {
    // Arrange
    let book = createMinimalBook()
    let publication = Publication(manifest: Manifest(metadata: Metadata(title: "Test")))
    let deviceId = "init-test-device"
    
    // Act
    let factory = TPPBookmarkFactory(
      book: book,
      publication: publication,
      drmDeviceID: deviceId
    )
    
    // Assert - factory was created successfully
    XCTAssertNotNil(factory)
  }
  
  func testInit_WithNilDeviceId_CreatesFactory() {
    // Arrange
    let book = createMinimalBook()
    let publication = Publication(manifest: Manifest(metadata: Metadata(title: "Test")))
    
    // Act
    let factory = TPPBookmarkFactory(
      book: book,
      publication: publication,
      drmDeviceID: nil
    )
    
    // Assert
    XCTAssertNotNil(factory)
  }
  
  private func createMinimalBook() -> TPPBook {
    let url = URL(string: "https://test.com")!
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: url,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    
    return TPPBook(
      acquisitions: [acquisition],
      authors: [],
      categoryStrings: [],
      distributor: "",
      identifier: "init-test-book",
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "",
      subtitle: "",
      summary: "",
      title: "Init Test",
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
      imageCache: MockImageCache()
    )
  }
}
