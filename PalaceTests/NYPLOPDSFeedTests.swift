import XCTest
import PalaceCatalog
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

  /// Init contract: nil XML produces nil; valid XML produces a non-nil
  /// feed. Pair both branches so a mutant that always-returns nil on init
  /// fails on the positive case from setUp.
  func testInit_nilXMLYieldsNil_validXMLYieldsParsedFeed() {
    XCTAssertNil(TPPOPDSFeed(xml: nil),
                 "Nil XML must short-circuit to nil")
    XCTAssertNotNil(feed,
                    "main.xml fixture must parse successfully (set up at the top of every test)")
  }

  /// `main.xml` is a known-shape fixture. Lock the parsed feed-level
  /// fields (identifier, title, type, link count, entries-array presence)
  /// in one body so a mutant that breaks any single field's parse fails
  /// here without forcing six near-identical tests. The whole test runs
  /// against the same parsed instance, so it's also faster than the prior
  /// six setup→assert loops.
  func testFeedFromMainFixture_parsesAllTopLevelFields() {
    XCTAssertEqual(feed.identifier, "http://localhost/main",
                   "Identifier must come from the <id> element verbatim")
    XCTAssertEqual(feed.title, "The Big Front Page",
                   "Title must come from the <title> element verbatim")
    XCTAssertEqual(feed.type, .acquisitionGrouped,
                   "main.xml has rel='collection' links — must classify as acquisitionGrouped")
    XCTAssertEqual(feed.links.count, 2,
                   "main.xml has exactly 2 top-level links — guards a parse-too-much/too-little mutant")
    XCTAssertNotNil(feed.entries,
                    "Entries array must be present (may be empty, but never nil)")
    XCTAssertGreaterThan(feed.entries.count, 0,
                         "main.xml is a populated fixture; entries must not be empty")
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
