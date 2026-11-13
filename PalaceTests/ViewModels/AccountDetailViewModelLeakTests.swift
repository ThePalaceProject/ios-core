//  AccountDetailViewModelLeakTests.swift
//
//  Hermetic guard for the AccountDetailViewModel retain cycle VM ->
//  businessLogic -> networkExecutor -> TPPNetworkResponder ->
//  credentialsProvider (= VM), broken by making `credentialsProvider` weak.
//  Kept out of AccountDetailViewModelTests, which skips without the keychain
//  entitlement (CI simulators, -34018); this class seeds a stub account with no
//  keychain or network so the dealloc assertion always runs.

import XCTest
import PalaceCatalog
@testable import Palace

// Subclasses PalaceTestCase (not bare XCTestCase): it touches shared singletons
// (`AppContainer.production()`, `ImageCache.shared`) so the TearDownRequiredLint
// requires a tearDown — inheriting the `*TestCase` base satisfies it AND adds the
// runtime-quiescence floor, which is apt for a hermeticity test.
@MainActor
final class AccountDetailViewModelLeakTests: PalaceTestCase {

    private func stubAccount(_ uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(id: uuid, title: "Leak Stub \(uuid.prefix(6))")
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        return Account(publication: publication, imageCache: ImageCache.shared)
    }

    func testViewModel_deallocatesAfterRelease_noLeakedObservers() async {
        // Hermetic test AppContainer (not .production()) — the retain cycle is
        // internal to the VM's OWN executor (it constructs
        // `TPPNetworkExecutor(credentialsProvider: self)`), so a test container
        // reproduces it identically while keeping the test isolation-lint clean.
        let appContainer = makeTestAppContainer()
        let manager = appContainer.accountsManager
        let uuid = "urn:uuid:leak-test-\(UUID().uuidString)"
        // Seed a current account WITHOUT keychain/network so the VM can be
        // constructed hermetically; teardown restores prior state.
        let restore = manager._seedAccountForTesting(stubAccount(uuid))
        defer { restore() }

        weak var weakVM: AccountDetailViewModel?
        do {
            let viewModel = AccountDetailViewModel(libraryAccountID: uuid, appContainer: appContainer)
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
