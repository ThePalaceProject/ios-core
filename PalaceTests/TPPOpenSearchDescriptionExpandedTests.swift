import XCTest
@testable import Palace

final class TPPOpenSearchDescriptionExpandedTests: XCTestCase {

  // MARK: - Init with XML

  func test_initWithXML_validOpenSearchXML_returnsNonNil() {
    let xmlString = """
    <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
      <Description>Search the library</Description>
      <Url type="application/atom+xml;profile=opds-catalog" template="https://example.com/search?q={searchTerms}"/>
    </OpenSearchDescription>
    """
    guard let data = xmlString.data(using: .utf8),
          let xml = TPPXML(data: data) else {
      XCTFail("Failed to create XML from string")
      return
    }
    let description = TPPOpenSearchDescription(xml: xml)
    XCTAssertNotNil(description, "Should parse valid OpenSearch XML")
    XCTAssertEqual(description?.humanReadableDescription, "Search the library")
  }

  func test_initWithXML_missingDescription_returnsNil() {
    let xmlString = """
    <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
      <Url type="application/atom+xml;profile=opds-catalog" template="https://example.com/search?q={searchTerms}"/>
    </OpenSearchDescription>
    """
    guard let data = xmlString.data(using: .utf8),
          let xml = TPPXML(data: data) else {
      XCTFail("Failed to create XML from string")
      return
    }
    let description = TPPOpenSearchDescription(xml: xml)
    XCTAssertNil(description, "Should return nil when Description element is missing")
  }

  func test_initWithXML_missingOPDSUrl_returnsNil() {
    let xmlString = """
    <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
      <Description>Search the library</Description>
      <Url type="text/html" template="https://example.com/search?q={searchTerms}"/>
    </OpenSearchDescription>
    """
    guard let data = xmlString.data(using: .utf8),
          let xml = TPPXML(data: data) else {
      XCTFail("Failed to create XML from string")
      return
    }
    let description = TPPOpenSearchDescription(xml: xml)
    XCTAssertNil(description, "Should return nil when no OPDS URL is present")
  }

  // MARK: - Init with Title and Books

  func test_initWithTitle_setsDescriptionAndBooks() {
    let books: [Any] = ["book1", "book2"]
    let description = TPPOpenSearchDescription(title: "My Search", books: books)
    XCTAssertNotNil(description)
    XCTAssertEqual(description.humanReadableDescription, "My Search")
    XCTAssertEqual(description.books?.count, 2)
  }

  func test_initWithTitle_emptyBooks_setsEmptyBooks() {
    let description = TPPOpenSearchDescription(title: "Search", books: [])
    XCTAssertNotNil(description)
    XCTAssertEqual(description.books?.count, 0)
  }

  // MARK: - URL Generation

  func test_opdsURLForSearching_encodesSpecialCharacters() {
    let description = TPPOpenSearchDescription(title: "title", books: [])
    description.opdsURLTemplate = "https://example.com/search?q={searchTerms}"
    let url = description.opdsURL(forSearchingString: "hello world")
    XCTAssertNotNil(url)
    XCTAssertTrue(url!.absoluteString.contains("hello%20world"))
  }

  func test_opdsURLForSearching_encodesAmpersand() {
    let description = TPPOpenSearchDescription(title: "title", books: [])
    description.opdsURLTemplate = "https://example.com/search?q={searchTerms}"
    let url = description.opdsURL(forSearchingString: "cats & dogs")
    XCTAssertNotNil(url)
    XCTAssertTrue(url!.absoluteString.contains("%26"))
  }

  func test_opdsURLForSearching_encodesUnicode() {
    let description = TPPOpenSearchDescription(title: "title", books: [])
    description.opdsURLTemplate = "https://example.com/search?q={searchTerms}"
    let url = description.opdsURL(forSearchingString: "caf\u{00e9}")
    XCTAssertNotNil(url)
    XCTAssertTrue(url!.absoluteString.contains("caf%C3%A9"))
  }

  func test_opdsURLForSearching_preservesEntrypoint() {
    let description = TPPOpenSearchDescription(title: "title", books: [])
    description.opdsURLTemplate = "https://example.com/search/?entrypoint=All&q={searchTerms}"
    let url = description.opdsURL(forSearchingString: "test")
    XCTAssertNotNil(url)
    XCTAssertTrue(url!.absoluteString.contains("entrypoint=All"))
    XCTAssertTrue(url!.absoluteString.contains("q=test"))
  }

  func test_opdsURLForSearching_emptyString_returnsURL() {
    let description = TPPOpenSearchDescription(title: "title", books: [])
    description.opdsURLTemplate = "https://example.com/search?q={searchTerms}"
    let url = description.opdsURL(forSearchingString: "")
    XCTAssertNotNil(url, "Empty search string should still produce a valid URL")
  }
}
