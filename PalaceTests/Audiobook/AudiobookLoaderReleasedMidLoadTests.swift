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

    /// Adapter that holds its completion until the test releases it, standing
    /// in for a manifest fetch still on the network when the patron closes.
    private final class DeferredAdapter: AudiobookVendorAdapter {
        private var pending: ((Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void)?
        private(set) var resolveCallCount = 0

        func canHandle(_ book: TPPBook) -> Bool { true }

        func resolveManifest(
            for book: TPPBook,
            completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
        ) {
            resolveCallCount += 1
            pending = completion
        }

        func complete(with result: Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) {
            let completion = pending
            pending = nil
            completion?(result)
        }
    }

    /// Not a decodable manifest: a loader that stays alive turns it into
    /// `.manifestDecodingFailed`, which tells it apart from `.cancelled`.
    private let undecodableManifest: [String: Any] = ["@type": "Audiobook", "title": "Stub"]

    private var adapter: DeferredAdapter!
    private var deliveries: [Result<LoadedAudiobook, AudiobookLoadError>] = []

    override func setUp() {
        super.setUp()
        adapter = DeferredAdapter()
        deliveries = []
    }

    override func tearDown() {
        adapter = nil
        deliveries = []
        super.tearDown()
    }

    /// Starts a load whose manifest fetch is parked in `adapter`. The account
    /// mock has no token, so the token gate passes synchronously.
    private func startLoad(_ loader: AudiobookLoader, fulfilling exp: XCTestExpectation) {
        // A second delivery is counted by `assertSingleDelivery`, not trapped here.
        exp.assertForOverFulfill = false
        loader.load(TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)) { [weak self] result in
            self?.deliveries.append(result)
            exp.fulfill()
        }
        XCTAssertEqual(adapter.resolveCallCount, 1, "the load must be parked in the adapter")
    }

    private func makeLoader() -> AudiobookLoader {
        let account = TPPUserAccountMock()
        return AudiobookLoader(adapters: [adapter], currentUserAccount: { account })
    }

    private func assertSingleDelivery(isCancelled expected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(deliveries.count, 1, "completion must fire exactly once", file: file, line: line)
        guard let result = deliveries.first else { return }
        let isCancelled: Bool
        if case .failure(.cancelled) = result { isCancelled = true } else { isCancelled = false }
        XCTAssertEqual(isCancelled, expected, "delivered \(result)", file: file, line: line)
    }

    /// Loader released while the manifest fetch is in flight, then the fetch
    /// fails: the caller is told `.cancelled` instead of waiting forever.
    func testLoad_loaderReleasedBeforeManifestFailure_reportsCancelled() {
        let exp = expectation(description: "load completion")
        var loader: AudiobookLoader? = makeLoader()
        weak var weakLoader = loader
        startLoad(loader!, fulfilling: exp)

        loader = nil
        XCTAssertNil(weakLoader, "the test must hold the only strong reference")
        adapter.complete(with: .failure(.manifestFetchFailed))

        wait(for: [exp], timeout: 2.0)
        assertSingleDelivery(isCancelled: true)
    }

    /// Same release, but the fetch succeeds: the late manifest is not built and
    /// the caller is still told `.cancelled`.
    func testLoad_loaderReleasedBeforeManifestSuccess_reportsCancelled() {
        let exp = expectation(description: "load completion")
        var loader: AudiobookLoader? = makeLoader()
        weak var weakLoader = loader
        startLoad(loader!, fulfilling: exp)

        loader = nil
        XCTAssertNil(weakLoader, "the test must hold the only strong reference")
        adapter.complete(with: .success((json: undecodableManifest, decryptor: nil)))

        wait(for: [exp], timeout: 2.0)
        assertSingleDelivery(isCancelled: true)
    }

    /// Loader alive when the result is produced but released before the
    /// main-actor hop delivers it: the shared exit itself reports `.cancelled`.
    func testLoad_loaderReleasedBetweenResultAndDelivery_reportsCancelled() {
        let exp = expectation(description: "load completion")
        var loader: AudiobookLoader? = makeLoader()
        weak var weakLoader = loader
        startLoad(loader!, fulfilling: exp)

        adapter.complete(with: .success((json: undecodableManifest, decryptor: nil)))
        XCTAssertTrue(deliveries.isEmpty, "delivery must still be pending on the main-actor hop")
        loader = nil
        XCTAssertNil(weakLoader, "the test must hold the only strong reference")

        wait(for: [exp], timeout: 2.0)
        assertSingleDelivery(isCancelled: true)
    }

    /// Control: a loader that stays alive delivers the pipeline's own result,
    /// so the cases above are not reporting `.cancelled` unconditionally.
    func testLoad_loaderRetained_deliversPipelineResult() {
        let exp = expectation(description: "load completion")
        let loader = makeLoader()
        startLoad(loader, fulfilling: exp)

        adapter.complete(with: .failure(.manifestFetchFailed))

        wait(for: [exp], timeout: 2.0)
        assertSingleDelivery(isCancelled: false)
        guard case .failure(.manifestFetchFailed)? = deliveries.first else {
            return XCTFail("expected .manifestFetchFailed, got \(String(describing: deliveries.first))")
        }
        withExtendedLifetime(loader) {}
    }
}
