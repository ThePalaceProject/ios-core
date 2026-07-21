//
//  BearerTokenAdapterTests.swift
//  PalaceTests
//
//  Mutation-killing tests for `BearerTokenAdapter` — the two-step
//  CM-fulfill flow carve-out from pre-swarm `AudiobookLoader.swift` lines
//  384-391 (bearer-token detection + recursion).
//
//  Both legs of the two-step flow are stubbed via constructor-injected
//  collaborators: the first-leg fetch returns the bearer-token wrapper
//  JSON, and the manifest fetcher returns the real manifest. Tests drive
//  every branch the original code took without touching URLSession or
//  AppContainer.production().
//
//  The TPPBook mutation paths (`book.bearerToken` / `book.bearerTokenFulfillURL`)
//  write to Keychain — the dedicated side-effect test that asserts those
//  values short-circuits with `KeychainAvailability.skipIfUnavailable()`
//  per CLAUDE.local.md's CI-safe-tests guidance.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class BearerTokenAdapterTests: XCTestCase {

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

    // MARK: - Stubs

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
            let box = SendableBox(value: completion)
            DispatchQueue.main.async { [stubbedData, stubbedResponse, stubbedError] in
                box.value(stubbedData, stubbedResponse, stubbedError)
            }
        }
    }

    private final class StubManifestFetcher: BearerTokenManifestFetching {
        var stubbedJSON: [String: Any]?
        private(set) var receivedTokens: [MyBooksSimplifiedBearerToken] = []
        private(set) var receivedBookIdentifiers: [String] = []
        private(set) var callCount: Int = 0

        func fetchManifest(
            with token: MyBooksSimplifiedBearerToken,
            for book: TPPBook,
            completion: @escaping ([String: Any]?) -> Void
        ) {
            callCount += 1
            receivedTokens.append(token)
            receivedBookIdentifiers.append(book.identifier)
            let box = SendableBox(value: (json: stubbedJSON, completion: completion))
            DispatchQueue.main.async {
                box.value.completion(box.value.json)
            }
        }
    }

    // MARK: - Helpers

    private let oneHour: TimeInterval = 3_600
    private let testLocation = URL(string: "https://library.test/audio/manifest.json")!

    private func bearerTokenWrapperData(
        location: String = "https://library.test/audio/manifest.json",
        accessToken: String = "test-access-token-12345",
        expiresIn: Int = 3600
    ) -> Data {
        let wrapper: [String: Any] = [
            "location": location,
            "access_token": accessToken,
            "expires_in": expiresIn
        ]
        return try! JSONSerialization.data(withJSONObject: wrapper, options: [])
    }

    private func makeBook() -> TPPBook {
        TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    }

    private func makeResponse(url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    // MARK: - canHandle

    /// `canHandle` returns `true` so the loader chain can invoke this
    /// adapter when it suspects a bearer-token fulfill flow. The actual
    /// dispatch decision lives in Module D. Mutation point: flipping
    /// `return true` to `return false` would prevent the adapter from
    /// ever running; this test fails the mutant.
    func testCanHandle_anyBookWithAcquisition_returnsTrue() {
        let network = StubNetwork()
        let fetcher = StubManifestFetcher()
        let adapter = BearerTokenAdapter(network: network, manifestFetcher: fetcher)

        XCTAssertTrue(
            adapter.canHandle(makeBook()),
            "BearerToken adapter must signal it can drive any book — Module D's dispatch picks when to invoke"
        )
    }

    // MARK: - Detection + recursion

    /// First leg returns a bearer-token wrapper. Adapter MUST detect it
    /// and invoke the second-leg manifest fetcher with the parsed token.
    /// Mutation point: removing the `if let bearerToken = ...` branch
    /// would skip the recursion; this test fails the mutant by asserting
    /// `manifestFetcher.callCount > 0`.
    func testResolveManifest_detectsBearerTokenInResponse_recursesToLocationURL() {
        let network = StubNetwork()
        let book = makeBook()
        let fulfillURL = book.defaultAcquisition!.hrefURL
        network.stubbedData = bearerTokenWrapperData()
        network.stubbedResponse = makeResponse(url: fulfillURL)

        let fetcher = StubManifestFetcher()
        // Stub returns a real manifest so resolution completes.
        fetcher.stubbedJSON = ["@type": "Audiobook", "title": "Real Manifest"]

        let adapter = BearerTokenAdapter(network: network, manifestFetcher: fetcher)
        let exp = expectation(description: "two-leg fulfill completes")
        adapter.resolveManifest(for: book) { _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(fetcher.callCount, 1,
                       "Bearer-token detection MUST trigger exactly one second-leg fetch")
        XCTAssertEqual(fetcher.receivedTokens.first?.accessToken, "test-access-token-12345",
                       "Parsed token's accessToken must flow through to the recursion")
        XCTAssertEqual(fetcher.receivedTokens.first?.location, URL(string: "https://library.test/audio/manifest.json"),
                       "Parsed token's location must flow through to the recursion")
        XCTAssertEqual(fetcher.receivedBookIdentifiers.first, book.identifier,
                       "Recursion must reference the original book")
    }

    /// Second-leg manifest fetch succeeds — adapter completes with the
    /// REAL manifest, not the wrapper. Mutation point: if the recursion
    /// were short-circuited (e.g. completing with the wrapper JSON
    /// directly), this test fails because the "Real Manifest" title
    /// would not appear in the propagated success payload.
    func testResolveManifest_bearerTokenFetchSuccess_completesWithRealManifest() {
        let network = StubNetwork()
        let book = makeBook()
        network.stubbedData = bearerTokenWrapperData()
        network.stubbedResponse = makeResponse(url: book.defaultAcquisition!.hrefURL)

        let fetcher = StubManifestFetcher()
        fetcher.stubbedJSON = [
            "@type": "Audiobook",
            "title": "Real Manifest",
            "@context": "http://readium.org/webpub-manifest/context.jsonld"
        ]

        let adapter = BearerTokenAdapter(network: network, manifestFetcher: fetcher)
        let exp = expectation(description: "two-leg fulfill returns real manifest")
        var observed: [String: Any]?
        adapter.resolveManifest(for: book) { result in
            if case .success(let value) = result { observed = value.json }
            exp.fulfill()
        }
        // CI-safe timeout: deps are stubbed so the completion fires in ms on
        // the happy path — a generous ceiling only matters when the runner is
        // CPU-starved (e.g. by leaked background work), and never slows the
        // green path. 2.0s was too tight under CI load and flaked.
        wait(for: [exp], timeout: 10.0)

        XCTAssertEqual(observed?["title"] as? String, "Real Manifest",
                       "Adapter completes with the second-leg JSON, NOT the bearer-token wrapper")
        XCTAssertEqual(observed?["@context"] as? String,
                       "http://readium.org/webpub-manifest/context.jsonld",
                       "Full manifest payload propagates verbatim through the recursion")
    }

    /// Second-leg manifest fetch returns nil — adapter MUST surface
    /// `.manifestFetchFailed` rather than completing with an empty
    /// success or hanging. Mutation point: changing the
    /// `guard let manifestJSON` to `if let` (with no else) would either
    /// hang or complete with nil — this test fails the mutant.
    func testResolveManifest_bearerTokenFetchFails_failsWithManifestFetchFailed() {
        let network = StubNetwork()
        let book = makeBook()
        network.stubbedData = bearerTokenWrapperData()
        network.stubbedResponse = makeResponse(url: book.defaultAcquisition!.hrefURL)

        let fetcher = StubManifestFetcher()
        fetcher.stubbedJSON = nil  // Second leg failure.

        let adapter = BearerTokenAdapter(network: network, manifestFetcher: fetcher)
        let exp = expectation(description: "second-leg failure surfaces")
        var observed: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observed = err }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        guard case .manifestFetchFailed = observed else {
            XCTFail("Second-leg nil must map to .manifestFetchFailed, got \(String(describing: observed))")
            return
        }
        XCTAssertEqual(fetcher.callCount, 1,
                       "Second-leg fetcher was invoked exactly once before failing")
    }

    /// Side-effect verification: detecting a bearer-token wrapper MUST
    /// pass it to the second-leg fetcher with `bearerToken.fulfillURL`
    /// set to the original acquisition URL. This is the load-bearing
    /// state mutation the playback layer relies on for re-auth.
    ///
    /// Keychain-dependent: the adapter writes `book.bearerToken` to the
    /// Keychain via TPPKeychainVariable; verifying the value back through
    /// the book accessor requires Keychain access at runtime. Skip on
    /// hosts where Keychain is unavailable per CLAUDE.md guidance.
    func testResolveManifest_setsBookBearerTokenSideEffect() throws {
        try KeychainAvailability.skipIfUnavailable()

        let network = StubNetwork()
        let book = makeBook()
        let fulfillURL = book.defaultAcquisition!.hrefURL
        network.stubbedData = bearerTokenWrapperData(accessToken: "side-effect-token")
        network.stubbedResponse = makeResponse(url: fulfillURL)

        let fetcher = StubManifestFetcher()
        fetcher.stubbedJSON = ["@type": "Audiobook"]

        let adapter = BearerTokenAdapter(network: network, manifestFetcher: fetcher)
        let exp = expectation(description: "side-effect flush")
        adapter.resolveManifest(for: book) { _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        // The token passed to the fetcher MUST carry the fulfillURL the
        // adapter assigned — covers `bearerToken.fulfillURL = url`.
        XCTAssertEqual(fetcher.receivedTokens.first?.fulfillURL, fulfillURL,
                       "Adapter must set bearerToken.fulfillURL to the original acquisition URL")
        // And the book itself records the token + URL so playback can
        // re-auth on expiration. Covers `book.bearerToken = ...` and
        // `book.bearerTokenFulfillURL = url`.
        XCTAssertEqual(book.bearerToken, "side-effect-token",
                       "Adapter must write the parsed access token onto the book for playback re-auth")
        XCTAssertEqual(book.bearerTokenFulfillURL, fulfillURL,
                       "Adapter must record the fulfill URL on the book for refresh")
    }
}
