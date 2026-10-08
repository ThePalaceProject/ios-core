//
//  MockBackendJourneyFixtureTests.swift
//  PalaceTests
//
//  The UI journey fixtures (PalaceUITests/Fixtures) run through the parsers and
//  the mock URL protocol the app uses, so a fixture that drifts from what the
//  app accepts fails here, in the unit suite, before a UI journey does.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace

private enum JourneyFixtures {
    static let host = "palace-fixtures.test"
    static let scenarioID = "journey_sign_in_and_borrow"
    static let libraryID = "urn:uuid:7f1d8a52-3b0e-4c86-9a5e-1f2a3b4c5d6e"
    static let bookID = "urn:palace-fixtures:book:quiet-harbors"
    static let bookTitle = "A Field Guide to Quiet Harbors"

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PalaceUITests/Fixtures")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func scenario() throws -> MockScenario {
        try JSONDecoder().decode(MockScenario.self, from: data("Scenarios/\(scenarioID).json"))
    }

    /// Parses an OPDS 1 document the way the borrow and loans paths do.
    static func feed(_ name: String) throws -> TPPOPDSFeed {
        let xml = try XCTUnwrap(TPPXML.xml(withData: data(name)), "\(name) is not XML")
        return try XCTUnwrap(TPPOPDSFeed(xml: xml), "\(name) is not OPDS")
    }

    static func books(in name: String) throws -> [TPPBook] {
        try feed(name).entries.compactMap { ($0 as? TPPOPDSEntry).flatMap(TPPBook.init(entry:)) }
    }
}

// MARK: - Fixture content

final class MockBackendJourneyFixtureTests: XCTestCase {

    func testRegistry_DeclaresItselfComplete_SoItReplacesTheBundledSnapshot() throws {
        let feed = try OPDS2CatalogsFeed.fromData(JourneyFixtures.data("registry.json"))

        XCTAssertEqual(feed.catalogs.map(\.metadata.id), [JourneyFixtures.libraryID])
        XCTAssertTrue(LibraryCatalogMerger.feedIsPositivelyComplete(feed),
                      "INV-2 refuses a shorter feed unless it is complete; the bundled snapshot would stay")
        let account = Account(publication: feed.catalogs[0], imageCache: MockImageCache())
        XCTAssertEqual(URL(string: account.catalogUrl ?? "")?.host, JourneyFixtures.host)
        XCTAssertEqual(URL(string: account.authenticationDocumentUrl ?? "")?.host, JourneyFixtures.host)
    }

    func testAuthDocument_OffersBasicSignInWithAProfileAndLoansURL() throws {
        let doc = try OPDS2AuthenticationDocument.fromData(JourneyFixtures.data("auth_document.json"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MockBackendJourneyFixtureTests.\(UUID())"))
        let details = AccountDetails(authenticationDocument: doc, uuid: JourneyFixtures.libraryID, defaults: defaults)

        XCTAssertEqual(details.auths.map(\.authType), [.basic])
        XCTAssertEqual(URL(string: details.userProfileUrl ?? "")?.host, JourneyFixtures.host)
        XCTAssertEqual(details.loansUrl?.host, JourneyFixtures.host)
    }

    func testCatalog_OffersTheFixtureBookForBorrowing() throws {
        let books = try JourneyFixtures.books(in: "catalog.xml")

        XCTAssertEqual(books.map(\.identifier), [JourneyFixtures.bookID])
        XCTAssertEqual(books.first?.title, JourneyFixtures.bookTitle)
        XCTAssertNotNil(books.first?.defaultAcquisitionIfBorrow, "the catalog entry must offer a borrow, not open access")
    }

    func testBorrowResponse_LeavesTheBookReadyToDownloadAsAnEPUB() throws {
        let catalogBook = try XCTUnwrap(JourneyFixtures.books(in: "catalog.xml").first)
        let borrowed = try XCTUnwrap(JourneyFixtures.books(in: "borrow_entry.xml").first)

        XCTAssertEqual(borrowed.identifier, catalogBook.identifier)
        XCTAssertEqual(BorrowOperation.borrowResponseState(for: borrowed, preBorrowBook: catalogBook).state, .downloadNeeded)
        XCTAssertEqual(borrowed.defaultBookContentType, .epub)
        XCTAssertEqual(borrowed.defaultAcquisition?.hrefURL.host, JourneyFixtures.host)
    }

    func testLoansFeeds_AreEmptyBeforeAndHoldOnlyTheBorrowedBookAfter() throws {
        XCTAssertEqual(try JourneyFixtures.books(in: "loans_empty.xml").count, 0)
        XCTAssertEqual(try JourneyFixtures.books(in: "loans_borrowed.xml").map(\.identifier), [JourneyFixtures.bookID])
    }

    func testEPUB_IsAZipWhoseFirstEntryIsTheStoredMimetype() throws {
        let data = try JourneyFixtures.data("quiet-harbors.epub")

        // OCF: "mimetype" is the first entry, stored, so its bytes sit at offset 38.
        XCTAssertEqual(data.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        XCTAssertEqual(String(data: data.subdata(in: 38..<58), encoding: .ascii), "application/epub+zip")
    }

    /// Every link a fixture serves stays on the reserved `.test` host, so a
    /// journey never reaches a real library, and an unmatched request fails
    /// instead of passing through to the network.
    func testEveryFixtureLink_PointsAtTheFixtureHost() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: JourneyFixtures.directory.path)
            .filter { $0.hasSuffix(".xml") || $0.hasSuffix(".json") }
        let hrefPattern = try NSRegularExpression(pattern: #"(?:href"?\s*[=:]\s*")([^"]+)""#)
        var hrefs: [String] = []
        for file in files {
            let text = try XCTUnwrap(String(data: JourneyFixtures.data(file), encoding: .utf8))
            hrefs += hrefPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        }

        XCTAssertGreaterThan(hrefs.count, 10, "the scan must see the fixtures' links to prove anything")
        XCTAssertEqual(hrefs.filter { URL(string: $0)?.host != JourneyFixtures.host }, [])
    }
}

// MARK: - Scenario routing

final class MockBackendJourneyScenarioTests: XCTestCase {

    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        MockBackendURLProtocol.activeScenario = try JourneyFixtures.scenario()
        MockBackendURLProtocol.fixtureDirectoryPath = JourneyFixtures.directory.path
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockBackendURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        MockBackendURLProtocol.flagsDidChange = nil
        MockBackendURLProtocol.activeScenario = nil
        MockBackendURLProtocol.fixtureDirectoryPath = nil
        super.tearDown()
    }

    private func get(_ path: String) async throws -> (Data, Int) {
        let url = try XCTUnwrap(URL(string: "https://\(JourneyFixtures.host)\(path)"))
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func loanCount() async throws -> Int {
        let (data, _) = try await get("/library/loans/")
        let xml = try XCTUnwrap(TPPXML.xml(withData: data))
        return try XCTUnwrap(TPPOPDSFeed(xml: xml)).entries.count
    }

    func testLoans_AreEmptyUntilTheBorrowIsServed_ThenHoldTheBook() async throws {
        let before = try await loanCount()
        let (_, borrowStatus) = try await get("/library/works/quiet-harbors/borrow")
        let after = try await loanCount()

        XCTAssertEqual(before, 0)
        XCTAssertEqual(borrowStatus, 201)
        XCTAssertEqual(after, 1)
        XCTAssertEqual(MockBackendURLProtocol.flags, ["borrowed"])
    }

    func testServingTheBorrow_ReportsTheRaisedFlagOnce() async throws {
        let reported = FlagRecorder()
        MockBackendURLProtocol.flagsDidChange = { reported.append($0) }

        _ = try await get("/library/works/quiet-harbors/borrow")
        _ = try await get("/library/works/quiet-harbors/borrow")

        XCTAssertEqual(reported.values, [["borrowed"]])
    }

    func testChangingTheScenario_ClearsRaisedFlags() async throws {
        _ = try await get("/library/works/quiet-harbors/borrow")

        MockBackendURLProtocol.activeScenario = try JourneyFixtures.scenario()

        XCTAssertEqual(MockBackendURLProtocol.flags, [])
        let count = try await loanCount()
        XCTAssertEqual(count, 0)
    }

    func testFulfill_ServesTheEPUBBytesUnchanged() async throws {
        let (data, status) = try await get("/library/works/quiet-harbors/fulfill")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(data, try JourneyFixtures.data("quiet-harbors.epub"))
    }

    func testRouteRequiringAFlag_DoesNotMatchUntilTheFlagIsRaised() throws {
        let route = MockRoute(pathPattern: ".*/loans", fixtureName: "x", requiresFlag: "borrowed")
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://\(JourneyFixtures.host)/library/loans")))

        XCTAssertFalse(route.matches(request))
        XCTAssertFalse(route.matches(request, flags: ["other"]))
        XCTAssertTrue(route.matches(request, flags: ["borrowed"]))
    }
}

// MARK: - Existing embedded scenario

/// The debug-menu `happy_path` scenario cannot drive a sign-in or a borrow in
/// the app, which is why the journeys carry their own fixtures. These pin that
/// finding; if the embedded scenario is fixed, they say so.
final class MockBackendHappyPathCharacterizationTests: XCTestCase {

    func testHappyPathAuthDocument_UsesAnAuthTypeTheAppDoesNotOfferAsBasicSignIn() throws {
        let data = try XCTUnwrap(EmbeddedFixtures.data(for: "auth_document"))
        let doc = try OPDS2AuthenticationDocument.fromData(data)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MockBackendHappyPathCharacterizationTests.\(UUID())"))
        let details = AccountDetails(authenticationDocument: doc, uuid: "happy", defaults: defaults)

        XCTAssertEqual(details.auths.map(\.authType), [AccountDetails.AuthType.none])
        XCTAssertNil(details.userProfileUrl, "without a profile link, credential validation has no URL")
    }

    func testHappyPathBorrowResponse_IsNotAnOPDSEntryTheBorrowPathCanRead() throws {
        let data = try XCTUnwrap(EmbeddedFixtures.data(for: "opds2_feed"))

        XCTAssertNil(TPPXML.xml(withData: data), "the borrow path parses OPDS 1 XML; this body is OPDS 2 JSON")
    }
}

private final class FlagRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Set<String>] = []
    var values: [Set<String>] { lock.withLock { _values } }
    func append(_ flags: Set<String>) { lock.withLock { _values.append(flags) } }
}
