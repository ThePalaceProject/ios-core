import XCTest
@testable import Palace

class TPPOPDSEntryTests: XCTestCase {

  var entry: TPPOPDSEntry!

  override func setUp() {
    super.setUp()

    let data = try! Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "single_entry", withExtension: "xml")!)
    let feedXML = TPPXML.xml(withData: data)!
    let feed = TPPOPDSFeed(xml: feedXML)!
    entry = feed.entries[0] as? TPPOPDSEntry
    XCTAssertNotNil(entry)
  }

  override func tearDown() {
    entry = nil
    super.tearDown()
  }

  func testHandlesNilInit() {
    XCTAssertNil(TPPOPDSEntry(xml: nil))
  }

  func testAuthorStrings() {
    XCTAssertEqual(entry.authorStrings.count, 2)
    XCTAssertEqual(entry.authorStrings[0], "James, Henry")
    XCTAssertEqual(entry.authorStrings[1], "Author, Fictional")
  }

  func testGroupAttributes() {
    let attributes = entry.groupAttributes
    XCTAssertNotNil(attributes)
    XCTAssertEqual(attributes?.href, URL(string: "http://localhost/group"))
    XCTAssertEqual(attributes?.title, "Example")
  }

  func testIdentifier() {
    XCTAssertEqual(entry.identifier, "http://localhost/works/4c87a3af9d312c5fd2d44403efc57e2b")
  }

  func testLinksPresent() {
    XCTAssertNotNil(entry.links)
  }

  func testTitle() {
    XCTAssertEqual(entry.title, "The American")
  }

  func testUpdated() {
    let date = entry.updated
    let dateComponents = (date as NSDate).utcComponents()
    XCTAssertEqual(dateComponents.year, 2014)
    XCTAssertEqual(dateComponents.month, 6)
    XCTAssertEqual(dateComponents.day, 2)
    XCTAssertEqual(dateComponents.hour, 16)
    XCTAssertEqual(dateComponents.minute, 59)
    XCTAssertEqual(dateComponents.second, 57)
  }
}
