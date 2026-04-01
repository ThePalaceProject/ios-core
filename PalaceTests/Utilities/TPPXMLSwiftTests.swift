import XCTest
@testable import Palace

final class TPPXMLSwiftTests: XCTestCase {

  // MARK: - Parsing Valid XML

  func test_parseValidXML_returnsNonNilRoot() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url) else {
      XCTFail("Missing valid.xml test resource")
      return
    }
    let root = TPPXML(data: data)
    XCTAssertNotNil(root, "Valid XML should parse successfully")
  }

  func test_parseValidXML_rootName_isFoo() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url) else {
      XCTFail("Missing valid.xml test resource")
      return
    }
    let root = TPPXML(data: data)
    XCTAssertEqual(root?.name, "foo")
  }

  func test_parseValidXML_rootNamespaceURI_isCorrect() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url) else {
      XCTFail("Missing valid.xml test resource")
      return
    }
    let root = TPPXML(data: data)
    XCTAssertEqual(root?.namespaceURI, "http://example.com")
  }

  func test_parseValidXML_rootQualifiedName() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url) else {
      XCTFail("Missing valid.xml test resource")
      return
    }
    let root = TPPXML(data: data)
    XCTAssertEqual(root?.qualifiedName, "ex:foo")
  }

  func test_parseValidXML_rootHasThreeChildren() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url) else {
      XCTFail("Missing valid.xml test resource")
      return
    }
    let root = TPPXML(data: data)
    XCTAssertEqual(root?.children.count, 3)
  }

  func test_parseValidXML_rootHasNoParent() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url) else {
      XCTFail("Missing valid.xml test resource")
      return
    }
    let root = TPPXML(data: data)
    XCTAssertNil(root?.parent, "Root element should have no parent")
  }

  // MARK: - Parsing Invalid XML

  func test_parseInvalidXML_returnsNil() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "invalid", withExtension: "xml"),
          let data = try? Data(contentsOf: url) else {
      XCTFail("Missing invalid.xml test resource")
      return
    }
    let root = TPPXML(data: data)
    XCTAssertNil(root, "Invalid XML should return nil")
  }

  func test_parseNilData_returnsNil() {
    let root = TPPXML(data: nil)
    XCTAssertNil(root, "nil data should return nil")
  }

  func test_parseEmptyData_returnsNil() {
    let root = TPPXML(data: Data())
    XCTAssertNil(root, "Empty data should return nil")
  }

  // MARK: - Child Access

  func test_childrenWithName_returnsMatchingChildren() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url),
          let root = TPPXML(data: data) else {
      XCTFail("Failed to parse valid.xml")
      return
    }
    let bars = root.childrenWithName("bar")
    XCTAssertEqual(bars.count, 2, "Should find 2 'bar' children")
  }

  func test_childrenWithName_nonexistentName_returnsEmptyArray() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url),
          let root = TPPXML(data: data) else {
      XCTFail("Failed to parse valid.xml")
      return
    }
    let result = root.childrenWithName("nonexistent")
    XCTAssertTrue(result.isEmpty, "Non-existent child name should return empty array")
  }

  func test_firstChildWithName_returnsFirstMatch() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url),
          let root = TPPXML(data: data) else {
      XCTFail("Failed to parse valid.xml")
      return
    }
    let bar = root.firstChild(withName: "bar")
    XCTAssertNotNil(bar)
    XCTAssertEqual(bar?.name, "bar")
  }

  func test_firstChildWithName_nonexistent_returnsNil() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url),
          let root = TPPXML(data: data) else {
      XCTFail("Failed to parse valid.xml")
      return
    }
    let result = root.firstChild(withName: "nonexistent")
    XCTAssertNil(result)
  }

  // MARK: - Attribute Access

  func test_attributes_emptyAttributes_returnsEmptyDictionary() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url),
          let root = TPPXML(data: data) else {
      XCTFail("Failed to parse valid.xml")
      return
    }
    let attributes = root.attributes as? [String: String] ?? [:]
    XCTAssertTrue(attributes.isEmpty, "Root element has no attributes")
  }

  func test_attributes_withAttributes_returnsDictionary() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url),
          let root = TPPXML(data: data) else {
      XCTFail("Failed to parse valid.xml")
      return
    }
    // second bar has a="hello" b="goodbye"
    let bars = root.childrenWithName("bar")
guard bars.count >= 2 else {
      XCTFail("Expected at least 2 bar children")
      return
    }
    let bar1Attrs = bars[1].attributes as? [String: String] ?? [:]
    XCTAssertEqual(bar1Attrs["a"], "hello")
    XCTAssertEqual(bar1Attrs["b"], "goodbye")
  }

  // MARK: - Value Access

  func test_value_returnsTextContent() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "valid", withExtension: "xml"),
          let data = try? Data(contentsOf: url),
          let root = TPPXML(data: data) else {
      XCTFail("Failed to parse valid.xml")
      return
    }
    let bars = root.childrenWithName("bar")
guard bars.count >= 2 else {
      XCTFail("Expected at least 2 bar children")
      return
    }
    XCTAssertEqual(bars[1].value, "100")
  }

  // MARK: - Inline XML Parsing

  func test_parseInlineXML_simpleElement() {
    let xmlString = "<root><child>value</child></root>"
    guard let data = xmlString.data(using: .utf8) else {
      XCTFail("Failed to create data from string")
      return
    }
    let root = TPPXML(data: data)
    XCTAssertNotNil(root)
    XCTAssertEqual(root?.name, "root")
    let child = root?.firstChild(withName: "child")
    XCTAssertEqual(child?.value, "value")
  }
}
