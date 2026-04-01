import XCTest
@testable import Palace

class TPPOPDSGroupSwiftTests: XCTestCase {

  func testInitStoresProperties() {
    let href = URL(string: "https://example.com/group")!
    let group = TPPOPDSGroup(entries: [], href: href, title: "Group Title")

    XCTAssertNotNil(group)
    XCTAssertEqual(group.href, href)
    XCTAssertEqual(group.title, "Group Title")
    XCTAssertEqual(group.entries.count, 0)
  }
}
