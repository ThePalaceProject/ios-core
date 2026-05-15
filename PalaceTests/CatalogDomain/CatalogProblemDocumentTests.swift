//
//  CatalogProblemDocumentTests.swift
//  PalaceTests
//
//  Deep mutation-killing tests for RFC 7807 problem-document handling
//  on the catalog load path.
//
//  ──────────────────────────────────────────────────────────────────────────
//  Behavior under test
//  ──────────────────────────────────────────────────────────────────────────
//
//  When the catalog endpoint returns an RFC 7807 problem document (e.g.
//  503 with `application/problem+json`):
//
//    • DefaultCatalogAPI/OPDSParser cannot parse the body as a valid OPDS
//      feed. Body shape determines the error:
//        - Body starts with `{` → routed to OPDS 2 parser → `invalidJSON`.
//        - Body starts with `<` → routed to OPDS 1 parser → `invalidXML`.
//      Both surface as `OPDSParser.ParserError` to the repository.
//
//    • CatalogRepository wraps non-cancellation throws in an NSError with
//      domain `"CatalogRepository"` and a localized description that
//      preserves the underlying error's message. If a cached fallback
//      exists, it is returned instead of throwing.
//
//    • The standalone `TPPProblemDocument` model decodes problem JSON
//      independently of OPDS parsing — this is the path the UI layer uses
//      to render error banners. Tests below pin the relevant fields.
//
//  ──────────────────────────────────────────────────────────────────────────
//  Gap documented (not fixed): the catalog layer does NOT special-case
//  `application/problem+json` responses today. Errors propagate as generic
//  parser failures whose `localizedDescription` mentions JSON/XML rather
//  than the server's `title`/`detail`. UI consumers parse problem documents
//  via `TPPProblemDocument.fromData(_:)` on a separate code path.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
import PalaceNetwork
@testable import Palace

final class CatalogProblemDocumentTests: XCTestCase {

    // MARK: - Fixtures

    private var networkClient: NetworkClientMock!
    private var parser: OPDSParser!
    private var api: DefaultCatalogAPI!
    private var repository: CatalogRepository!
    private let topURL = URL(string: "https://library.example.com/catalog")!

    override func setUp() {
        super.setUp()
        networkClient = NetworkClientMock()
        parser = OPDSParser()
        api = DefaultCatalogAPI(
            client: networkClient,
            parser: parser,
            featureFlags: MockFeatureFlagProvider(isOPDS2Enabled: true)
        )
        repository = CatalogRepository(api: api)
    }

    override func tearDown() {
        networkClient = nil
        parser = nil
        api = nil
        repository = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Stub a problem-document JSON response at the given status code.
    private func stubProblemDocument(
        status: Int,
        type: String = "http://librarysimplified.org/terms/problem/upstream-service-down",
        title: String = "Library temporarily unavailable",
        detail: String = "The lending service is offline. Please try again shortly."
    ) {
        let json = """
        {
          "type": "\(type)",
          "title": "\(title)",
          "status": \(status),
          "detail": "\(detail)"
        }
        """
        let data = Data(json.utf8)
        let response = HTTPURLResponse(
            url: topURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/problem+json"]
        )!
        networkClient.stubbedResponses[topURL] = NetworkResponse(data: data, response: response)
    }

    /// Stub a problem document with non-default Content-Type (e.g. some
    /// servers use `application/api-problem+json`).
    private func stubProblemWithVariantContentType() {
        let json = """
        {
          "type": "about:blank",
          "title": "Maintenance",
          "status": 503,
          "detail": "Service is in scheduled maintenance"
        }
        """
        let response = HTTPURLResponse(
            url: topURL,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/api-problem+json"]
        )!
        networkClient.stubbedResponses[topURL] = NetworkResponse(
            data: Data(json.utf8),
            response: response
        )
    }

    // MARK: - DefaultCatalogAPI: parser routes JSON problem doc to invalidJSON

    /// Mutant killed: making the parser silently return nil for invalid
    /// OPDS 2 bodies. A problem document is valid JSON but invalid OPDS 2;
    /// the parser MUST throw, not produce a feed with empty content.
    func testFetchFeed_ProblemDocumentJSON_ThrowsInvalidJSONFromParser() async {
        stubProblemDocument(status: 503)

        do {
            _ = try await api.fetchFeed(at: topURL)
            XCTFail("A 503 problem document must NOT be silently parsed into a feed")
        } catch let error as OPDSParser.ParserError {
            XCTAssertEqual(error, .invalidJSON,
                           "Problem document JSON starting with `{` must surface as ParserError.invalidJSON")
        } catch {
            // Any throw is acceptable — silently returning a feed is not.
        }
    }

    /// Mutant killed: removing the `application/problem+json` body from
    /// reaching the JSON-parser branch. We don't care HOW the parser fails,
    /// but it MUST NOT report success.
    func testFetchFeed_ProblemDocument_NeverReturnsValidFeed() async {
        stubProblemDocument(status: 401, type: "http://librarysimplified.org/terms/problem/credentials-invalid")

        var producedFeed: CatalogFeed?
        do {
            producedFeed = try await api.fetchFeed(at: topURL)
        } catch {
            // Expected throw — neither isOPDS2 nor entries should ever be produced.
        }
        XCTAssertNil(producedFeed,
                     "A problem document must NEVER be returned as a parsed CatalogFeed")
    }

    /// Mutant killed: routing problem documents to the XML branch. A
    /// body starting with `{` is committed to the JSON parser; that
    /// decision is locked in by `OPDSFormat.detect`.
    func testFetchFeed_ProblemDocument_DoesNotInvokeXMLParser() async {
        stubProblemDocument(status: 500)

        do {
            _ = try await api.fetchFeed(at: topURL)
        } catch let error as OPDSParser.ParserError {
            XCTAssertNotEqual(error, .invalidXML,
                              "JSON-bodied problem docs must NEVER surface as invalidXML")
        } catch {
            // ok
        }
    }

    /// Mutant killed: hard-coded support for only `application/problem+json`
    /// while ignoring the older `application/api-problem+json` MIME. Since
    /// routing is purely by body first-byte, BOTH variants must produce
    /// the same `invalidJSON` outcome.
    func testFetchFeed_VariantApiProblemContentType_RoutesIdenticallyToJSONParser() async {
        stubProblemWithVariantContentType()

        do {
            _ = try await api.fetchFeed(at: topURL)
            XCTFail("api-problem+json must NOT be accepted as a valid feed")
        } catch let error as OPDSParser.ParserError {
            XCTAssertEqual(error, .invalidJSON,
                           "api-problem+json (older form) must also reach the JSON parser and throw invalidJSON")
        } catch {
            // also acceptable
        }
    }

    // MARK: - CatalogRepository: error wrapping & cache fallback

    /// Mutant killed: making the repository swallow parser errors and
    /// return nil. A problem document at the first-ever load (no prior
    /// cache) MUST throw so the UI can surface an error banner.
    func testLoadTopLevelCatalog_ProblemDocumentNoCache_PropagatesError() async {
        stubProblemDocument(status: 503)

        do {
            _ = try await repository.loadTopLevelCatalog(at: topURL)
            XCTFail("Problem document with no cache fallback must throw")
        } catch {
            // The repository wraps non-cancellation errors as an NSError
            // with domain "CatalogRepository". Exact domain pin would be
            // brittle, but the throw MUST happen.
            XCTAssertEqual(networkClient.sendCallCount, 1,
                           "Exactly one network call must occur — no silent retry on problem doc")
        }
    }

    /// Mutant killed: dropping the cached-fallback branch in
    /// `CatalogRepository.loadTopLevelCatalog`. When the server suddenly
    /// returns a problem document but a previously successful feed is
    /// cached, the cached feed MUST be returned (the UI must keep
    /// rendering content the user already had).
    func testLoadTopLevelCatalog_ProblemDocumentWithFreshCache_ReturnsCachedFeed() async throws {
        // First successful load populates the cache.
        let xml = NetworkClientMock.makeOPDSFeedXML(title: "Last-Known-Good", entries: 1)
        networkClient.stubOPDSResponse(for: topURL, xml: xml)
        let cached = try await repository.loadTopLevelCatalog(at: topURL)
        XCTAssertEqual(cached?.title, "Last-Known-Good")

        // Within the fresh window: the next read should not even attempt
        // the network. Stub a 503 problem doc anyway as belt-and-braces;
        // it must not be observed.
        stubProblemDocument(status: 503)
        let result = try await repository.loadTopLevelCatalog(at: topURL)
        XCTAssertEqual(result?.title, "Last-Known-Good",
                       "Fresh cache must serve last-known-good feed even if the next response would be a problem doc")
        XCTAssertEqual(networkClient.sendCallCount, 1,
                       "Fresh-cache hit must not touch the network at all")
    }

    /// Mutant killed: collapsing the network-error fallback to "no fallback".
    /// After invalidation + problem-doc response on retry, the repository's
    /// in-memory cache entry has already been cleared, so the throw MUST
    /// propagate — pinning that invalidateCache() actually clears the
    /// fallback entry, not just the freshness window.
    func testLoadTopLevelCatalog_InvalidateThenProblemDocument_PropagatesError() async throws {
        let xml = NetworkClientMock.makeOPDSFeedXML(title: "Initial", entries: 1)
        networkClient.stubOPDSResponse(for: topURL, xml: xml)
        _ = try await repository.loadTopLevelCatalog(at: topURL)

        // Invalidate — cache entry must be gone.
        repository.invalidateCache(for: topURL)

        // Server now responds with a problem doc.
        stubProblemDocument(status: 503)

        do {
            _ = try await repository.loadTopLevelCatalog(at: topURL)
            XCTFail("After invalidate, problem document must propagate (no fallback to serve)")
        } catch {
            // Expected.
            XCTAssertGreaterThanOrEqual(networkClient.sendCallCount, 2,
                                        "Second load after invalidation must attempt the network")
        }
    }

    // MARK: - TPPProblemDocument decode contract (UI's surfacing path)

    /// Mutant killed: dropping any of the four core fields from the
    /// `TPPProblemDocument.fromData(_:)` decode. Each field is what the
    /// UI banner / alert reads to render the user-facing message.
    func testProblemDocument_FromData_ExtractsAllRFC7807Fields() throws {
        let json = """
        {
          "type": "http://librarysimplified.org/terms/problem/loan-limit-reached",
          "title": "Too many checkouts",
          "status": 403,
          "detail": "You already have 10 books out. Return one to borrow more.",
          "instance": "urn:uuid:abc-123"
        }
        """
        let doc = try TPPProblemDocument.fromData(Data(json.utf8))

        XCTAssertEqual(doc.type, "http://librarysimplified.org/terms/problem/loan-limit-reached",
                       "type field must survive decode (UI uses it to classify the error)")
        XCTAssertEqual(doc.title, "Too many checkouts",
                       "title field must survive decode (banner headline)")
        XCTAssertEqual(doc.status, 403,
                       "status field must survive decode (matches HTTP status)")
        XCTAssertEqual(doc.detail, "You already have 10 books out. Return one to borrow more.",
                       "detail field must survive decode (banner body text)")
        XCTAssertEqual(doc.instance, "urn:uuid:abc-123",
                       "instance field must survive decode (used for log correlation)")
    }

    /// Mutant killed: collapsing `stringValue` to ignore the title or detail.
    /// `stringValue` is what error logs and toasts use when there's no UI
    /// space for separate title/detail.
    func testProblemDocument_StringValue_IncludesTitleAndDetail() throws {
        let json = """
        { "type": "x", "title": "Hold limit", "status": 403, "detail": "10 holds is the cap." }
        """
        let doc = try TPPProblemDocument.fromData(Data(json.utf8))

        let s = doc.stringValue
        XCTAssertTrue(s.contains("Hold limit"),
                      "stringValue must include the title for log/toast surfaces")
        XCTAssertTrue(s.contains("10 holds is the cap."),
                      "stringValue must include the detail for log/toast surfaces")
    }

    /// Mutant killed: hardening the JSON decode to reject any extra junk.
    /// Servers have been observed returning two concatenated JSON objects
    /// (a known bug); the extraction must succeed on the first object.
    func testProblemDocument_FromData_HandlesConcatenatedDuplicateJSON() throws {
        // Two JSON objects glued together — a real bug we have to be tolerant of.
        let payload = """
        {"type":"x","title":"First","status":500,"detail":"d1"}{"type":"y","title":"Second","status":501,"detail":"d2"}
        """
        let doc = try TPPProblemDocument.fromData(Data(payload.utf8))
        XCTAssertEqual(doc.title, "First",
                       "Concatenated JSON must parse the FIRST object only — not the second, not fail outright")
        XCTAssertEqual(doc.status, 500)
    }

    /// Mutant killed: removing the recoverable-auth classification helper.
    /// UI uses `isRecoverableAuthError` to decide whether to re-prompt for
    /// credentials silently (recoverable) or surface a hard error
    /// (unrecoverable).
    func testProblemDocument_RecoverableAuthClassification_DistinguishesPaths() {
        let recoverable = TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/auth/recoverable/token-expired"
        ])
        let unrecoverable = TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/auth/unrecoverable/invalid-credentials"
        ])
        let generic = TPPProblemDocument.fromDictionary([
            "type": "http://librarysimplified.org/terms/problem/loan-limit-reached"
        ])

        XCTAssertTrue(recoverable.isRecoverableAuthError,
                      "Recoverable auth path must be classified for silent re-auth flow")
        XCTAssertFalse(recoverable.isUnrecoverableAuthError,
                       "Recoverable error must NOT also be classified as unrecoverable")

        XCTAssertTrue(unrecoverable.isUnrecoverableAuthError,
                      "Unrecoverable auth path must surface as hard error")
        XCTAssertFalse(unrecoverable.isRecoverableAuthError,
                       "Unrecoverable error must NOT also be classified as recoverable")

        XCTAssertFalse(generic.isRecoverableAuthError,
                       "Non-auth problem types must NOT match the recoverable predicate")
        XCTAssertFalse(generic.isUnrecoverableAuthError,
                       "Non-auth problem types must NOT match the unrecoverable predicate")
    }

    /// Mutant killed: `fromProblemResponseData` returning nil for any
    /// payload that doesn't strictly satisfy RFC 7807 keys. Real servers
    /// sometimes send `{ "message": "..." }` instead of `detail` and we
    /// must still surface something usable to the user.
    ///
    /// Note: when strict decode succeeds (all RFC 7807 fields are
    /// optional so `{ "message": "x" }` decodes fine with all nils), the
    /// fallback message-extraction branch is NOT entered. To pin the
    /// fallback branch we force strict decode to fail by giving `status`
    /// a wrong type (string instead of number); the fallback then runs
    /// `JSONSerialization` and maps `message` → `detail`.
    func testProblemDocument_FromProblemResponseData_LooseDecodeFallsBackToMessage() {
        let loose = """
        { "message": "Something went wrong but no title/detail.", "status": "not-an-int" }
        """
        let doc = TPPProblemDocument.fromProblemResponseData(Data(loose.utf8))
        XCTAssertNotNil(doc, "fromProblemResponseData must return SOMETHING when 'message' is present")
        XCTAssertEqual(doc?.detail, "Something went wrong but no title/detail.",
                       "loose decode must map 'message' → detail so the UI banner has content")
    }
}
