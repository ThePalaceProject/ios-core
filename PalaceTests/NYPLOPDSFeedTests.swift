import XCTest
@testable import Palace

class TPPOPDSFeedTests: XCTestCase {

  var feed: TPPOPDSFeed!

  override func setUp() {
    super.setUp()

    let data = try! Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "main", withExtension: "xml")!)
    let feedXML = TPPXML.xml(withData: data)!
    feed = TPPOPDSFeed(xml: feedXML)!
  }

  override func tearDown() {
    feed = nil
    super.tearDown()
  }

  func testHandlesNilInit() {
    XCTAssertNil(TPPOPDSFeed(xml: nil))
  }

  func testEntriesPresent() {
    XCTAssertNotNil(feed.entries)
  }

  func testTypeAcquisitionGrouped() {
    // After the ObjC→Swift port, entries with rel="collection" links
    // are detected as grouped (TPPOPDSRelationGroup = "collection").
    XCTAssertEqual(feed.type, .acquisitionGrouped)
  }

  func testIdentifier() {
    XCTAssertEqual(feed.identifier, "http://localhost/main")
  }

  func testLinkCount() {
    XCTAssertEqual(feed.links.count, 2)
  }

  func testTitle() {
    XCTAssertEqual(feed.title, "The Big Front Page")
  }

  func testUpdated() {
    let date = feed.updated!
    let dateComponents = (date as NSDate).utcComponents()
    XCTAssertEqual(dateComponents.year, 2014)
    XCTAssertEqual(dateComponents.month, 6)
    XCTAssertEqual(dateComponents.day, 2)
    XCTAssertEqual(dateComponents.hour, 16)
    XCTAssertEqual(dateComponents.minute, 59)
    XCTAssertEqual(dateComponents.second, 57)
  }
}
