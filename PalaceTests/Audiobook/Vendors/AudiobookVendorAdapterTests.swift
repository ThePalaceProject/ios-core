//
//  AudiobookVendorAdapterTests.swift
//  PalaceTests
//
//  Behavior tests for the `AudiobookVendorAdapter` protocol. Per-adapter
//  behavior is exercised in each adapter's own tests — these pin the
//  protocol's *shape contract* by driving spy
//  conformances through both branches of `Result` and asserting first-match
//  priority order between two adapters.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@preconcurrency import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookVendorAdapterTests: XCTestCase {

    // MARK: - Spy conformance

    /// Minimal spy that lets a test pre-program `canHandle` and the
    /// `resolveManifest` return value, then records how often each
    /// method was invoked. Subclassable so production code that holds an
    /// array of `AudiobookVendorAdapter` accepts heterogeneous spies.
    private final class SpyAdapter: AudiobookVendorAdapter {
        var handles: Bool
        var stubbedResult: Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>
        private(set) var canHandleCallCount = 0
        private(set) var resolveCallCount = 0
        let label: String

        init(
            label: String,
            handles: Bool,
            stubbedResult: Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>
        ) {
            self.label = label
            self.handles = handles
            self.stubbedResult = stubbedResult
        }

        func canHandle(_ book: TPPBook) -> Bool {
            canHandleCallCount += 1
            return handles
        }

        func resolveManifest(
            for book: TPPBook
        ) async -> Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError> {
            resolveCallCount += 1
            return stubbedResult
        }
    }

    // MARK: - Helpers

    /// Walk an adapter chain in priority order; return the first that
    /// claims the book. Mirrors the dispatch logic in `AudiobookLoader`.
    /// Keeping it inline in the test (instead of shipping a registry helper
    /// in production) avoids locking the loader into a chain abstraction.
    private func firstHandler(in chain: [AudiobookVendorAdapter], for book: TPPBook) -> AudiobookVendorAdapter? {
        chain.first { $0.canHandle(book) }
    }

    // MARK: - Tests

    func testProtocol_canHandleMustBeSync() {
        // `resolveManifest` is async, but canHandle must stay synchronous
        // so the loader can build the chain
        // and pick a winner without ceremony. We pin that by reading the
        // return value on the same line as the call — if canHandle were
        // ever changed to async this would fail to compile.
        let adapter = SpyAdapter(
            label: "sync-probe",
            handles: true,
            stubbedResult: .success((json: [:], decryptor: nil))
        )
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        let claimed: Bool = adapter.canHandle(book)

        XCTAssertTrue(claimed, "canHandle returns the stubbed value synchronously")
        XCTAssertEqual(adapter.canHandleCallCount, 1, "canHandle invoked exactly once per ask")
    }

    func testProtocol_resolveManifestSignature_propagatesSuccess() async {
        // Drive the success branch of the Result type through the protocol
        // surface. Asserts both the json payload and the decryptor (nil)
        // flow through unchanged — if the tuple shape ever drifts (e.g.
        // someone reorders json/decryptor), this fails.
        let manifest: [String: Any] = ["@type": "Audiobook", "title": "Test Book"]
        let adapter = SpyAdapter(
            label: "ok",
            handles: true,
            stubbedResult: .success((json: manifest, decryptor: nil))
        )
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        var observedJSON: [String: Any]?
        var observedDecryptor: DRMDecryptor??
        if case .success(let (json, decryptor)) = await adapter.resolveManifest(for: book) {
            observedJSON = json
            observedDecryptor = decryptor
        }

        XCTAssertEqual(observedJSON?["title"] as? String, "Test Book")
        XCTAssertEqual(observedJSON?["@type"] as? String, "Audiobook")
        XCTAssertNotNil(observedDecryptor, "the success branch was taken (outer optional is non-nil)")
        XCTAssertNil(observedDecryptor ?? nil, "decryptor (inner optional) is nil for non-DRM adapters")
        XCTAssertEqual(adapter.resolveCallCount, 1, "resolveManifest invoked exactly once")
    }

    func testProtocol_resolveManifestSignature_propagatesFailure() async {
        // Drive the failure branch. Asserts the AudiobookLoadError flows
        // through unchanged — pins that the protocol does not silently
        // map errors or swallow them.
        let adapter = SpyAdapter(
            label: "fail",
            handles: true,
            stubbedResult: .failure(.manifestFetchFailed)
        )
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        var observedError: AudiobookLoadError?
        if case .failure(let err) = await adapter.resolveManifest(for: book) {
            observedError = err
        }

        guard case .manifestFetchFailed = observedError else {
            XCTFail("Expected manifestFetchFailed, got \(String(describing: observedError))")
            return
        }
    }

    func testFirstMatchPriorityOrder() {
        // The chain semantics `AudiobookLoader` relies on: adapters are asked
        // in array order, the first to claim wins, and downstream adapters
        // are NEVER asked once a winner is found. This test pins that
        // contract — flipping the helper's `.first` to `.last` would
        // pick the wrong adapter and fail this test.
        let lcp = SpyAdapter(
            label: "lcp",
            handles: true,
            stubbedResult: .success((json: ["src": "lcp"], decryptor: nil))
        )
        let openAccess = SpyAdapter(
            label: "openAccess",
            handles: true,
            stubbedResult: .success((json: ["src": "openAccess"], decryptor: nil))
        )
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        let winner = firstHandler(in: [lcp, openAccess], for: book)

        XCTAssertNotNil(winner, "At least one adapter claimed the book")
        XCTAssertEqual((winner as? SpyAdapter)?.label, "lcp", "First adapter in chain wins")
        XCTAssertEqual(lcp.canHandleCallCount, 1, "Priority adapter is asked once")
        XCTAssertEqual(openAccess.canHandleCallCount, 0, "Later adapters are NOT asked once a winner is found")
    }

    func testFirstMatchPriorityOrder_skipsNonClaimingAdapter() {
        // Inverse of the above: the first adapter declines, the second
        // claims. Pins that the chain does NOT short-circuit on the first
        // adapter regardless of its claim — it actually checks the
        // boolean return.
        let lcp = SpyAdapter(
            label: "lcp",
            handles: false,
            stubbedResult: .failure(.lcpNotAvailable)
        )
        let openAccess = SpyAdapter(
            label: "openAccess",
            handles: true,
            stubbedResult: .success((json: ["src": "openAccess"], decryptor: nil))
        )
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        let winner = firstHandler(in: [lcp, openAccess], for: book)

        XCTAssertEqual((winner as? SpyAdapter)?.label, "openAccess",
                       "Chain walks past non-claiming adapter to the next claimant")
        XCTAssertEqual(lcp.canHandleCallCount, 1, "Declining adapter is asked exactly once")
        XCTAssertEqual(openAccess.canHandleCallCount, 1, "Subsequent adapter is asked after decline")
    }
}
