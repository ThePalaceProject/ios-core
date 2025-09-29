import XCTest
@testable import Palace

final class OPDSFeedParsingTests: XCTestCase {
  func testParseValidOPDSFeed() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "main", withExtension: "xml") else {
      XCTFail("Missing main.xml test resource")
      return
    }
    do {
      let data = try Data(contentsOf: url)
      XCTAssertNoThrow(try OPDSParser().parseFeed(from: data))
    } catch {
      XCTFail("Error loading resource: \(error)")
    }
  }

  func testParseInvalidOPDSFeed() {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "invalid", withExtension: "xml") else {
      XCTFail("Missing invalid.xml test resource")
      return
    }
    do {
      let data = try Data(contentsOf: url)
      XCTAssertThrowsError(try OPDSParser().parseFeed(from: data))
    } catch {
      XCTFail("Error loading resource: \(error)")
    }
  }
}
