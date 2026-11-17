//
//  LocalFileAdapterTests.swift
//  PalaceTests
//
//  Branch tests for `LocalFileAdapter` — the on-disk manifest path carved
//  out of the original `AudiobookLoader.swift`.
//
//  All three collaborators (download center, file reader, token refresher)
//  are constructor-injected stubs. The test cases drive both branches of
//  `canHandle`, the disk-read success/failure mapping, and both sides of
//  the bearer-token-fulfill-URL conditional that refreshes the token
//  before completing playback.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@preconcurrency import PalaceAudiobookToolkit
@preconcurrency @testable import Palace
import PalaceBookModel

@MainActor
final class LocalFileAdapterTests: XCTestCase {

    // MARK: - Stub collaborators

    /// Minimal `MyBooksDownloadCenterProviding` stub — most surface area
    /// of the protocol is irrelevant to LocalFileAdapter. Only
    /// `fileUrl(for:)` is exercised; the rest is left intentionally
    /// fatalError-ing so accidental use surfaces loudly.
    private final class StubDownloadCenter: MyBooksDownloadCenterProviding {
        var stubbedFileURL: URL?

        var downloadProgressPublisher = PassthroughSubject<(String, Double), Never>()
        var downloadErrorPublisher = PassthroughSubject<DownloadErrorInfo, Never>()

        func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
            XCTFail("LocalFileAdapter must not call startBorrow")
        }
        func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest?) {
            XCTFail("LocalFileAdapter must not call startDownload")
        }
        func cancelDownload(for identifier: String) {
            XCTFail("LocalFileAdapter must not call cancelDownload")
        }
        func deleteLocalContent(for identifier: String, account: String?) {
            XCTFail("LocalFileAdapter must not call deleteLocalContent")
        }
        func returnBook(withIdentifier identifier: String, completion: (() -> Void)?) {
            XCTFail("LocalFileAdapter must not call returnBook")
        }
        func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo? { nil }
        func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo? { nil }
        func fileUrl(for identifier: String) -> URL? { stubbedFileURL }
        func fileUrl(for identifier: String, account: String?) -> URL? { stubbedFileURL }
        func broadcastUpdate() { /* no-op */ }
        func reset() { /* no-op */ }
    }

    /// In-memory file reader. `existsResponse` controls `canHandle`'s
    /// disk check; `dataResponse` controls the read path
    /// (`.success(Data)` returns bytes, `.failure(error)` throws).
    private final class StubFileReader: AudiobookFileReading {
        var existsResponse: Bool = false
        var dataResponse: Result<Data, Error> = .failure(NSError(domain: "stub", code: 0))
        private(set) var readURLs: [URL] = []

        func fileExists(atPath path: String) -> Bool {
            existsResponse
        }
        func data(at url: URL) throws -> Data {
            readURLs.append(url)
            switch dataResponse {
            case .success(let data): return data
            case .failure(let err): throw err
            }
        }
    }

    /// Bearer-token refresh seam. Records whether `refreshToken` was
    /// invoked and returns a stubbed token or nil.
    private final class StubTokenRefresher: BearerTokenRefreshing {
        var stubbedToken: MyBooksSimplifiedBearerToken?
        private(set) var callCount: Int = 0
        private(set) var receivedURLs: [URL] = []

        func refreshToken(from fulfillURL: URL) async -> MyBooksSimplifiedBearerToken? {
            callCount += 1
            receivedURLs.append(fulfillURL)
            return stubbedToken
        }
    }

    // MARK: - Helpers

    private func makeBook() -> TPPBook {
        TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
    }

    private let manifestURL = URL(fileURLWithPath: "/tmp/test-manifest.json")

    private func validManifestData(title: String = "Local Book") -> Data {
        try! JSONSerialization.data(withJSONObject: ["@type": "Audiobook", "title": title], options: [])
    }

    private func makeAdapter(
        downloadCenter: StubDownloadCenter,
        fileReader: StubFileReader,
        tokenRefresher: StubTokenRefresher = StubTokenRefresher()
    ) -> LocalFileAdapter {
        LocalFileAdapter(
            downloadCenter: downloadCenter,
            fileReader: fileReader,
            tokenRefresher: tokenRefresher
        )
    }

    // MARK: - canHandle

    func testCanHandle_localFileExists_returnsTrue() {
        let dc = StubDownloadCenter(); dc.stubbedFileURL = manifestURL
        let reader = StubFileReader(); reader.existsResponse = true
        let adapter = makeAdapter(downloadCenter: dc, fileReader: reader)

        XCTAssertTrue(
            adapter.canHandle(makeBook()),
            "canHandle must return true when both URL and file-exists check succeed"
        )
    }

    func testCanHandle_noLocalFile_returnsFalse() {
        // Two failure modes share this assertion: a) downloadCenter
        // returned nil, b) downloadCenter returned a URL but the file
        // doesn't exist. Both must return false so the chain falls
        // through to the network adapters.
        let dcNoURL = StubDownloadCenter(); dcNoURL.stubbedFileURL = nil
        let reader = StubFileReader(); reader.existsResponse = true
        let adapterNoURL = makeAdapter(downloadCenter: dcNoURL, fileReader: reader)
        XCTAssertFalse(adapterNoURL.canHandle(makeBook()),
                       "nil fileUrl must return false")

        let dcWithURL = StubDownloadCenter(); dcWithURL.stubbedFileURL = manifestURL
        let readerMissing = StubFileReader(); readerMissing.existsResponse = false
        let adapterMissing = makeAdapter(downloadCenter: dcWithURL, fileReader: readerMissing)
        XCTAssertFalse(adapterMissing.canHandle(makeBook()),
                       "URL present but fileExists=false must return false")
    }

    // MARK: - resolveManifest

    func testResolveManifest_validJSON_succeeds() async {
        let dc = StubDownloadCenter(); dc.stubbedFileURL = manifestURL
        let reader = StubFileReader()
        reader.existsResponse = true
        reader.dataResponse = .success(validManifestData(title: "Disk Book"))
        let adapter = makeAdapter(downloadCenter: dc, fileReader: reader)

        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        let result = await adapter.resolveManifest(for: makeBook())
            if case .success(let value) = result { observed = value }

        XCTAssertEqual(observed?.json["title"] as? String, "Disk Book",
                       "Parsed disk JSON must propagate through to caller")
        XCTAssertNil(observed?.decryptor,
                     "Local-file path produces no DRM decryptor — must be nil")
        XCTAssertEqual(reader.readURLs.first, manifestURL,
                       "Adapter read from the URL the download center provided")
    }

    func testResolveManifest_unreadableFile_failsWithManifestParseFailed() async {
        let dc = StubDownloadCenter(); dc.stubbedFileURL = manifestURL
        let reader = StubFileReader()
        reader.existsResponse = true
        reader.dataResponse = .failure(
            NSError(domain: "test.read", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        )
        let adapter = makeAdapter(downloadCenter: dc, fileReader: reader)

        var observed: AudiobookLoadError?
        let result = await adapter.resolveManifest(for: makeBook())
            if case .failure(let err) = result { observed = err }

        guard case .manifestParseFailed = observed else {
            XCTFail("Throwing reader must map to .manifestParseFailed, got \(String(describing: observed))")
            return
        }
    }

    /// Bearer-token fulfill URL set → refresher MUST be called BEFORE
    /// completion. Inverting `if let fulfillURL = ...` would skip refresh;
    /// this test catches that by asserting `refresher.callCount > 0`.
    ///
    /// Keychain-dependent because setting `book.bearerTokenFulfillURL`
    /// writes via TPPKeychainVariable. Skip on hosts without Keychain.
    func testResolveManifest_bearerTokenFulfillURL_refreshesTokenBeforeReturn() async throws {
        try KeychainAvailability.skipIfUnavailable()

        let dc = StubDownloadCenter(); dc.stubbedFileURL = manifestURL
        let reader = StubFileReader()
        reader.existsResponse = true
        reader.dataResponse = .success(validManifestData())
        let refresher = StubTokenRefresher()
        refresher.stubbedToken = MyBooksSimplifiedBearerToken(
            accessToken: "refreshed-token",
            expiration: Date().addingTimeInterval(3_600),
            location: URL(string: "https://library.test/audio/manifest.json")!
        )

        let book = makeBook()
        let fulfillURL = URL(string: "https://library.test/audio/fulfill")!
        book.bearerTokenFulfillURL = fulfillURL

        let adapter = makeAdapter(downloadCenter: dc, fileReader: reader, tokenRefresher: refresher)
        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        let result = await adapter.resolveManifest(for: book)
            if case .success(let value) = result { observed = value }

        XCTAssertEqual(refresher.callCount, 1,
                       "Adapter must invoke token refresh exactly once when fulfill URL is set")
        XCTAssertEqual(refresher.receivedURLs.first, fulfillURL,
                       "Refresher must receive the book's bearerTokenFulfillURL")
        XCTAssertEqual(book.bearerToken, "refreshed-token",
                       "Adapter must write the refreshed token back onto the book before completion")
        XCTAssertNotNil(observed?.json,
                        "Manifest JSON still propagates through after refresh")
    }

    /// Bearer-token fulfill URL NOT set → refresher MUST NOT be called.
    /// Companion to the above so the conditional's TRUE/FALSE bifurcation
    /// is fully pinned. Without this, ALWAYS calling
    /// `refresher.refreshToken(...)` would go unnoticed.
    func testResolveManifest_noBearerTokenFulfillURL_skipsRefresh() async {
        let dc = StubDownloadCenter(); dc.stubbedFileURL = manifestURL
        let reader = StubFileReader()
        reader.existsResponse = true
        reader.dataResponse = .success(validManifestData(title: "No Token"))
        let refresher = StubTokenRefresher()
        // book.bearerTokenFulfillURL defaults to nil — the TPPBookMocker
        // does not set it.

        let adapter = makeAdapter(downloadCenter: dc, fileReader: reader, tokenRefresher: refresher)
        var observed: (json: [String: Any], decryptor: DRMDecryptor?)?
        let result = await adapter.resolveManifest(for: makeBook())
            if case .success(let value) = result { observed = value }

        XCTAssertEqual(refresher.callCount, 0,
                       "Adapter must NOT invoke token refresh when fulfill URL is unset")
        XCTAssertEqual(observed?.json["title"] as? String, "No Token",
                       "Disk JSON propagates through unchanged on the no-refresh branch")
    }
}
