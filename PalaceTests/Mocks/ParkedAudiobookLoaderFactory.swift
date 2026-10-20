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

    func makeLoader() -> AudiobookLoader {
        let adapter = DeferredAudiobookVendorAdapter()
        adapters.append(adapter)
        let userAccount = TPPUserAccountMock()
        return AudiobookLoader(adapters: [adapter], currentUserAccount: { userAccount })
    }
}
