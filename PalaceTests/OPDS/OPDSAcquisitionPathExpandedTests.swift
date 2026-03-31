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
    XCTAssertFalse(feed.title.isEmpty)
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
    XCTAssertFalse(feed.identifier.isEmpty)
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
    XCTAssertEqual(entry.links.count, 6, "Entry should have 6 links")
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

  func test_entryInitWithNilXML_returnsNil() {
    let entry = TPPOPDSEntry(xml: nil)
    XCTAssertNil(entry, "Entry should be nil when initialized with nil XML")
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

  // MARK: - Acquisition Dictionary Roundtrip

  func test_acquisitionFromSingleEntry_dictionaryRoundtrip() {
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
    let restored = TPPOPDSAcquisition(dictionary: dict)
    XCTAssertNotNil(restored, "Should restore acquisition from dictionary")
    XCTAssertEqual(restored?.relation, acquisition.relation)
    XCTAssertEqual(restored?.type, acquisition.type)
    XCTAssertEqual(restored?.hrefURL, acquisition.hrefURL)
  }
}
