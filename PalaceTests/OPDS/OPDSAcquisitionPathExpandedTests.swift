import XCTest
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
    XCTAssertNotNil(feed, "Should parse a valid OPDS feed")
    XCTAssertNotNil(feed?.entries, "Feed should have entries")
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

  func test_supportedTypes_isNonEmpty() {
    let types = TPPOPDSAcquisitionPath.supportedTypes()
    XCTAssertGreaterThan(types.count, 0, "Should have at least one supported type")
  }

  func test_supportedTypes_containsEPUB() {
    let types = TPPOPDSAcquisitionPath.supportedTypes()
    let containsEpub = types.contains(where: { ($0 as? String)?.contains("epub") ?? false })
    XCTAssertTrue(containsEpub, "Supported types should include EPUB")
  }

  func test_audiobookTypes_isNonEmpty() {
    let types = TPPOPDSAcquisitionPath.audiobookTypes()
    XCTAssertGreaterThan(types.count, 0, "Should have at least one audiobook type")
  }

  // MARK: - Nil Handling

  func test_feedInitWithNilXML_returnsNil() {
    let feed = TPPOPDSFeed(xml: nil)
    XCTAssertNil(feed, "Feed should be nil when initialized with nil XML")
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

  func test_linkInitWithNilXML_returnsNil() {
    let link = TPPOPDSLink(xml: nil)
    XCTAssertNil(link, "Link should be nil when initialized with nil XML")
  }

  // MARK: - Acquisition Relation Conversion

  func test_acquisitionRelationString_openAccess() {
    let str = NYPLOPDSAcquisitionRelationString(.openAccess)
    XCTAssertTrue(str.contains("open-access"), "Open access relation should contain 'open-access'")
  }

  func test_acquisitionRelationString_borrow() {
    let str = NYPLOPDSAcquisitionRelationString(.borrow)
    XCTAssertTrue(str.contains("borrow"), "Borrow relation should contain 'borrow'")
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
