import XCTest
@testable import Palace

class TPPXMLTests: XCTestCase {

  func testValid() {
    let root = TPPXML.xml(withData: try! Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "valid", withExtension: "xml")!))!

    XCTAssertEqual(root.attributes as! [String: String], [:])
    XCTAssertEqual(root.children.count, 3)
    XCTAssertEqual(root.name, "foo")
    XCTAssertEqual(root.namespaceURI, "http://example.com")
    XCTAssertNil(root.parent)
    XCTAssertEqual(root.qualifiedName, "ex:foo")
    XCTAssertNotNil(root.value)

    let bar0 = root.children[0]
    XCTAssertEqual(bar0.attributes as! [String: String], [:])
    XCTAssertNotNil(bar0.children)
    XCTAssertEqual(bar0.children.count, 0)
    XCTAssertEqual(bar0.name, "bar")
    XCTAssertEqual(bar0.namespaceURI, "")
    XCTAssertEqual(bar0.parent, root)
    XCTAssertEqual(bar0.qualifiedName, "bar")
    XCTAssertEqual(bar0.value, "\n    42\n  ")

    let bar1 = root.children[1]
    let bar1Attributes = ["a": "hello", "b": "goodbye"]
    XCTAssertEqual(bar1.attributes as! [String: String], bar1Attributes)
    XCTAssertNotNil(bar1.children)
    XCTAssertEqual(bar1.children.count, 0)
    XCTAssertEqual(bar1.name, "bar")
    XCTAssertEqual(bar1.namespaceURI, "")
    XCTAssertEqual(bar1.parent, root)
    XCTAssertEqual(bar1.qualifiedName, "bar")
    XCTAssertEqual(bar1.value, "100")

    let baz = root.children[2]
    XCTAssertEqual(baz.attributes as! [String: String], [:])
    XCTAssertEqual(baz.children.count, 2)
    XCTAssertEqual(baz.name, "baz")
    XCTAssertEqual(baz.namespaceURI, "")
    XCTAssertEqual(baz.parent, root)
    XCTAssertEqual(baz.qualifiedName, "baz")
    XCTAssertEqual(baz.value, "\n    one\n    \n    two\n    \n  ")

    let quux0 = baz.children[0]
    XCTAssertEqual(quux0.attributes as! [String: String], [:])
    XCTAssertNotNil(quux0.children)
    XCTAssertEqual(quux0.children.count, 0)
    XCTAssertEqual(quux0.name, "quux")
    XCTAssertEqual(quux0.namespaceURI, "")
    XCTAssertEqual(quux0.parent, baz)
    XCTAssertEqual(quux0.qualifiedName, "quux")
    XCTAssertEqual(quux0.value, "")

    let quux1 = baz.children[1]
    XCTAssertEqual(quux1.attributes as! [String: String], [:])
    XCTAssertNotNil(quux1.children)
    XCTAssertEqual(quux1.children.count, 0)
    XCTAssertEqual(quux1.name, "quux")
    XCTAssertEqual(quux1.namespaceURI, "")
    XCTAssertEqual(quux1.parent, baz)
    XCTAssertEqual(quux1.qualifiedName, "quux")
    XCTAssertEqual(quux1.value, "\n      three\n    ")

    let bars = [bar0, bar1]
    let quuxes = [quux0, quux1]
    XCTAssertEqual(root.childrenWithName("bar"), bars)
    XCTAssertEqual(root.childrenWithName("baz"), [baz])
    XCTAssertEqual(root.childrenWithName("quux"), [])
    XCTAssertEqual(root.childrenWithName(nil), [])
    XCTAssertEqual(baz.childrenWithName("quux"), quuxes)
    XCTAssertEqual(baz.childrenWithName("glor"), [])
    XCTAssertEqual(baz.childrenWithName(nil), [])
  }

  func testInvalid() {
    let root = TPPXML.xml(withData: try! Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "invalid", withExtension: "xml")!))
    XCTAssertNil(root)
  }

  func testNoData() {
    let root = TPPXML.xml(withData: nil)
    XCTAssertNil(root)
  }
}
