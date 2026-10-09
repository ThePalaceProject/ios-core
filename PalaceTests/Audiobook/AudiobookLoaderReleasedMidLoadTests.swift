//
//  AudiobookLoaderReleasedMidLoadTests.swift
//  PalaceTests
//
//  The session manager awaits `load` with no timeout, so every open must end in
//  a result. Closing a book mid-load cancels the loader (and drops the session
//  manager's reference); these tests pin that a cancelled load still reports
//  `.cancelled`, and that an uncancelled one reports its own result (PP-5302).
//

import XCTest
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookLoaderReleasedMidLoadTests: XCTestCase {

    /// Not a decodable manifest: a loader that is not cancelled turns it into
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

    private func makeLoader() -> AudiobookLoader {
        let account = TPPUserAccountMock()
        return AudiobookLoader(adapters: [adapter], currentUserAccount: { account })
    }

    /// Starts a load whose manifest fetch is parked in `adapter`. The account
    /// mock has no token, so the token gate passes without a refresh.
    private func startLoad(_ loader: AudiobookLoader) async {
        Task { self.deliveries.append(await loader.load(TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook))) }
        await awaitConditionAsync { self.adapter.resolveCallCount == 1 }
    }

    /// Waits for the result, then checks it arrived exactly once.
    private func singleDelivery(file: StaticString = #filePath, line: UInt = #line) async -> Result<LoadedAudiobook, AudiobookLoadError>? {
        await awaitConditionAsync(file: file, line: line) { !self.deliveries.isEmpty }
        await Task.yield()
        XCTAssertEqual(deliveries.count, 1, "load must return exactly once", file: file, line: line)
        return deliveries.first
    }

    private func isCancelled(_ result: Result<LoadedAudiobook, AudiobookLoadError>?) -> Bool {
        if case .failure(.cancelled)? = result { return true }
        return false
    }

    /// Closing mid-load cancels the loader; a fetch that then fails is
    /// reported as `.cancelled`.
    func testLoad_cancelledMidLoadThenManifestFails_reportsCancelled() async {
        let loader = makeLoader()
        await startLoad(loader)

        loader.cancel()
        adapter.complete(with: .failure(.manifestFetchFailed))

        let result = await singleDelivery()
        XCTAssertTrue(isCancelled(result), "got \(String(describing: result))")
    }

    /// Same cancel, but the fetch succeeds: the caller is still told
    /// `.cancelled`.
    func testLoad_cancelledMidLoadThenManifestSucceeds_reportsCancelled() async {
        let loader = makeLoader()
        await startLoad(loader)

        loader.cancel()
        adapter.complete(with: .success((json: undecodableManifest, decryptor: nil)))

        let result = await singleDelivery()
        XCTAssertTrue(isCancelled(result), "got \(String(describing: result))")
    }

    /// Control: an uncancelled loader delivers the pipeline's own result, so
    /// the cases above are not reporting `.cancelled` unconditionally.
    func testLoad_notCancelled_deliversPipelineResult() async {
        let loader = makeLoader()
        await startLoad(loader)

        adapter.complete(with: .success((json: undecodableManifest, decryptor: nil)))

        let result = await singleDelivery()
        guard case .failure(.manifestDecodingFailed)? = result else {
            return XCTFail("expected .manifestDecodingFailed, got \(String(describing: result))")
        }
    }
}
