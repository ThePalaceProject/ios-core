//  AuthDocumentLoaderSeamTests.swift
//
//  Pins `AuthDocumentLoader` built directly with spies and an isolated
//  `AccountStateStore`. `Account._setState` writes to the shared store, so
//  terminals are not observable here; the observable is whether a fetch fired,
//  seen as a synchronous `signedInStateProvider` call on the non-dedup path.
//  Terminals stay pinned by `AccountsManagerAuthDocContractTests`. Fired fetches
//  use link-less accounts (no network), unique uuids, and tearDown resets state.

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace

@MainActor
final class AuthDocumentLoaderSeamTests: XCTestCase {

    private var touchedUUIDs: [String] = []

    override func tearDown() {
        // A fired fetch writes a terminal to AccountStateStore.shared (Account._setState
        // hard-codes .shared); reset so nothing bleeds into a later test.
        for uuid in touchedUUIDs { AccountStateStore.shared.reset(for: uuid) }
        touchedUUIDs.removeAll()
        super.tearDown()
    }

    // MARK: - Pure guard

    /// `fetchCompletionMayWriteTerminal` returns false ONLY for an evicted state (so a
    /// switch-cancellation completion can't clobber the eviction marker), true otherwise.
    /// Regression caught: dropping the `.detailsEvicted` short-circuit ⇒ the evicted assertion flips.
    func testFetchCompletionMayWriteTerminal_purity() {
        XCTAssertFalse(
            AuthDocumentLoader.fetchCompletionMayWriteTerminal(currentState: .detailsEvicted(.libraryDeselected(uuid: "x"))),
            "an evicted account's in-flight completion must NOT write a terminal")
        XCTAssertTrue(AuthDocumentLoader.fetchCompletionMayWriteTerminal(currentState: .notLoaded))
        XCTAssertTrue(AuthDocumentLoader.fetchCompletionMayWriteTerminal(currentState: .basicInfoLoaded))
        XCTAssertTrue(AuthDocumentLoader.fetchCompletionMayWriteTerminal(currentState: .detailsLoading))
        XCTAssertTrue(AuthDocumentLoader.fetchCompletionMayWriteTerminal(currentState: .detailsFailed(.accountNotFound(uuid: "x"))))
    }

    // MARK: - Single-flight dedup / wedge reclaim (via the inflight map + fetch-fired spy)

    /// A recent in-flight entry DEDUPES the next fetch: completion fires `true`
    /// synchronously and NO network is fired (`signedInStateProvider` untouched).
    ///
    /// Regression caught: dropping the dedup guard ⇒ the fetch fires the network (spy called).
    func testFetch_dedupesAgainstRecentInflight() {
        let (loader, account, spy) = makeLoader()
        loader._seedInflightAuthDocForTesting(uuid: account.uuid, age: 1) // recent

        var completedWith: Bool?
        loader.fetchAuthDocumentWithStateMachine(for: account) { completedWith = $0 }

        XCTAssertEqual(completedWith, true, "a deduped caller's completion balances with true")
        XCTAssertFalse(spy.called, "dedup must NOT fire the network fetch")
        XCTAssertTrue(loader._inflightAuthDocContainsForTesting(uuid: account.uuid), "the recent slot is untouched")
    }

    /// A STALE in-flight entry (older than the timeout) is reclaimed and the fetch
    /// re-fires: `signedInStateProvider` IS called and the slot stays claimed.
    ///
    /// Regression caught: treating a stale wedge as a live dedup ⇒ the fetch never re-fires
    /// (spy untouched) and `awaitReady()` stays wedged (HelpSpot #18414).
    func testFetch_reclaimsStaleWedge() {
        let (loader, account, spy) = makeLoader()
        loader._seedInflightAuthDocForTesting(uuid: account.uuid, age: AuthDocumentLoader.authDocInflightTimeout + 5)

        loader.fetchAuthDocumentWithStateMachine(for: account) { _ in }

        XCTAssertTrue(spy.called, "a stale wedge must be reclaimed and the fetch re-fired")
        // The re-fired fetch reclaims the slot, then its network completion clears it.
        // For a link-less account `loadAuthenticationDocument` calls back SYNCHRONOUSLY
        // (no URL → completion(false)), and the loader's completion synchronously removes
        // the slot before this line — so it is already gone (mirrors the wiring-suite
        // wedge precedent `testWedgedInflightAuthDoc…`, which asserts the same clear).
        XCTAssertFalse(loader._inflightAuthDocContainsForTesting(uuid: account.uuid), "the re-fired fetch's synchronous completion clears the reclaimed slot")
    }

    // MARK: - Drive routing (via the injected store + fetch-fired spy)

    /// `drive` at a genuine terminal failure does NOT re-fetch (the "real failure, don't
    /// redrive" arm). Regression caught: routing `.detailsFailed` to a redrive ⇒ spy called.
    func testDrive_atTerminalFailure_doesNotRefetch() {
        let (loader, account, spy, store) = makeLoaderWithStore()
        store.setState(.detailsFailed(.accountNotFound(uuid: account.uuid)), for: account.uuid)

        loader.driveCurrentAccountAuthDocIfNeeded()

        XCTAssertFalse(spy.called, "a genuine .detailsFailed terminal must NOT redrive")
    }

    /// `drive` on a STALE `.detailsEvicted(.libraryDeselected)` marker REDRIVES (swap-back).
    /// Regression caught: routing `.detailsEvicted` to `return` ⇒ awaitReady() stuck after swap-back.
    func testDrive_atStaleEvictionMarker_redrives() {
        let (loader, account, spy, store) = makeLoaderWithStore()
        store.setState(.detailsEvicted(.libraryDeselected(uuid: account.uuid)), for: account.uuid)

        loader.driveCurrentAccountAuthDocIfNeeded()

        XCTAssertTrue(spy.called, "a stale .detailsEvicted marker for the current account must redrive")
    }

    /// `drive` at a non-terminal state fetches. Regression caught: a change that early-returns
    /// on `.notLoaded` ⇒ awaitReady() consumers never get a terminal.
    func testDrive_atNonTerminal_fetches() {
        let (loader, _, spy, _) = makeLoaderWithStore() // fresh store ⇒ .notLoaded

        loader.driveCurrentAccountAuthDocIfNeeded()

        XCTAssertTrue(spy.called, "a non-terminal (.notLoaded) current account must be driven")
    }

    // MARK: - Helpers

    /// Loader with an isolated store, a spy `signedInStateProvider`, and a fixed current
    /// account. `signedInStateProvider` returns nil (the param is optional; the no-URL
    /// account fails fast) and records that the fetch reached the network call site.
    private func makeLoaderWithStore() -> (AuthDocumentLoader, Account, ProviderSpy, AccountStateStore) {
        let account = Self.makeAccount("authdoc-\(UUID().uuidString)")
        touchedUUIDs.append(account.uuid)
        let store = AccountStateStore()
        let spy = ProviderSpy()
        let loader = AuthDocumentLoader(
            accountStateStore: store,
            currentAccountProvider: { account },
            signedInStateProvider: { spy.called = true; return nil },
            isTornDown: { false }
        )
        return (loader, account, spy, store)
    }

    private func makeLoader() -> (AuthDocumentLoader, Account, ProviderSpy) {
        let (loader, account, spy, _) = makeLoaderWithStore()
        return (loader, account, spy)
    }

    /// Link-less account whose `metadata.id` is the uuid; no auth-doc URL ⇒ any fired
    /// `loadAuthenticationDocument` fails fast without network.
    private static func makeAccount(_ uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "auth-doc-loader seam",
            id: uuid,
            title: "AuthDoc \(uuid.suffix(6))"
        )
        return Account(publication: OPDS2Publication(links: [], metadata: metadata, images: nil),
                       imageCache: MockImageCache())
    }
}

/// Records whether the loader reached the `loadAuthenticationDocument(using:)` call site
/// (i.e. actually fired the fetch, vs deduped/returned early). `@unchecked Sendable`: the
/// loader evaluates the provider synchronously on the test thread.
fileprivate final class ProviderSpy: @unchecked Sendable {
    var called = false
}
