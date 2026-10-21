//
//  ParkedAudiobookLoaderFactory.swift
//  PalaceTests
//
//  Hands each `openAudiobook` its own parked adapter, in open order, so a test
//  can hold a load in flight and count how many opens reached the loader.
//

@testable import Palace

@MainActor
final class ParkedAudiobookLoaderFactory {
    private(set) var adapters: [DeferredAudiobookVendorAdapter] = []
    /// Whether each open asked for a fresh manifest instead of the one on disk.
    private(set) var fetchesFreshManifest: [Bool] = []

    /// No default: every caller threads the value production passes, so an
    /// assertion on `fetchesFreshManifest` cannot pass against a hard-coded
    /// `false` the open never sent.
    func makeLoader(fetchesFreshManifest: Bool) -> AudiobookLoader {
        self.fetchesFreshManifest.append(fetchesFreshManifest)
        let adapter = DeferredAudiobookVendorAdapter()
        adapters.append(adapter)
        let userAccount = TPPUserAccountMock()
        return AudiobookLoader(adapters: [adapter], currentUserAccount: { userAccount })
    }
}
