//
//  OpenAccessAdapterTests.swift
//  PalaceTests
//
//  Mutation-killing tests for `OpenAccessAdapter` — the open-access
//  network-fetch carve-out from pre-swarm `AudiobookLoader.swift` lines
//  346-396 (minus the bearer-token branch, which lives in
//  `BearerTokenAdapter`).
//
//  Every test drives a single decision point through both branches so the
//  mutation engine cannot flip a conditional without killing at least one
//  test. The network collaborator is a constructor-injected stub — zero
//  real network, zero AppContainer.production() reads.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class OpenAccessAdapterTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    /// Test-only carrier that lets a non-Sendable value (a completion closure
    /// or a manifest payload) cross a `@Sendable` dispatch closure under
    /// Swift 6. Each box is created and consumed exactly once on the same
    /// serial test flow, so unchecked Sendable is safe here.
    private struct SendableBox<T>: @unchecked Sendable {
        let value: T
    }

    // MARK: - Stub network

    private final class StubNetwork: AudiobookManifestNetworkFetching {
        var stubbedData: Data?
        var stubbedResponse: URLResponse?
        var stubbedError: Error?
        private(set) var requestedURLs: [URL] = []

        func fetchData(
            from url: URL,
            completion: @escaping (Data?, URLResponse?, Error?) -> Void
        ) {
            requestedURLs.append(url)
            // Hop off the call stack to mirror real URLSession ordering.
            let box = SendableBox(value: completion)
            DispatchQueue.main.async { [stubbedData, stubbedResponse, stubbedError] in
                box.value(stubbedData, stubbedResponse, stubbedError)
            }
        }
    }

    private func makeResponse(url: URL, status: Int, contentType: String? = nil) -> HTTPURLResponse {
        let headers = contentType.map { ["Content-Type": $0] }
        return HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func makeBook() -> TPPBook {
        TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    }

    // MARK: - canHandle

    /// OpenAccess is the fallback adapter — it MUST accept any book the
    /// chain hands it. Mutation point: flipping `return true` to `return
    /// false` would break the loader's fallback path. This test fails the
    /// mutant by asserting true on a non-LCP, non-local OPDS book.
    func testCanHandle_anyOPDSBook_returnsTrueAsFallback() {
        let network = StubNetwork()
        let adapter = OpenAccessAdapter(network: network)
        let book = makeBook()

        XCTAssertTrue(
            adapter.canHandle(book),
            "OpenAccess is the chain's fallback — it must always accept"
        )
    }

    // MARK: - resolveManifest success

    func testResolveManifest_successPath_completesWithJSON() {
        let network = StubNetwork()
        let json: [String: Any] = ["@type": "Audiobook", "title": "Test"]
        network.stubbedData = try! JSONSerialization.data(withJSONObject: json, options: [])
        let book = makeBook()
        network.stubbedResponse = makeResponse(
            url: book.defaultAcquisition!.hrefURL,
            status: 200,
            contentType: "application/json"
        )

        let adapter = OpenAccessAdapter(network: network)
        let exp = expectation(description: "resolveManifest success")
        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        adapter.resolveManifest(for: book) { result in
            if case .success(let value) = result { observed = value }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(observed?.json["title"] as? String, "Test",
                       "Parsed JSON must propagate through to caller verbatim")
        XCTAssertEqual(observed?.json["@type"] as? String, "Audiobook")
        XCTAssertNil(observed?.decryptor,
                     "Open-access produces no DRM decryptor — must be nil")
        XCTAssertEqual(network.requestedURLs.count, 1,
                       "Adapter performed exactly one network fetch")
    }

    // MARK: - resolveManifest failure paths

    func testResolveManifest_networkError_failsWithManifestFetchFailed() {
        let network = StubNetwork()
        network.stubbedError = NSError(domain: "test.network", code: -1, userInfo: nil)
        let adapter = OpenAccessAdapter(network: network)
        let book = makeBook()

        let exp = expectation(description: "resolveManifest network error")
        var observed: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observed = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        guard case .manifestFetchFailed = observed else {
            XCTFail("Network error must map to .manifestFetchFailed, got \(String(describing: observed))")
            return
        }
    }

    func testResolveManifest_emptyData_failsWithManifestFetchFailed() {
        let network = StubNetwork()
        network.stubbedData = Data()
        let book = makeBook()
        network.stubbedResponse = makeResponse(url: book.defaultAcquisition!.hrefURL, status: 200)
        let adapter = OpenAccessAdapter(network: network)

        let exp = expectation(description: "resolveManifest empty data")
        var observed: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observed = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        guard case .manifestFetchFailed = observed else {
            XCTFail("Empty data must map to .manifestFetchFailed, got \(String(describing: observed))")
            return
        }
    }

    func testResolveManifest_htmlResponse_failsWithManifestFetchFailed() {
        // A login-redirect page is HTML with a 200 status code and a body.
        // The HTML check must short-circuit BEFORE JSON parsing (which
        // would map to .manifestParseFailed). This pins the failure-mode
        // distinction the contract specifies.
        let network = StubNetwork()
        let htmlBody = "<html><body>Please log in</body></html>".data(using: .utf8)!
        network.stubbedData = htmlBody
        let book = makeBook()
        network.stubbedResponse = makeResponse(
            url: book.defaultAcquisition!.hrefURL,
            status: 200,
            contentType: "text/html; charset=utf-8"
        )
        let adapter = OpenAccessAdapter(network: network)

        let exp = expectation(description: "resolveManifest html response")
        var observed: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observed = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        guard case .manifestFetchFailed = observed else {
            XCTFail("HTML response must map to .manifestFetchFailed (not parseFailed), got \(String(describing: observed))")
            return
        }
    }

    func testResolveManifest_invalidJSON_failsWithManifestParseFailed() {
        // Non-HTML, non-empty, non-dict bytes — the actual "we got data
        // but it's not a JSON dict" branch. Drives the
        // `.manifestParseFailed` mapping that distinguishes parse from
        // fetch failures in the error surface.
        let network = StubNetwork()
        network.stubbedData = "[1,2,3]".data(using: .utf8)!  // valid JSON, but an array
        let book = makeBook()
        network.stubbedResponse = makeResponse(
            url: book.defaultAcquisition!.hrefURL,
            status: 200,
            contentType: "application/json"
        )
        let adapter = OpenAccessAdapter(network: network)

        let exp = expectation(description: "resolveManifest invalid JSON")
        var observed: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observed = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        guard case .manifestParseFailed = observed else {
            XCTFail("Non-dict JSON must map to .manifestParseFailed, got \(String(describing: observed))")
            return
        }
    }

    // MARK: - PP-4631 bearer-token wrapper recovery

    /// Stub second-leg fetcher. Records the token + book it was handed and
    /// returns a pre-canned manifest (or nil to simulate a failed second leg).
    private final class StubBearerFetcher: BearerTokenManifestFetching {
        var stubbedManifest: [String: Any]?
        private(set) var callCount = 0
        private(set) var receivedToken: MyBooksSimplifiedBearerToken?
        private(set) var receivedBook: TPPBook?

        func fetchManifest(
            with token: MyBooksSimplifiedBearerToken,
            for book: TPPBook,
            completion: @escaping ([String: Any]?) -> Void
        ) {
            callCount += 1
            receivedToken = token
            receivedBook = book
            let box = SendableBox(value: (manifest: stubbedManifest, completion: completion))
            DispatchQueue.main.async { box.value.completion(box.value.manifest) }
        }
    }

    private func bearerWrapperData(
        location: String = "https://cm.example.org/real-manifest.json",
        accessToken: String = "tok-abc",
        expiresIn: Int = 3600
    ) -> Data {
        try! JSONSerialization.data(
            withJSONObject: ["access_token": accessToken, "location": location, "expires_in": expiresIn],
            options: []
        )
    }

    /// PP-4631 core regression: a fulfill response that is a bearer-token
    /// wrapper (the OverDrive / Unlimited Listens shape whose MIME is nested
    /// in the indirectAcquisition chain, so the top-level-MIME
    /// `BearerTokenMIMEGate` does not claim it) must be followed to the real
    /// manifest at the token's `location` — NOT returned verbatim as if the
    /// wrapper were the manifest (which fails decode → "error opening this
    /// book"). Kills the mutant that drops the bearer-detection branch.
    func testResolveManifest_bearerWrapperWithFetcher_followsSecondLegToRealManifest() {
        let network = StubNetwork()
        let book = makeBook()
        network.stubbedData = bearerWrapperData()
        network.stubbedResponse = makeResponse(
            url: book.defaultAcquisition!.hrefURL,
            status: 200,
            contentType: "application/json"
        )
        let bearerFetcher = StubBearerFetcher()
        bearerFetcher.stubbedManifest = ["@type": "Audiobook", "title": "Real Manifest", "readingOrder": []]
        let adapter = OpenAccessAdapter(network: network, bearerTokenManifestFetcher: bearerFetcher)

        let exp = expectation(description: "bearer second leg")
        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        adapter.resolveManifest(for: book) { result in
            if case .success(let value) = result { observed = value }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(bearerFetcher.callCount, 1,
                       "A bearer-token wrapper body must trigger exactly one second-leg fetch")
        XCTAssertEqual(observed?.json["title"] as? String, "Real Manifest",
                       "Caller must receive the real manifest, not the bearer wrapper")
        XCTAssertNil(observed?.json["access_token"],
                     "The bearer wrapper must NOT be returned as the manifest")
        XCTAssertEqual(bearerFetcher.receivedToken?.accessToken, "tok-abc",
                       "Second-leg fetch must carry the parsed access token")
        XCTAssertEqual(bearerFetcher.receivedToken?.fulfillURL, book.defaultAcquisition!.hrefURL,
                       "Second-leg token must record the fulfill URL for later re-auth")
    }

    /// A failed second leg (nil manifest) must surface as `.manifestFetchFailed`,
    /// not a spurious success. Pins the bearer failure-mapping branch.
    func testResolveManifest_bearerSecondLegReturnsNil_failsWithManifestFetchFailed() {
        let network = StubNetwork()
        let book = makeBook()
        network.stubbedData = bearerWrapperData()
        network.stubbedResponse = makeResponse(
            url: book.defaultAcquisition!.hrefURL,
            status: 200,
            contentType: "application/json"
        )
        let bearerFetcher = StubBearerFetcher()
        bearerFetcher.stubbedManifest = nil
        let adapter = OpenAccessAdapter(network: network, bearerTokenManifestFetcher: bearerFetcher)

        let exp = expectation(description: "bearer second leg nil")
        var observed: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observed = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        guard case .manifestFetchFailed = observed else {
            XCTFail("Nil second-leg manifest must map to .manifestFetchFailed, got \(String(describing: observed))")
            return
        }
    }

    /// Back-compat: with no fetcher injected (the open-access-only
    /// construction used across the suite), bearer detection is skipped and
    /// the body is returned verbatim — the exact pre-fix fallback behavior,
    /// so existing open-access tests/usages are unaffected.
    func testResolveManifest_bearerWrapperButNoFetcher_returnsBodyVerbatim() {
        let network = StubNetwork()
        let book = makeBook()
        network.stubbedData = bearerWrapperData()
        network.stubbedResponse = makeResponse(
            url: book.defaultAcquisition!.hrefURL,
            status: 200,
            contentType: "application/json"
        )
        let adapter = OpenAccessAdapter(network: network)  // no bearer fetcher

        let exp = expectation(description: "no fetcher verbatim")
        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        adapter.resolveManifest(for: book) { result in
            if case .success(let value) = result { observed = value }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(observed?.json["access_token"] as? String, "tok-abc",
                       "Without a fetcher, the body is returned verbatim (back-compat)")
    }

    /// A plain (non-wrapper) manifest with a fetcher present must still be
    /// returned directly — the bearer branch must not swallow normal
    /// open-access manifests. Kills the mutant that always takes the bearer
    /// path regardless of body shape.
    func testResolveManifest_plainManifestWithFetcher_returnsDirectlyWithoutSecondLeg() {
        let network = StubNetwork()
        let book = makeBook()
        network.stubbedData = try! JSONSerialization.data(
            withJSONObject: ["@type": "Audiobook", "title": "Plain", "readingOrder": []],
            options: []
        )
        network.stubbedResponse = makeResponse(
            url: book.defaultAcquisition!.hrefURL,
            status: 200,
            contentType: "application/json"
        )
        let bearerFetcher = StubBearerFetcher()
        let adapter = OpenAccessAdapter(network: network, bearerTokenManifestFetcher: bearerFetcher)

        let exp = expectation(description: "plain manifest")
        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        adapter.resolveManifest(for: book) { result in
            if case .success(let value) = result { observed = value }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(bearerFetcher.callCount, 0,
                       "A plain manifest must NOT trigger the bearer second-leg")
        XCTAssertEqual(observed?.json["title"] as? String, "Plain",
                       "Plain open-access manifest must be returned directly")
    }

    // MARK: - PP-4631 Overdrive manifest decode (gated regression guard)
    //
    // The toolkit's own PalaceAudiobookToolkitTests are NOT run by any CI
    // workflow, so the root-invariant regression that broke every Overdrive
    // audiobook open (PP-4631, toolkit commit 3d1046b8) shipped unguarded.
    // These tests run in PalaceTests (which IS gated) and decode through the
    // SAME path the loader uses (`Manifest.customDecoder()`), so a future
    // re-tightening of the invariant fails here in CI.

    /// The real Overdrive descriptor shape (CM fulfillment): `formatType`
    /// "audiobook-overdrive" + `links.contentlinks`, with NO metadata /
    /// readingOrder / spine. It MUST decode (not throw) and classify as
    /// `.overdrive` — decoding this shape is exactly what PP-4631 broke.
    func testOverdriveDescriptorManifest_decodesAndTypesAsOverdrive() throws {
        let json = #"""
        {
          "reserveId": "66e77ed7-3568-477a-83b7-8028424c840a",
          "formatType": "audiobook-overdrive",
          "id": "urn:librarysimplified.org/terms/id/Overdrive ID/66e77ed7",
          "links": { "contentlinks": [
            { "type": "text/html", "href": "https://ofsdirect.api.overdrive.com/contentfile?body=abc" }
          ] }
        }
        """#
        let manifest = try Manifest.customDecoder().decode(Manifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.audiobookType, .overdrive,
                       "Overdrive descriptor must classify as .overdrive")
        XCTAssertNil(manifest.metadata,
                     "Overdrive descriptor legitimately has no root metadata — must still decode")
    }

    /// F-005 guard preserved: a non-Overdrive manifest with no metadata and no
    /// readingOrder/spine must STILL be rejected.
    func testEmptyManifest_stillThrows() {
        XCTAssertThrowsError(
            try Manifest.customDecoder().decode(Manifest.self, from: Data("{}".utf8)),
            "Empty manifest (no metadata/tracks, not overdrive) must still throw"
        )
    }

    /// The Overdrive exemption is contentLinks-gated: an "overdrive" formatType
    /// with NO content links is genuinely broken and must still throw.
    func testOverdriveFormatWithoutContentLinks_stillThrows() {
        XCTAssertThrowsError(
            try Manifest.customDecoder().decode(Manifest.self, from: Data(#"{"formatType":"audiobook-overdrive"}"#.utf8)),
            "Overdrive formatType without contentlinks must still be rejected (F-005 guard)"
        )
    }
}
