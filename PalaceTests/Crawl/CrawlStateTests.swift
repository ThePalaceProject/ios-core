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
            lastFullCrawlDate: now,
            lastCrawlAppVersion: "3.2.0"
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CrawlState.self, from: data)

        let decodedCrawlDate = try XCTUnwrap(decoded.lastSuccessfulCrawlDate)
        XCTAssertEqual(decodedCrawlDate.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate, accuracy: 0.001)
        XCTAssertEqual(decoded.orderModifiedFacetURL, facetURL)
        let decodedFullDate = try XCTUnwrap(decoded.lastFullCrawlDate)
        XCTAssertEqual(decodedFullDate.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate, accuracy: 0.001)
        XCTAssertEqual(decoded.lastCrawlAppVersion, "3.2.0")
    }

    func testCrawlState_DecodesWithMissingOptionals() throws {
        let json = "{}".data(using: .utf8)!
        let state = try JSONDecoder().decode(CrawlState.self, from: json)

        XCTAssertNil(state.lastSuccessfulCrawlDate)
        XCTAssertNil(state.orderModifiedFacetURL)
        XCTAssertNil(state.lastFullCrawlDate)
        XCTAssertNil(state.lastCrawlAppVersion)
    }

    func testCrawlState_DecodesLegacyPayload_WithoutAppVersion() throws {
        // Persistence written by an earlier build that didn't have lastCrawlAppVersion
        let json = """
        {
            "lastSuccessfulCrawlDate": 754416000,
            "orderModifiedFacetURL": "https://registry.example.com/libraries/crawlable?order=modified",
            "lastFullCrawlDate": 754416000
        }
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(CrawlState.self, from: json)

        XCTAssertNotNil(state.lastSuccessfulCrawlDate)
        XCTAssertNotNil(state.lastFullCrawlDate)
        XCTAssertNil(state.lastCrawlAppVersion)
    }

    // MARK: - needsFullCrawl: structural triggers

    func testNeedsFullCrawl_WhenNoLastCrawlDate_ReturnsTrue() {
        let state = CrawlState(
            lastSuccessfulCrawlDate: nil,
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: nil
        )
        XCTAssertTrue(state.needsFullCrawl())
    }

    func testNeedsFullCrawl_WhenNoFacetURL_ReturnsTrue() {
        let state = CrawlState(
            lastSuccessfulCrawlDate: Date(),
            orderModifiedFacetURL: nil,
            lastFullCrawlDate: nil
        )
        XCTAssertTrue(state.needsFullCrawl())
    }

    func testNeedsFullCrawl_WhenBothNil_ReturnsTrue() {
        let state = CrawlState()
        XCTAssertTrue(state.needsFullCrawl())
    }

    func testNeedsFullCrawl_WhenAllPresent_AndFreshAndSameVersion_ReturnsFalse() {
        let now = Date()
        let state = CrawlState(
            lastSuccessfulCrawlDate: now,
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: now,
            lastCrawlAppVersion: "3.2.0"
        )
        XCTAssertFalse(state.needsFullCrawl(currentAppVersion: "3.2.0", now: now))
    }

    // MARK: - needsFullCrawl: version-upgrade trigger

    func testNeedsFullCrawl_WhenAppVersionChanged_ReturnsTrue() {
        let now = Date()
        let state = CrawlState(
            lastSuccessfulCrawlDate: now,
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: now,
            lastCrawlAppVersion: "3.1.0"
        )
        XCTAssertTrue(state.needsFullCrawl(currentAppVersion: "3.2.0", now: now))
    }

    func testNeedsFullCrawl_WhenAppVersionRecordedNil_AndCurrentSet_ReturnsTrue() {
        // Legacy persisted state (no lastCrawlAppVersion field); upgrade landed.
        // We trigger a full crawl exactly once so deletions reconcile.
        let now = Date()
        let state = CrawlState(
            lastSuccessfulCrawlDate: now,
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: now,
            lastCrawlAppVersion: nil
        )
        XCTAssertTrue(state.needsFullCrawl(currentAppVersion: "3.2.0", now: now))
    }

    func testNeedsFullCrawl_WhenAppVersionMatches_AndAllFresh_ReturnsFalse() {
        let now = Date()
        let state = CrawlState(
            lastSuccessfulCrawlDate: now,
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: now,
            lastCrawlAppVersion: "3.2.0"
        )
        XCTAssertFalse(state.needsFullCrawl(currentAppVersion: "3.2.0", now: now))
    }

    // MARK: - needsFullCrawl: 7-day periodic trigger

    func testNeedsFullCrawl_WhenLastFullCrawlOlderThan7Days_ReturnsTrue() {
        let now = Date()
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let state = CrawlState(
            lastSuccessfulCrawlDate: now,
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: eightDaysAgo,
            lastCrawlAppVersion: "3.2.0"
        )
        XCTAssertTrue(state.needsFullCrawl(currentAppVersion: "3.2.0", now: now))
    }

    func testNeedsFullCrawl_WhenLastFullCrawlExactly7Days_ReturnsTrue() {
        let now = Date()
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let state = CrawlState(
            lastSuccessfulCrawlDate: now,
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: sevenDaysAgo,
            lastCrawlAppVersion: "3.2.0"
        )
        XCTAssertTrue(state.needsFullCrawl(currentAppVersion: "3.2.0", now: now))
    }

    func testNeedsFullCrawl_WhenLastFullCrawlWithin7Days_ReturnsFalse() {
        let now = Date()
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)
        let state = CrawlState(
            lastSuccessfulCrawlDate: now,
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: sixDaysAgo,
            lastCrawlAppVersion: "3.2.0"
        )
        XCTAssertFalse(state.needsFullCrawl(currentAppVersion: "3.2.0", now: now))
    }

    func testNeedsFullCrawl_WhenIncrementalSucceededButFullCrawlNeverHappened_ReturnsTrue() {
        // lastSuccessfulCrawlDate set, but lastFullCrawlDate nil — a full crawl is required
        let now = Date()
        let state = CrawlState(
            lastSuccessfulCrawlDate: now,
            orderModifiedFacetURL: URL(string: "https://example.com/crawlable?order=modified")!,
            lastFullCrawlDate: nil,
            lastCrawlAppVersion: "3.2.0"
        )
        XCTAssertTrue(state.needsFullCrawl(currentAppVersion: "3.2.0", now: now))
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
            lastFullCrawlDate: Date(timeIntervalSince1970: 1699990000),
            lastCrawlAppVersion: "3.2.0"
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
        XCTAssertEqual(loaded.lastCrawlAppVersion, "3.2.0")
        // Time-aware predicate stays false when fresh + version matches.
        XCTAssertFalse(loaded.needsFullCrawl(
            currentAppVersion: "3.2.0",
            now: Date(timeIntervalSince1970: 1700001000)
        ))
    }

    func testCrawlState_LoadFromMissingFile_Fails() {
        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).json")

        XCTAssertThrowsError(try Data(contentsOf: bogusURL))
    }
}
