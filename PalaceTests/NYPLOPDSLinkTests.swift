import XCTest
@testable import Palace

class TPPOPDSLinkTests: XCTestCase {

  var links: [TPPOPDSLink]!

  override func setUp() {
    super.setUp()

    let data = try! Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "single_entry", withExtension: "xml")!)
    let feedXML = TPPXML.xml(withData: data)!
    let feed = TPPOPDSFeed(xml: feedXML)!
    let entry = feed.entries[0] as! TPPOPDSEntry
    links = entry.links
    XCTAssertNotNil(links)
  }

  override func tearDown() {
    links = nil
    super.tearDown()
  }

  func testHandlesNilInit() {
    XCTAssertNil(TPPOPDSLink(xml: nil))
  }

  func testCount() {
    // After the ObjC→Swift port, acquisition links are separated into
    // entry.acquisitions rather than entry.links, so the link count
    // drops by 1 (the open-access acquisition is no longer in links).
    XCTAssertEqual(links.count, 5)
  }

  func testLink0() {
    let link = links[0]
    XCTAssertEqual(link.href, URL(string: "http://localhost/works/4c87a3af9d312c5fd2d44403efc57e2b"))
    XCTAssertNil(link.rel)
    XCTAssertNil(link.type)
    XCTAssertNil(link.hreflang)
    XCTAssertNil(link.title)
  }

  // Link1 (acquisition) is now in entry.acquisitions, not entry.links.
  func testLink1() {
    let link = links[1]
    XCTAssertEqual(link.href, URL(string: "http://covers.openlibrary.org/b/id/244619-S.jpg"))
    XCTAssertEqual(link.rel, "http://opds-spec.org/image/thumbnail")
    XCTAssertNil(link.type)
    XCTAssertNil(link.hreflang)
    XCTAssertNil(link.title)
  }

  func testLink2() {
    let link = links[2]
    XCTAssertEqual(link.href, URL(string: "http://covers.openlibrary.org/b/id/244619-L.jpg"))
    XCTAssertEqual(link.rel, "http://opds-spec.org/image")
    XCTAssertNil(link.type)
    XCTAssertNil(link.hreflang)
    XCTAssertNil(link.title)
  }

  func testLink3() {
    let link = links[3]
    XCTAssertEqual(link.href, URL(string: "http://localhost/lanes/Nonfiction"))
    XCTAssertEqual(link.rel, "collection")
    XCTAssertNil(link.type)
    XCTAssertNil(link.hreflang)
    XCTAssertEqual(link.title, "Nonfiction")
  }

  func testLink4() {
    let link = links[4]
    XCTAssertEqual(link.href, URL(string: "http://localhost/group"))
    XCTAssertEqual(link.rel, "http://opds-spec.org/group")
    XCTAssertNil(link.type)
    XCTAssertNil(link.hreflang)
    XCTAssertEqual(link.title, "Example")
  }
}
