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
            // Parsed feed should produce at least one entry or link
            let feed = try OPDSParser().parseFeed(from: data)
            XCTAssertNotNil(feed, "parseFeed should return a non-nil result for valid XML")
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
            // Two separate parser instances should both throw for the same invalid data
            XCTAssertThrowsError(try OPDSParser().parseFeed(from: data),
                                 "A second parser instance should also reject invalid XML")
        } catch {
            XCTFail("Error loading resource: \(error)")
        }
    }
}
