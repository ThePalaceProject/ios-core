//
//  CrossVendorSmokeTests.swift
//  PalaceTests
//
//  SMOKE-MATRIX: audiobook
//  This class is THE entry point for the audiobook cross-vendor smoke gate.
//  `scripts/verify-pr.sh` (Module C of swarm_eefef87a) selects it via
//      -only-testing:PalaceTests/AudiobookCrossVendorSmokeTests
//  when any `Palace/Audiobooks/` or `ios-audiobooktoolkit/` file is in the
//  diff. Renaming or removing this class WILL fail the gate. See:
//    .forgeos/swarms/swarm_eefef87a/contracts/B-AudiobookCrossVendorSmoke.md
//    .forgeos/swarms/swarm_eefef87a/contracts/C-Tooling.md
//
//  Why this exists: `PalaceAudiobookToolkit` is the highest-risk dependency
//  in the project — 25+ revisions across releases with frequent regressions
//  requiring reverts (see `reference_audiobook_toolkit_risk_profile.md`).
//  Each audiobook fix risks breaking another playback path because all four
//  active vendor adapters share the same player infrastructure. This file is
//  the breadth-not-depth smoke net that runs on every toolkit-touching PR.
//
//  Active vendors covered (one method each):
//    1. LCP        — DRM-fulfilled audiobook (LCP license + Readium)
//    2. BearerToken — Overdrive-shape two-leg fulfill (wrapper → manifest)
//    3. OpenAccess  — single-leg unauthenticated manifest fetch
//    4. LocalFile   — manifest already on disk (post-download replay)
//
//  Findaway is referenced in the toolkit risk-profile memory pin but is NOT
//  an active adapter in `Palace/Audiobooks/Vendors/` — `grep findaway` only
//  surfaces a constant in `TPPOPDSAcquisitionPath.swift`. The four above are
//  the active adapter set; Findaway absence is intentional, not missed.
//
//  Smoke contract per case (adapter seam, not deep playback):
//    - Build the vendor's `AudiobookVendorAdapter` with stubbed collaborators
//      from the existing per-adapter test pattern (no real network/disk/DRM).
//    - Pump a single-track Readium webpub manifest through `resolveManifest`.
//    - Assert success: non-nil JSON, `readingOrder` non-empty (single track).
//    - Assert the vendor's wire-through seam was hit exactly once.
//  Deep per-adapter behavior (every failure-mode branch, source-selection
//  precedence, MIME nesting) lives in `PalaceTests/Audiobook/Vendors/*` —
//  this file is intentionally shallow.
//
//  Scope honesty (QA review rev_0d6da02f): these tests verify **adapter
//  wire-through**, NOT playback-state advancement. The method names use
//  `_wiresThrough*` rather than `_singleTrackLoadAndAdvance` to reflect
//  this — the toolkit's 25+-revision regression history is largely about
//  playback-engine bugs (chapter-transition crashes, position-write races,
//  continuation-misuse SIGABRT) which live INSIDE `PalaceAudiobookToolkit`,
//  not at the Palace-side adapter seam. This smoke matrix is the cheap
//  first-line net for adapter-level regressions; playback-engine regressions
//  belong to (a) toolkit-internal tests and (b) the simdrive E2E corpus
//  under `.simdrive/replays/chaos/`. Do NOT rely on this file for playback
//  coverage.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class AudiobookCrossVendorSmokeTests: XCTestCase {

    /// Test-only carrier that lets a non-Sendable value (a completion closure
    /// or a manifest payload) cross a `@Sendable` dispatch closure under
    /// Swift 6. Each box is created and consumed exactly once on the same
    /// serial test flow, so unchecked Sendable is safe here.
    private struct SendableBox<T>: @unchecked Sendable {
        let value: T
    }

    // MARK: - Shared single-track manifest fixture

    /// Readium webpub manifest with exactly one entry in `readingOrder` —
    /// the minimal shape every active vendor's resolved manifest must
    /// satisfy for `PlaybackBootstrapper` to construct a player.
    private func singleTrackManifestJSON() -> [String: Any] {
        return [
            "@context": "http://readium.org/webpub-manifest/context.jsonld",
            "@type": "Audiobook",
            "metadata": [
                "@type": "Audiobook",
                "title": "Smoke Single Track"
            ],
            "readingOrder": [
                [
                    "href": "track-1.mp3",
                    "type": "audio/mpeg",
                    "duration": 60
                ]
            ]
        ]
    }

    private func singleTrackManifestData() throws -> Data {
        try JSONSerialization.data(withJSONObject: singleTrackManifestJSON(), options: [])
    }

    private func httpOK(url: URL, contentType: String = "application/json") -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        ) else {
            preconditionFailure("HTTPURLResponse initializer returned nil for url=\(url)")
        }
        return response
    }

    private func makeAudiobookBook() -> TPPBook {
        TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    }

    /// Shared assertion the smoke matrix runs against each vendor's
    /// resolved manifest. Pins the single-track shape `PlaybackBootstrapper`
    /// consumes downstream.
    private func assertSingleTrackManifest(
        _ resolved: (json: [String: Any], decryptor: DRMDecryptor?)?,
        expectTitle: String = "Smoke Single Track",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let json = resolved?.json else {
            XCTFail("Expected non-nil resolved manifest JSON", file: file, line: line)
            return
        }
        let metadata = json["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["title"] as? String, expectTitle,
                       "Manifest title must propagate through adapter resolution",
                       file: file, line: line)
        let readingOrder = json["readingOrder"] as? [[String: Any]] ?? []
        XCTAssertEqual(readingOrder.count, 1,
                       "Single-track manifest must surface exactly one reading-order entry",
                       file: file, line: line)
        XCTAssertEqual(readingOrder.first?["href"] as? String, "track-1.mp3",
                       "Track href must propagate verbatim — downstream PlaybackBootstrapper keys off this",
                       file: file, line: line)
    }

    // MARK: - LCP

    /// Minimal `LCPAdapterDownloadCenter` stub — only `fileUrl(for:)` is
    /// exercised by the LCP source-selection branch.
    private final class StubLCPDownloadCenter: LCPAdapterDownloadCenter {
        var fileURLByIdentifier: [String: URL] = [:]
        private(set) var fileUrlCallCount = 0
        func fileUrl(for identifier: String) -> URL? {
            fileUrlCallCount += 1
            return fileURLByIdentifier[identifier]
        }
    }

    /// LCP network executor stub — covers the license re-download path.
    /// Records the URL it was asked to GET.
    private final class StubLCPNetworkExecutor: LCPAdapterNetworkExecutor {
        var stubbedData: Data?
        var stubbedResponse: URLResponse?
        var stubbedError: Error?
        private(set) var getCallCount = 0

        func GET(
            _ reqURL: URL,
            completion: @escaping (Data?, URLResponse?, Error?) -> Void
        ) -> URLSessionDataTask? {
            getCallCount += 1
            completion(stubbedData, stubbedResponse, stubbedError)
            return nil
        }
    }

    /// LCP smoke: with a local `.lcpa` file present, the adapter must hand
    /// that URL to the `LCPAudiobooks` factory (the wire-through signal).
    /// We can't smoke the full DRM round-trip without a real Readium
    /// package — that's the per-adapter test suite's job (LCPAdapterTests).
    /// The smoke here pins the cross-vendor invariant: "the LCP adapter
    /// reached its factory seam with the right URL" — if the toolkit churn
    /// broke `prepareLCPSource`, this test fails before any deeper test
    /// has a chance.
    func testSmoke_LCP_wiresThroughToAudiobooksFactory() async throws {
        #if LCP
        let book = makeAudiobookBook()

        let downloadCenter = StubLCPDownloadCenter()
        let localFileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookCrossVendorSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localFileDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localFileDir) }
        let localURL = localFileDir.appendingPathComponent("\(book.identifier).lcpa")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: localURL) // ZIP magic — placeholder bytes
        downloadCenter.fileURLByIdentifier[book.identifier] = localURL

        let networkExecutor = StubLCPNetworkExecutor()
        var capturedFactoryURL: URL?
        var factoryCallCount = 0
        let adapter = LCPAdapter(
            downloadCenter: downloadCenter,
            networkExecutor: networkExecutor,
            lcpAudiobooksFactory: { url in
                factoryCallCount += 1
                capturedFactoryURL = url
                return nil // forces .lcpInstantiationFailed — smoke targets the wire-through, not deeper Readium
            }
        )

        let resolveExpectation = expectation(description: "LCP smoke resolveManifest completes")
        var observedError: AudiobookLoadError?
        adapter.resolveManifest(for: book) { result in
            if case .failure(let err) = result { observedError = err }
            resolveExpectation.fulfill()
        }
        await fulfillment(of: [resolveExpectation], timeout: 2.0)

        XCTAssertEqual(factoryCallCount, 1,
                       "LCP wire-through: factory must be invoked exactly once when local source resolves")
        XCTAssertEqual(capturedFactoryURL, localURL,
                       "LCP source-selection must pass the local .lcpa URL to the LCPAudiobooks factory")
        XCTAssertEqual(networkExecutor.getCallCount, 0,
                       "LCP smoke: local file present means no license re-download — no network hop")
        XCTAssertEqual(downloadCenter.fileUrlCallCount, 1,
                       "LCP source-selection must consult downloadCenter.fileUrl exactly once")
        guard case .lcpInstantiationFailed = observedError else {
            XCTFail("LCP smoke expected .lcpInstantiationFailed from the stubbed factory, got \(String(describing: observedError))")
            return
        }
        #else
        throw XCTSkip("LCP feature is disabled in this build configuration (Palace-noDRM)")
        #endif
    }

    // MARK: - BearerToken (Overdrive surface)

    /// Network stub for the first-leg fetch (manifest fetch returning a
    /// bearer-token wrapper). Records the URLs it was asked to fetch.
    private final class StubBearerTokenNetwork: AudiobookManifestNetworkFetching {
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

    /// Second-leg manifest fetcher stub. Records the bearer tokens it was
    /// handed and returns a stubbed manifest JSON.
    private final class StubBearerTokenManifestFetcher: BearerTokenManifestFetching {
        var stubbedJSON: [String: Any]?
        private(set) var callCount: Int = 0

        func fetchManifest(
            with token: MyBooksSimplifiedBearerToken,
            for book: TPPBook,
            completion: @escaping ([String: Any]?) -> Void
        ) {
            callCount += 1
            let box = SendableBox(value: (json: stubbedJSON, completion: completion))
            DispatchQueue.main.async {
                box.value.completion(box.value.json)
            }
        }
    }

    /// BearerToken smoke: drive a single-track manifest through the
    /// two-leg fulfill flow. First leg returns the bearer-token wrapper;
    /// second leg returns the real manifest. The adapter must surface the
    /// real manifest (NOT the wrapper) and invoke each leg exactly once.
    func testSmoke_BearerToken_wiresThroughTwoLegManifestFetch() async throws {
        let book = makeAudiobookBook()
        guard let fulfillURL = book.defaultAcquisition?.hrefURL else {
            return XCTFail("Mock book missing default acquisition URL — fixture invariant broken")
        }

        let wrapper: [String: Any] = [
            "location": "https://library.test/audio/manifest.json",
            "access_token": "smoke-bearer-token",
            "expires_in": 3600
        ]
        let network = StubBearerTokenNetwork()
        network.stubbedData = try JSONSerialization.data(withJSONObject: wrapper, options: [])
        network.stubbedResponse = httpOK(url: fulfillURL)

        let fetcher = StubBearerTokenManifestFetcher()
        fetcher.stubbedJSON = singleTrackManifestJSON()

        let adapter = BearerTokenAdapter(network: network, manifestFetcher: fetcher)

        let resolveExpectation = expectation(description: "BearerToken smoke resolveManifest completes")
        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        adapter.resolveManifest(for: book) { result in
            if case .success(let value) = result { observed = value }
            resolveExpectation.fulfill()
        }
        await fulfillment(of: [resolveExpectation], timeout: 2.0)

        assertSingleTrackManifest(observed)
        XCTAssertEqual(network.requestedURLs.count, 1,
                       "BearerToken wire-through: exactly one first-leg network fetch")
        XCTAssertEqual(network.requestedURLs.first, fulfillURL,
                       "First-leg fetch must hit the book's default acquisition URL")
        XCTAssertEqual(fetcher.callCount, 1,
                       "BearerToken wire-through: exactly one second-leg manifest fetch after wrapper detection")
        XCTAssertNil(observed?.decryptor,
                     "BearerToken flow produces no DRM decryptor — must be nil")
    }

    // MARK: - OpenAccess

    /// Reuse `StubBearerTokenNetwork` shape for OpenAccess too — both
    /// conform to `AudiobookManifestNetworkFetching` so the seam is
    /// identical; the adapter differs in what it does with the bytes.
    /// We keep separate stub classes per case to keep each smoke test
    /// self-contained and the assertions unambiguous.
    private final class StubOpenAccessNetwork: AudiobookManifestNetworkFetching {
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

    /// OpenAccess smoke: single-leg manifest fetch returns the manifest
    /// JSON directly (no bearer-token wrapper). Adapter must propagate
    /// the manifest verbatim and invoke the network seam exactly once.
    func testSmoke_OpenAccess_wiresThroughSingleLegManifestFetch() async throws {
        let book = makeAudiobookBook()
        guard let fulfillURL = book.defaultAcquisition?.hrefURL else {
            return XCTFail("Mock book missing default acquisition URL — fixture invariant broken")
        }

        let network = StubOpenAccessNetwork()
        network.stubbedData = try singleTrackManifestData()
        network.stubbedResponse = httpOK(url: fulfillURL)

        let adapter = OpenAccessAdapter(network: network)

        let resolveExpectation = expectation(description: "OpenAccess smoke resolveManifest completes")
        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        adapter.resolveManifest(for: book) { result in
            if case .success(let value) = result { observed = value }
            resolveExpectation.fulfill()
        }
        await fulfillment(of: [resolveExpectation], timeout: 2.0)

        assertSingleTrackManifest(observed)
        XCTAssertEqual(network.requestedURLs.count, 1,
                       "OpenAccess wire-through: exactly one network fetch")
        XCTAssertEqual(network.requestedURLs.first, fulfillURL,
                       "OpenAccess fetch must hit the book's default acquisition URL")
        XCTAssertNil(observed?.decryptor,
                     "OpenAccess flow produces no DRM decryptor — must be nil")
    }

    // MARK: - LocalFile

    /// `MyBooksDownloadCenterProviding` stub — LocalFile only exercises
    /// `fileUrl(for:)`. Other methods are intentionally unimplemented; if
    /// the adapter ever reaches for borrow/cancel/return, the smoke fails
    /// loudly via XCTFail rather than silently passing.
    private final class StubLocalDownloadCenter: MyBooksDownloadCenterProviding {
        var stubbedFileURL: URL?

        var downloadProgressPublisher = PassthroughSubject<(String, Double), Never>()
        var downloadErrorPublisher = PassthroughSubject<DownloadErrorInfo, Never>()

        func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
            XCTFail("LocalFile smoke must not call startBorrow")
        }
        func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest?) {
            XCTFail("LocalFile smoke must not call startDownload")
        }
        func cancelDownload(for identifier: String) {
            XCTFail("LocalFile smoke must not call cancelDownload")
        }
        func deleteLocalContent(for identifier: String, account: String?) {
            XCTFail("LocalFile smoke must not call deleteLocalContent")
        }
        func returnBook(withIdentifier identifier: String, completion: (() -> Void)?) {
            XCTFail("LocalFile smoke must not call returnBook")
        }
        func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo? { nil }
        func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo? { nil }
        func fileUrl(for identifier: String) -> URL? { stubbedFileURL }
        func fileUrl(for identifier: String, account: String?) -> URL? { stubbedFileURL }
        func broadcastUpdate() { /* no-op */ }
        func reset() { /* no-op */ }
    }

    /// In-memory file reader stub — `existsResponse` controls `canHandle`'s
    /// disk check; `dataResponse` controls the read path.
    private final class StubLocalFileReader: AudiobookFileReading {
        var existsResponse: Bool = false
        var dataResponse: Result<Data, Error> = .failure(NSError(domain: "stub", code: 0))
        private(set) var readURLs: [URL] = []

        func fileExists(atPath path: String) -> Bool { existsResponse }
        func data(at url: URL) throws -> Data {
            readURLs.append(url)
            switch dataResponse {
            case .success(let data): return data
            case .failure(let err): throw err
            }
        }
    }

    /// Token refresher stub — for the smoke we drive the no-fulfill-URL
    /// branch so refresh stays off the wire and the case is keychain-free.
    private final class StubLocalTokenRefresher: BearerTokenRefreshing {
        private(set) var callCount: Int = 0
        func refreshToken(
            from fulfillURL: URL,
            completion: @escaping (MyBooksSimplifiedBearerToken?) -> Void
        ) {
            callCount += 1
            let box = SendableBox(value: completion)
            DispatchQueue.main.async { box.value(nil) }
        }
    }

    /// LocalFile smoke: manifest is already on disk (post-download replay).
    /// Adapter reads it via the injected file reader, no network, no
    /// keychain. With `bearerTokenFulfillURL` unset on the book, the
    /// refresh branch is skipped so the case runs keychain-free.
    func testSmoke_LocalFile_wiresThroughLocalManifestRead() async throws {
        let book = makeAudiobookBook()

        let downloadCenter = StubLocalDownloadCenter()
        let manifestURL = URL(fileURLWithPath: "/tmp/cross-vendor-smoke-\(book.identifier).json")
        downloadCenter.stubbedFileURL = manifestURL

        let fileReader = StubLocalFileReader()
        fileReader.existsResponse = true
        fileReader.dataResponse = .success(try singleTrackManifestData())

        let tokenRefresher = StubLocalTokenRefresher()

        let adapter = LocalFileAdapter(
            downloadCenter: downloadCenter,
            fileReader: fileReader,
            tokenRefresher: tokenRefresher
        )

        // canHandle must return true on a local-file replay — that's the
        // chain placement signal the loader relies on.
        XCTAssertTrue(adapter.canHandle(book),
                      "LocalFile.canHandle must return true when both URL and file-exists check succeed")

        let resolveExpectation = expectation(description: "LocalFile smoke resolveManifest completes")
        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        adapter.resolveManifest(for: book) { result in
            if case .success(let value) = result { observed = value }
            resolveExpectation.fulfill()
        }
        await fulfillment(of: [resolveExpectation], timeout: 2.0)

        assertSingleTrackManifest(observed)
        XCTAssertEqual(fileReader.readURLs.count, 1,
                       "LocalFile wire-through: exactly one file read from the provided URL")
        XCTAssertEqual(fileReader.readURLs.first, manifestURL,
                       "LocalFile adapter must read from the URL the download center provided")
        XCTAssertEqual(tokenRefresher.callCount, 0,
                       "Smoke: bearerTokenFulfillURL is unset so refresh path must be skipped")
        XCTAssertNil(observed?.decryptor,
                     "LocalFile flow produces no DRM decryptor — must be nil")
    }
}
