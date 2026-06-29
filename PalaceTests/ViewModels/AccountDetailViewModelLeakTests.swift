//
//  AccountDetailViewModelLeakTests.swift
//  PalaceTests
//
//  Hermetic leak-repro guard for the AccountDetailViewModel retain cycle
//  (intent: accountdetail-leak-cycle-and-hermetic-network). Deliberately NOT in
//  AccountDetailViewModelTests: that class is keychain-gated
//  (KeychainAvailability.skipIfUnavailable) and SKIPS on hosts without the
//  keychain entitlement (CI sims, -34018), which would silently skip the leak
//  proof. This class seeds a stub account directly (no keychain, no network) so
//  the dealloc assertion always runs.
//
//  Red→green proof: this test FAILED while the 4-hop cycle was intact —
//  VM → businessLogic → networkExecutor → TPPNetworkResponder →
//  credentialsProvider(=VM) — even after the loadInitialData weak-self change
//  (the cycle dominates). It PASSES once `TPPNetworkResponder.credentialsProvider`
//  is `weak`, breaking the only strong back-edge so the VM (and its
//  account-change observers) deallocate after release.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountDetailViewModelLeakTests: XCTestCase {

    private func stubAccount(_ uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(id: uuid, title: "Leak Stub \(uuid.prefix(6))")
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        return Account(publication: publication, imageCache: ImageCache.shared)
    }

    func testViewModel_deallocatesAfterRelease_noLeakedObservers() async {
        let manager = AppContainer.production().accountsManager
        let uuid = "urn:uuid:leak-test-\(UUID().uuidString)"
        // Seed a current account WITHOUT keychain/network so the VM can be
        // constructed hermetically; teardown restores prior state.
        let restore = manager._seedAccountForTesting(stubAccount(uuid))
        defer { restore() }

        weak var weakVM: AccountDetailViewModel?
        do {
            let viewModel = AccountDetailViewModel(libraryAccountID: uuid, appContainer: .production())
            weakVM = viewModel
            XCTAssertNotNil(weakVM, "Precondition: VM exists while strongly held")
            await Task.yield()   // let the @MainActor init Task run
        }
        // Drain the main actor so any in-flight @MainActor Task releases its
        // capture. CI-safe (yield loop, no sleep).
        for _ in 0..<10 { await Task.yield() }

        XCTAssertNil(
            weakVM,
            "AccountDetailViewModel must deallocate after release — the "
            + "TPPNetworkResponder.credentialsProvider strong back-edge (or an "
            + "unbalanced observer) would otherwise keep it and its account-change "
            + "observers alive past its scope"
        )
    }
}
