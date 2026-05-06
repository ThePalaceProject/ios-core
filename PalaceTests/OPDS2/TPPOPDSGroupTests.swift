import XCTest
@testable import Palace

class TPPOPDSGroupSwiftTests: XCTestCase {

  func testInitStoresProperties() {
    let href = URL(string: "https://example.com/group")!
    let group = TPPOPDSGroup(entries: [], href: href, title: "Group Title")

    XCTAssertEqual(group.href, href)
    XCTAssertEqual(group.title, "Group Title")
    XCTAssertEqual(group.entries.count, 0)
  }

  func testInitStoresEntries() {
    let href = URL(string: "https://example.com/group")!
    // Create two minimal entries to verify the entries array is stored correctly
    let entryHref = URL(string: "https://example.com/book1")!
    let acquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: entryHref,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    let book = TPPBook(
      acquisitions: [acquisition],
      authors: [],
      categoryStrings: [],
      distributor: "",
      identifier: "group-entry-1",
      imageURL: nil,
      imageThumbnailURL: nil,
      published: Date(),
      publisher: "",
      subtitle: "",
      summary: "",
      title: "Group Entry One",
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

    let group = TPPOPDSGroup(entries: [book], href: href, title: "Books With Entries")

    XCTAssertEqual(group.entries.count, 1, "Group should store exactly one entry")
    XCTAssertEqual((group.entries.first as? TPPBook)?.identifier, "group-entry-1",
                   "The stored entry should match the book passed in")
    XCTAssertEqual(group.title, "Books With Entries")
    XCTAssertEqual(group.href, href)
  }

  func testInitWithDifferentHref_storesDifferentHref() {
    let href1 = URL(string: "https://example.com/group1")!
    let href2 = URL(string: "https://example.com/group2")!

    let group1 = TPPOPDSGroup(entries: [], href: href1, title: "Group 1")
    let group2 = TPPOPDSGroup(entries: [], href: href2, title: "Group 2")

    XCTAssertNotEqual(group1.href, group2.href, "Groups with different hrefs must not share the same href")
    XCTAssertNotEqual(group1.title, group2.title, "Groups with different titles must not share the same title")
    XCTAssertEqual(group1.entries.count, 0)
    XCTAssertEqual(group2.entries.count, 0)
  }
}
