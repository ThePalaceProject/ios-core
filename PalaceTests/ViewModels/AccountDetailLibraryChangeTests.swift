//
//  AccountDetailLibraryChangeTests.swift
//  PalaceTests
//
//  The Account screen re-reads its sign-in state when the current library
//  changes, so a switch does not leave the previous library's state on screen.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class AccountDetailLibraryChangeTests: PalaceTestCase {

    /// Counts credential reads; each `accountDidChange()` pass makes one.
    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func record() { lock.withLock { reads += 1 } }
        var count: Int { lock.withLock { reads } }
    }

    /// A change on the screen's own accounts manager triggers exactly one
    /// sign-in state re-read.
    func testCurrentLibraryChange_RereadsSignInStateOnce() async {
        let appContainer = makeTestAppContainer()
        let counter = ReadCounter()
        let signedOut = TPPUserAccount.CredentialSnapshot(
            hasCredentials: false, hasAuthToken: false, authState: .loggedOut,
            barcode: nil, pin: nil, authToken: nil, authDefinition: nil, cookies: nil
        )
        let viewModel = AccountDetailViewModel(
            libraryAccountID: "pp5471-library-change",
            accountsManager: appContainer.accountsManager,
            bookRegistry: appContainer.bookRegistry,
            downloadCenter: appContainer.downloadCenter,
            settings: appContainer.settings,
            userAccountPublisher: appContainer.userAccountPublisher,
            drmAuthorizerProvider: { nil },
            credentialSnapshotProvider: { _ in counter.record(); return signedOut }
        )
        await settle(until: { !viewModel.isLoadingAuth })
        let readsBefore = counter.count

        appContainer.accountsManager.requestCurrentLibraryRefresh()
        await settle(until: { counter.count > readsBefore })

        XCTAssertEqual(counter.count, readsBefore + 1)
    }

    /// Drains the main queue until `condition` holds, at most 50 rounds, then
    /// three more so a late duplicate read would show up in the count.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<50 where !condition() {
            await drainMainQueueAsync()
        }
        for _ in 0..<3 { await drainMainQueueAsync() }
    }
}
