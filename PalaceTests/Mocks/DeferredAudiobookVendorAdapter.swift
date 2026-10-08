//
//  DeferredAudiobookVendorAdapter.swift
//  PalaceTests
//
//  Claims every book and holds its manifest completion until the test calls
//  `complete(with:)`, standing in for a fetch still on the network.
//

@preconcurrency import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel

final class DeferredAudiobookVendorAdapter: AudiobookVendorAdapter {
    typealias ManifestResult = Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>

    private var pending: ((ManifestResult) -> Void)?
    private(set) var resolveCallCount = 0

    func canHandle(_ book: TPPBook) -> Bool { true }

    func resolveManifest(for book: TPPBook, completion: @escaping (ManifestResult) -> Void) {
        resolveCallCount += 1
        pending = completion
    }

    func complete(with result: ManifestResult) {
        let completion = pending
        pending = nil
        completion?(result)
    }
}
