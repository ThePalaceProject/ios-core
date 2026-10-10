//
//  DeferredAudiobookVendorAdapter.swift
//  PalaceTests
//
//  Claims every book and holds `resolveManifest` until the test calls
//  `complete(with:)`, standing in for a fetch still on the network.
//

@preconcurrency import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel

@MainActor
final class DeferredAudiobookVendorAdapter: AudiobookVendorAdapter {
    typealias ManifestResult = Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>

    // The continuation carries no payload: the result is stored here instead,
    // because a manifest dictionary is not `Sendable`.
    private var waiter: CheckedContinuation<Void, Never>?
    private var result: ManifestResult?
    private(set) var resolveCallCount = 0

    func canHandle(_ book: TPPBook) -> Bool { true }

    func resolveManifest(for book: TPPBook) async -> ManifestResult {
        resolveCallCount += 1
        await withCheckedContinuation { waiter = $0 }
        return result ?? .failure(.manifestFetchFailed)
    }

    func complete(with result: ManifestResult) {
        self.result = result
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume()
    }
}
