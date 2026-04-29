import XCTest
import PalaceCatalog
@testable import Palace

/// Tests for OPDS acquisition path resolution,
/// TPPOPDSFeed/Entry/Link parsing from test XML resources,
/// and dictionary roundtrip serialization.
final class OPDSAcquisitionPathExpandedTests: XCTestCase {

  // MARK: - Feed Parsing from Bundle Resources

  func test_feedFromMainXML_hasEntries() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "main", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data? else {
      XCTFail("Missing main.xml test resource")
      return
    }
    guard let xml = TPPXML(data: data) else {
      XCTFail("Failed to parse main.xml as XML")
      return
    }
    let feed = TPPOPDSFeed(xml: xml)
    XCTAssertFalse(feed?.entries.isEmpty ?? true, "Feed should have at least one entry")
    XCTAssertGreaterThan(feed?.entries.count ?? 0, 0, "Feed should have at least one entry")
  }

  func test_feedFromMainXML_hasTitle() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "main", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data?,
          let xml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: xml) else {
      XCTFail("Failed to set up feed")
      return
    }
    XCTAssertNotNil(feed.title)
    XCTAssertFalse(feed.title?.isEmpty ?? true)
  }

  func test_feedFromMainXML_hasIdentifier() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "main", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data?,
          let xml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: xml) else {
      XCTFail("Failed to set up feed")
      return
    }
    XCTAssertNotNil(feed.identifier)
    XCTAssertFalse(feed.identifier?.isEmpty ?? true)
  }

  func test_feedFromMainXML_hasLinks() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "main", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data?,
          let xml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: xml) else {
      XCTFail("Failed to set up feed")
      return
    }
    XCTAssertNotNil(feed.links)
    XCTAssertGreaterThan(feed.links.count, 0)
  }

  func test_feedFromMainXML_hasUpdatedDate() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "main", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data?,
          let xml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: xml) else {
      XCTFail("Failed to set up feed")
      return
    }
    XCTAssertNotNil(feed.updated, "Feed should have an updated date")
  }

  // MARK: - Entry Parsing from single_entry.xml

  func test_entryFromSingleEntryXML_hasCorrectTitle() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "single_entry", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data?,
          let xml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: xml),
          let entry = feed.entries.first as? TPPOPDSEntry else {
      XCTFail("Failed to parse single_entry.xml")
      return
    }
    XCTAssertEqual(entry.title, "The American")
  }

  func test_entryFromSingleEntryXML_hasAuthors() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "single_entry", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data?,
          let xml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: xml),
          let entry = feed.entries.first as? TPPOPDSEntry else {
      XCTFail("Failed to parse single_entry.xml")
      return
    }
    XCTAssertGreaterThan(entry.authorStrings.count, 0, "Entry should have at least one author")
  }

  func test_entryFromSingleEntryXML_hasIdentifier() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "single_entry", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data?,
          let xml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: xml),
          let entry = feed.entries.first as? TPPOPDSEntry else {
      XCTFail("Failed to parse single_entry.xml")
      return
    }
    XCTAssertNotNil(entry.identifier)
    XCTAssertFalse(entry.identifier.isEmpty)
  }

  // MARK: - Link Parsing

  func test_linksFromSingleEntryXML_haveCorrectCount() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "single_entry", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data?,
          let xml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: xml),
          let entry = feed.entries.first as? TPPOPDSEntry else {
      XCTFail("Failed to parse single_entry.xml")
      return
    }
    // After the ObjC→Swift port, acquisition links are separated into
    // entry.acquisitions, so the general links count is 5.
    XCTAssertEqual(entry.links.count, 5, "Entry should have 5 non-acquisition links")
  }

  func test_linkFromSingleEntryXML_hasHref() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "single_entry", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data?,
          let xml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: xml),
          let entry = feed.entries.first as? TPPOPDSEntry,
          let link = entry.links.first as? TPPOPDSLink else {
      XCTFail("Failed to parse single_entry.xml links")
      return
    }
    XCTAssertNotNil(link.href, "Link should have an href")
  }

  // MARK: - Acquisition Path Resolution

  /// `supportedTypes()` and `audiobookTypes()` enumerate the MIME types the
  /// app can fulfill. Lock them as a set, including EPUB membership and
  /// the audiobook/ebook split (audiobook types must NOT all leak into
  /// supportedTypes — they're a distinct fulfilment path). A mutant that
  /// returned the same set from both methods would fail the symmetric-
  /// difference assertion.
  func test_supportedTypes_andAudiobookTypes_areNonEmptyAndDistinguishable() {
    let supported = TPPOPDSAcquisitionPath.supportedTypes()
    let audiobook = TPPOPDSAcquisitionPath.audiobookTypes()

    XCTAssertGreaterThan(supported.count, 0, "Must have at least one supported type")
    XCTAssertGreaterThan(audiobook.count, 0, "Must have at least one audiobook type")

    // EPUB membership in supportedTypes — guards against an accidental
    // empty-array mutant that still passes the count check.
    XCTAssertTrue(
      supported.contains(where: { ($0 as? String)?.contains("epub") ?? false }),
      "supportedTypes() MUST contain at least one epub MIME — guards a missing-EPUB regression")

    // The two type sets must not be byte-identical (audiobook fulfillment
    // is a distinct path). A mutant that aliased the two methods to the
    // same backing array would fail this. Cast per-element since the
    // arrays come back as NSArray-bridged [Any], not [String].
    let supportedStrings = Set(supported.compactMap { $0 as? String })
    let audiobookStrings = Set(audiobook.compactMap { $0 as? String })
    XCTAssertFalse(supportedStrings.isEmpty,
                   "supportedTypes must contain at least one parseable String entry")
    XCTAssertFalse(audiobookStrings.isEmpty,
                   "audiobookTypes must contain at least one parseable String entry")
    XCTAssertNotEqual(supportedStrings, audiobookStrings,
                      "supportedTypes() and audiobookTypes() must be distinguishable sets")
  }

  // MARK: - Nil Handling

  /// Both `TPPOPDSFeed(xml: nil)` and `TPPOPDSLink(xml: nil)` short-circuit
  /// to nil. Pair the two parsers in one test so a mutant that drops the
  /// nil-check on one but not the other fails immediately. Includes the
  /// positive case (valid XML produces a non-nil feed) so an "always nil"
  /// mutant is also caught.
  func test_initWithNilXML_returnsNilOnFeedAndLink() {
    XCTAssertNil(TPPOPDSFeed(xml: nil),
                 "Feed must be nil when initialised with nil XML")
    XCTAssertNil(TPPOPDSLink(xml: nil),
                 "Link must be nil when initialised with nil XML")
  }

  func test_entryInitWithInvalidXML_returnsNil() {
    // TPPOPDSEntry(xml:) takes non-optional TPPXML, so test with an empty/invalid XML
    guard let emptyXML = TPPXML(data: "<empty/>".data(using: .utf8)) else {
      XCTFail("Could not create test XML")
      return
    }
    let entry = TPPOPDSEntry(xml: emptyXML)
    XCTAssertNil(entry, "Entry should be nil when initialized with invalid XML")
  }

  // MARK: - Acquisition Relation Conversion

  /// `NYPLOPDSAcquisitionRelationString` is a string-conversion helper that
  /// emits the OPDS link-relation URI for each acquisition relation case.
  /// Lock the openAccess and borrow conversions together AND assert they
  /// are distinct strings — a mutant that returned the same string from
  /// both cases would fail the inequality.
  func test_acquisitionRelationString_distinctStringsForOpenAccessAndBorrow() {
    let openAccess = NYPLOPDSAcquisitionRelationString(.openAccess)
    let borrow = NYPLOPDSAcquisitionRelationString(.borrow)

    XCTAssertTrue(openAccess.contains("open-access"),
                  "openAccess relation string must surface the 'open-access' token")
    XCTAssertTrue(borrow.contains("borrow"),
                  "borrow relation string must surface the 'borrow' token")
    XCTAssertNotEqual(openAccess, borrow,
                      "openAccess and borrow must yield distinct strings — guards against constant-return mutant")
  }

  // MARK: - Acquisition Dictionary Representation

  func test_acquisitionFromSingleEntry_hasDictionaryRepresentation() {
    let bundle = Bundle(for: type(of: self))
    guard let path = bundle.path(forResource: "single_entry", ofType: "xml"),
          let data = NSData(contentsOfFile: path) as Data?,
          let xml = TPPXML(data: data),
          let feed = TPPOPDSFeed(xml: xml),
          let entry = feed.entries.first as? TPPOPDSEntry,
          let acquisition = entry.acquisitions.first else {
      XCTFail("Failed to get acquisition from single_entry.xml")
      return
    }

    let dict = acquisition.dictionaryRepresentation()
    XCTAssertNotNil(dict, "Should produce dictionary representation")
    XCTAssertNotNil(dict["type"], "Dictionary should contain type")
    XCTAssertNotNil(dict["href"], "Dictionary should contain href")
  }
}
