//
//  AudiobookLoaderReleasedMidLoadTests.swift
//  PalaceTests
//
//  The session manager holds the only strong reference to an in-flight
//  AudiobookLoader and awaits its completion with no timeout. Closing the book
//  mid-load releases the loader, so `load`'s completion must still fire with
//  `.cancelled` rather than never (PP-5302).
//

import XCTest
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookLoaderReleasedMidLoadTests: XCTestCase {

    /// Not a decodable manifest: a loader that stays alive turns it into
    /// `.manifestDecodingFailed`, which tells it apart from `.cancelled`.
    private let undecodableManifest: [String: Any] = ["@type": "Audiobook", "title": "Stub"]

    private var adapter: DeferredAudiobookVendorAdapter!
    private var deliveries: [Result<LoadedAudiobook, AudiobookLoadError>] = []

    override func setUp() async throws {
        try await super.setUp()
        adapter = DeferredAudiobookVendorAdapter()
        deliveries = []
    }

    override func tearDown() async throws {
        adapter = nil
        deliveries = []
        try await super.tearDown()
    }

    /// Starts a load whose manifest fetch is parked in `adapter`. The account
    /// mock has no token, so the token gate passes synchronously.
    private func startLoad(_ loader: AudiobookLoader) {
        loader.load(TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)) { [weak self] result in
            self?.deliveries.append(result)
        }
        XCTAssertEqual(adapter.resolveCallCount, 1, "the load must be parked in the adapter")
    }

    private func makeLoader() -> AudiobookLoader {
        let account = TPPUserAccountMock()
        return AudiobookLoader(adapters: [adapter], currentUserAccount: { account })
    }

    /// Waits for the main-actor hop that delivers the result, then checks it
    /// arrived exactly once.
    private func assertSingleDelivery(isCancelled expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        await awaitConditionAsync(file: file, line: line) { !self.deliveries.isEmpty }
        // Let any second delivery already queued on the main actor land first.
        await Task.yield()
        await drainMainQueueAsync()
        XCTAssertEqual(deliveries.count, 1, "completion must fire exactly once", file: file, line: line)
        guard let result = deliveries.first else { return }
        let isCancelled: Bool
        if case .failure(.cancelled) = result { isCancelled = true } else { isCancelled = false }
        XCTAssertEqual(isCancelled, expected, "delivered \(result)", file: file, line: line)
    }

    /// Loader released while the manifest fetch is in flight, then the fetch
    /// fails: the caller is told `.cancelled` instead of waiting forever.
    func testLoad_loaderReleasedBeforeManifestFailure_reportsCancelled() async {
        var loader: AudiobookLoader? = makeLoader()
        weak var weakLoader = loader
        startLoad(loader!)

        loader = nil
        XCTAssertNil(weakLoader, "the test must hold the only strong reference")
        adapter.complete(with: .failure(.manifestFetchFailed))

        await assertSingleDelivery(isCancelled: true)
    }

    /// Same release, but the fetch succeeds: the late manifest is not built and
    /// the caller is still told `.cancelled`.
    func testLoad_loaderReleasedBeforeManifestSuccess_reportsCancelled() async {
        var loader: AudiobookLoader? = makeLoader()
        weak var weakLoader = loader
        startLoad(loader!)

        loader = nil
        XCTAssertNil(weakLoader, "the test must hold the only strong reference")
        adapter.complete(with: .success((json: undecodableManifest, decryptor: nil)))

        await assertSingleDelivery(isCancelled: true)
    }

    /// Loader alive when the result is produced but released before the
    /// main-actor hop delivers it: the shared exit itself reports `.cancelled`.
    func testLoad_loaderReleasedBetweenResultAndDelivery_reportsCancelled() async {
        var loader: AudiobookLoader? = makeLoader()
        weak var weakLoader = loader
        startLoad(loader!)

        adapter.complete(with: .success((json: undecodableManifest, decryptor: nil)))
        XCTAssertTrue(deliveries.isEmpty, "delivery must still be pending on the main-actor hop")
        loader = nil
        XCTAssertNil(weakLoader, "the test must hold the only strong reference")

        await assertSingleDelivery(isCancelled: true)
    }

    /// Control: a loader that stays alive delivers the pipeline's own result,
    /// so the cases above are not reporting `.cancelled` unconditionally.
    func testLoad_loaderRetained_deliversPipelineResult() async {
        let loader = makeLoader()
        startLoad(loader)

        adapter.complete(with: .failure(.manifestFetchFailed))

        await assertSingleDelivery(isCancelled: false)
        guard case .failure(.manifestFetchFailed)? = deliveries.first else {
            return XCTFail("expected .manifestFetchFailed, got \(String(describing: deliveries.first))")
        }
        withExtendedLifetime(loader) {}
    }
}
