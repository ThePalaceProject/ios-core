import XCTest
import PalaceCatalog
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

  /// Init contract: XML missing the required `id` element must yield nil
  /// (init? short-circuits the partial parse). Pair both an empty <entry/>
  /// AND an entry with everything-but-id so a mutant that only checks
  /// "is empty" but not "has id" fails on the second case.
  func testInit_returnsNilWhenRequiredIdElementIsMissing() {
    let empty = TPPXML(data: "<entry></entry>".data(using: .utf8)!)!
    XCTAssertNil(TPPOPDSEntry(xml: empty),
                 "Empty <entry/> must yield nil — required 'id' is missing")

    let titleButNoId = TPPXML(data: "<entry><title>Has Title</title></entry>".data(using: .utf8)!)!
    XCTAssertNil(TPPOPDSEntry(xml: titleButNoId),
                 "Entry with title but no id must still yield nil — id is the load-bearing requirement")
  }

  func testAuthorStrings() {
    XCTAssertEqual(entry.authorStrings.count, 2)
    XCTAssertEqual(entry.authorStrings[0], "James, Henry")
    XCTAssertEqual(entry.authorStrings[1], "Author, Fictional")
  }

  func testGroupAttributes() {
    // After the ObjC→Swift port, TPPOPDSRelationGroup = "collection".
    // The first link with rel="collection" in the XML is the Nonfiction lane.
    let attributes = entry.groupAttributes
    XCTAssertNotNil(attributes)
    XCTAssertEqual(attributes?.href, URL(string: "http://localhost/lanes/Nonfiction"))
    XCTAssertEqual(attributes?.title, "Nonfiction")
  }

  /// `single_entry.xml` is a known-shape fixture. Lock the parsed entry's
  /// scalar fields (identifier, title, links non-empty) in one body so a
  /// mutant that breaks any single field's parse fails here on a single
  /// test instead of three near-identical tests.
  func testEntryFromSingleEntryFixture_parsesAllScalarFields() {
    XCTAssertEqual(entry.identifier,
                   "http://localhost/works/4c87a3af9d312c5fd2d44403efc57e2b",
                   "Identifier must come from <id> element verbatim")
    XCTAssertEqual(entry.title, "The American",
                   "Title must come from <title> element verbatim")
    XCTAssertNotNil(entry.links,
                    "Links array must be present after parse")
    XCTAssertGreaterThan(entry.links.count, 0,
                         "single_entry.xml has multiple <link> elements; entry must surface them")
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
