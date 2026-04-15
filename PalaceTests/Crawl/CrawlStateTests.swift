import XCTest
@testable import Palace

final class CrawlStateTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func testCrawlState_EncodesAndDecodes() throws {
        let now = Date()
        let facetURL = URL(string: "https://registry.palaceproject.io/libraries/crawlable?order=modified")!
        let state = CrawlState(
            lastSuccessfulCrawlDate: now,
            orderModifiedFacetURL: facetURL,
            lastFullCrawlDate: now
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CrawlState.self, from: data)

        let decodedCrawlDate = try XCTUnwrap(decoded.lastSuccessfulCrawlDate)
        XCTAssertEqual(decodedCrawlDate.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate, accuracy: 0.001)
        XCTAssertEqual(decoded.orderModifiedFacetURL, facetURL)
        let decodedFullDate = try XCTUnwrap(decoded.lastFullCrawlDate)
        XCTAssertEqual(decodedFullDate.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate, accuracy: 0.001)
    }

    func testCrawlState_DecodesWithMissingOptionals() throws {
        let json = "{}".data(using: .utf8)!
        let state = try JSONDecoder().decode(CrawlState.self, from: json)

        XCTAssertNil(state.lastSuccessfulCrawlDate)
        XCTAssertNil(state.orderModifiedFacetURL)
        XCTAssertNil(state.lastFullCrawlDate)
    }

    // MARK: - needsFullCrawl

    func testNeedsFullCrawl_WhenNoLastCrawlDate_ReturnsTrue() {
        let state = CrawlState(
            lastSuccessfulCrawlDate: nil,
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: nil
        )
        XCTAssertTrue(state.needsFullCrawl)
    }

    func testNeedsFullCrawl_WhenNoFacetURL_ReturnsTrue() {
        let state = CrawlState(
            lastSuccessfulCrawlDate: Date(),
            orderModifiedFacetURL: nil,
            lastFullCrawlDate: nil
        )
        XCTAssertTrue(state.needsFullCrawl)
    }

    func testNeedsFullCrawl_WhenBothNil_ReturnsTrue() {
        let state = CrawlState()
        XCTAssertTrue(state.needsFullCrawl)
    }

    func testNeedsFullCrawl_WhenBothPresent_ReturnsFalse() {
        let state = CrawlState(
            lastSuccessfulCrawlDate: Date(),
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: Date()
        )
        XCTAssertFalse(state.needsFullCrawl)
    }

    // MARK: - Disk Persistence

    func testCrawlState_PersistsToDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_crawl_state_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let facetURL = URL(string: "https://registry.palaceproject.io/libraries/crawlable?order=modified")!
        let original = CrawlState(
            lastSuccessfulCrawlDate: Date(timeIntervalSince1970: 1700000000),
            orderModifiedFacetURL: facetURL,
            lastFullCrawlDate: Date(timeIntervalSince1970: 1699990000)
        )

        let data = try JSONEncoder().encode(original)
        try data.write(to: fileURL)

        let readData = try Data(contentsOf: fileURL)
        let loaded = try JSONDecoder().decode(CrawlState.self, from: readData)

        let loadedCrawlDate = try XCTUnwrap(loaded.lastSuccessfulCrawlDate)
        XCTAssertEqual(loadedCrawlDate.timeIntervalSince1970, 1700000000, accuracy: 0.001)
        XCTAssertEqual(loaded.orderModifiedFacetURL, facetURL)
        let loadedFullDate = try XCTUnwrap(loaded.lastFullCrawlDate)
        XCTAssertEqual(loadedFullDate.timeIntervalSince1970, 1699990000, accuracy: 0.001)
        XCTAssertFalse(loaded.needsFullCrawl)
    }

    func testCrawlState_LoadFromMissingFile_Fails() {
        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).json")

        XCTAssertThrowsError(try Data(contentsOf: bogusURL))
    }
}
