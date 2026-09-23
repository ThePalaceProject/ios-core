//
//  AccountsManagerAuthDocContractTests.swift
//  PalaceTests
//
//  PRE-WAVE CHARACTERIZATION PACK — god-class decomposition (Wave 3a,
//  `Palace/Accounts/Library/AccountsManager.swift`).
//  See docs/architecture/god-class-decomposition-plan.md §3a-2 (cluster
//  "Auth-document fetch with state-machine wiring", 1605–1786) and §5 row
//  "AccountsManager" ("auth-doc fetch → AccountStateStore transition contract").
//
//  WHAT THIS PINS
//  ==============
//  The ORDERED sequence of `Account.LoadState` transitions that
//  `AccountsManager.fetchAuthDocumentWithStateMachine(for:completion:)` writes
//  into `AccountStateStore.shared` for a fetch that FAILS. This is the
//  `AuthDocumentLoader` extraction boundary: after the class is split, the new
//  loader must drive the SAME ordered transitions (`.detailsLoading` before the
//  fetch, `.detailsFailed(.authDocumentFetchFailed)` on failure) or a consumer's
//  `awaitReady()` gate silently regresses. Existing
//  `AccountsManagerStateMachineWiringTests` asserts the presence of those two
//  transitions via loose stream membership; THIS test locks the exact ORDERED
//  call sequence as a contract (the CallLog primitive from PalaceTests/Contract),
//  so a reorder / dropped-transition drift fails loudly.
//
//  WHY CallLog-sequence instead of the file-based `ContractSnapshot.assert`:
//  the file snapshot's first run RECORDS a baseline and deliberately FAILS
//  ("re-run to verify"). This pack is authored WITHOUT a local DRM build (CI is
//  the gate per CLAUDE.md), so a byte-exact Foundation-pretty-printed baseline
//  cannot be generated + verified here, and shipping a guaranteed-red first run
//  violates the green-board contract. The CallLog `[CallRecord]` equality below
//  gives the identical ordered-call-sequence guarantee, is deterministic, and is
//  green on first CI run. A maintainer who wants the on-disk snapshot form can
//  swap the final `XCTAssertEqual` for `ContractSnapshot.assert(log, named:)` and
//  record once with `CONTRACT_SNAPSHOT_RECORD=1`.
//
//  DETERMINISM: no sleeps. A fresh, unique-UUID account starts at `.notLoaded`;
//  a publication with no `authentication_document` link makes
//  `Account.loadAuthenticationDocument` fire `completion(false)` SYNCHRONOUSLY,
//  so the two transitions land inline. The stream sink is gated on
//  subscription-attached before the drive so the `CurrentValueSubject`-backed
//  stream cannot replay-collapse the intermediate `.detailsLoading` (the same
//  gating `AccountsManagerStateMachineWiringTests` Test 3 uses).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountsManagerAuthDocContractTests: PalaceWiringTestCase {

    // MARK: - Contract: failure-path transition order

    /// Contract (AuthDocumentLoader boundary): a failing auth-doc fetch drives
    /// exactly `.notLoaded → .detailsLoading → .detailsFailed(.authDocumentFetchFailed)`.
    ///
    /// Kill cases this pins:
    ///  - Removing the entry `account._setState(.detailsLoading)` drops the middle
    ///    record → sequence mismatch.
    ///  - Inverting the success/failure branch (writing `.detailsLoaded` on
    ///    `success == false`) → wrong terminal label.
    ///  - Reordering the terminal ahead of `.detailsLoading` → order mismatch.
    ///
    /// SEAM: `fetchAuthDocumentWithStateMachine` hard-codes `AccountStateStore.shared`
    /// as its transition sink and calls `account.loadAuthenticationDocument` for the
    /// real network fetch. The extraction's `AuthDocumentLoader` must take an
    /// injected `AccountStateStoring` (transition sink) AND an injected auth-doc
    /// fetcher so this contract can observe a spy store + drive the SUCCESS path
    /// deterministically. Until then only the (synchronous, network-free) failure
    /// order is pinnable here; the success order is deferred to the loader's own
    /// contract test post-extraction.
    func testAuthDocFetchFailure_pinsOrderedTransitionSequence() {
        // A publication with NO authentication_document link → nil
        // `authenticationDocumentUrl` → `loadAuthenticationDocument` short-circuits
        // with `completion(false)` synchronously. Unique id → the shared store
        // starts this UUID at `.notLoaded` regardless of suite order.
        let uuid = "urn:uuid:decomp-authdoc-\(UUID().uuidString)"
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "auth-doc contract (no auth-doc link)",
            id: uuid,
            title: "AuthDoc Contract Library"
        )
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        let account = Account(publication: publication, imageCache: MockImageCache())

        XCTAssertNil(account.authenticationDocumentUrl,
                     "Setup: account must have a nil authenticationDocumentUrl so the fetch fails synchronously")
        guard case .notLoaded = AccountStateStore.shared.state(for: uuid) else {
            return XCTFail("Setup: a fresh unique account must start at .notLoaded")
        }

        let manager = makeFreshAccountsManager()
        let log = CallLog()

        // Record every observed transition, in order, into the contract log.
        // Gate the drive on the sink being attached (first replayed value) so
        // the synchronous `.detailsLoading`/`.detailsFailed` sends cannot land
        // before the subscriber exists.
        let subscribed = expectation(description: "state stream subscription attached")
        subscribed.assertForOverFulfill = false
        let streamTask = Task { @MainActor in
            var firstSeen = false
            for await state in account.stateStream {
                log.record("authDocStateTransition", args: ["state": Self.stateLabel(state)])
                if !firstSeen { firstSeen = true; subscribed.fulfill() }
                if case .detailsFailed = state { break }
            }
        }
        wait(for: [subscribed], timeout: 2.0)

        let completed = expectation(description: "fetch completion")
        manager.fetchAuthDocumentWithStateMachine(for: account) { success in
            XCTAssertFalse(success, "nil-URL auth-doc fetch must complete(false)")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2.0)

        // Wait until the terminal transition has been recorded (no sleep).
        awaitCondition(timeout: 2.0) { log.snapshot().count >= 3 }
        streamTask.cancel()

        let expected = [
            CallRecord(method: "authDocStateTransition", args: ["state": "notLoaded"]),
            CallRecord(method: "authDocStateTransition", args: ["state": "detailsLoading"]),
            CallRecord(method: "authDocStateTransition", args: ["state": "detailsFailed.authDocumentFetchFailed"]),
        ]
        XCTAssertEqual(log.snapshot(), expected,
                       "Auth-doc failure must drive exactly notLoaded → detailsLoading → detailsFailed(.authDocumentFetchFailed), in order")

        // Housekeeping: unique UUID, but drop its subject so nothing bleeds.
        AccountStateStore.shared.reset(for: uuid)
    }

    // NOTE: The per-UUID single-flight dedup (two concurrent same-UUID fetches →
    // one `.detailsLoading`) is deliberately NOT re-pinned here. It is already
    // covered by `AccountsManagerStateMachineWiringTests`
    // `testSingleFlight_twoConcurrentAwaiters_oneNetworkRequest`, and pinning it
    // requires two-thread interleaving whose determinism hinges on the timing of
    // the (network-free) completion — a racy shape this deterministic pack avoids.

    // MARK: - Helpers

    /// Stable, associated-value-free label for a `LoadState`. Free (nonisolated)
    /// so the `@Sendable`/`@MainActor` stream tasks can call it without capturing
    /// `self`.
    fileprivate static func stateLabel(_ state: Account.LoadState) -> String {
        switch state {
        case .notLoaded:       return "notLoaded"
        case .basicInfoLoaded: return "basicInfoLoaded"
        case .detailsLoading:  return "detailsLoading"
        case .detailsLoaded:   return "detailsLoaded"
        case .detailsFailed(let err):
            if case .authDocumentFetchFailed = err { return "detailsFailed.authDocumentFetchFailed" }
            if case .accountNotFound = err { return "detailsFailed.accountNotFound" }
            if case .malformedAuthDocument = err { return "detailsFailed.malformedAuthDocument" }
            if case .evicted = err { return "detailsFailed.evicted" }
            return "detailsFailed.other"
        case .detailsEvicted(let reason):
            if case .libraryDeselected = reason { return "detailsEvicted.libraryDeselected" }
            return "detailsEvicted.other"
        }
    }
}
