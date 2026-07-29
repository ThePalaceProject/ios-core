//
//  AccountsManagerCurrentAccountSwitchContractTests.swift
//  PalaceTests
//
//  PRE-WAVE CHARACTERIZATION PACK — god-class decomposition (Wave 3a,
//  `Palace/Accounts/Library/AccountsManager.swift`).
//  See docs/architecture/god-class-decomposition-plan.md §3a-2 (cluster
//  "Account retrieval … current account", 824–1016 — the `currentAccount`
//  setter) and §5 row "AccountsManager" ("currentAccount-switch publication
//  order").
//
//  WHAT THIS PINS
//  ==============
//  The PUBLICATION-ORDER contract of the `AccountsManager.currentAccount` setter:
//  at the instant `.TPPCurrentAccountDidChange` is published, the setter's state
//  mutations are ALREADY complete —
//    1. `currentAccountId` has been advanced to the NEW account's uuid, and
//    2. the PRIOR account has been terminally evicted
//       (`.detailsEvicted(.libraryDeselected)`), and
//    3. `isAccountSwitching` reflects the branch it took.
//  This is the `CurrentAccountStore` / `UserAccountPublisher` extraction boundary
//  (§3a-2): the facade must preserve the SAME happens-before ordering, or a
//  `.TPPCurrentAccountDidChange` observer that re-reads `currentAccount` /
//  `currentAccountId` (there are ~dozens of these across Book/Settings/MyBooks)
//  would observe torn, mid-switch state.
//
//  The individual EFFECTS (prior eviction, new-account drive) are already covered
//  by `AccountsManagerStateMachineWiringTests`. What is NOT pinned anywhere is the
//  ORDER: that publication happens AFTER those mutations. A `.TPPCurrentAccountDidChange`
//  observer records, at delivery time, the synchronously-observable state — so a
//  reorder (publishing before the id update or before the eviction) drifts the
//  recorded contract.
//
//  WHY CallLog-sequence instead of file-based `ContractSnapshot.assert`: see the
//  companion `AccountsManagerAuthDocContractTests` header — the on-disk snapshot
//  first-run RECORDS + fails, which cannot be verified without a local DRM build
//  and would redden the board on introduction. The `[CallRecord]` equality here
//  gives the identical ordered-record guarantee, deterministically and green on
//  first CI run.
//
//  DETERMINISM: no sleeps, no network. The setter posts `.TPPCurrentAccountDidChange`
//  SYNCHRONOUSLY at the end of its body; a `queue: nil` observer is delivered
//  synchronously on the posting (main) thread, so a single `log.snapshot()` taken
//  immediately after the synchronous assignment is complete and race-free. The new
//  account is deliberately NOT registered in `accountSets`, so the setter's
//  `driveCurrentAccountAuthDocIfNeeded()` resolves nil and fires no network fetch
//  (same technique as the wiring suite's reselect test). Per-test isolated
//  `UserDefaults` keeps the `currentAccountIdentifierKey` writes off `.standard`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import UIKit
import PalaceCatalog
import PalaceBookModel
@testable import Palace

@MainActor
final class AccountsManagerCurrentAccountSwitchContractTests: PalaceWiringTestCase {

    // MARK: - Contract 1: real switch A → B

    /// Contract: on a real library switch (prior ≠ new, prior ≠ nil), by the time
    /// `.TPPCurrentAccountDidChange` publishes, `currentAccountId == B`, the prior
    /// account A is `.detailsEvicted(.libraryDeselected)`, and `isAccountSwitching`
    /// is `true` (its reset is deferred to the async cleanup, NOT the setter).
    ///
    /// Kill cases:
    ///  - Publishing `.TPPCurrentAccountDidChange` BEFORE `currentAccountId = new`
    ///    → observer reads currentAccountId == A → record mismatch.
    ///  - Moving the prior-account eviction AFTER the publish → observer reads A as
    ///    `.notLoaded` → mismatch.
    ///  - Resetting `isAccountSwitching` synchronously in the setter (the F-032
    ///    regression) → observer reads `false` → mismatch.
    func testSwitch_AtoB_publishesAfterIdUpdate_andPriorEviction() {
        let aUUID = "urn:uuid:decomp-switch-A-\(UUID().uuidString)"
        let bUUID = "urn:uuid:decomp-switch-B-\(UUID().uuidString)"
        let accountB = Self.makeAccount(uuid: bUUID)

        let defaults = Self.testUserDefaults()
        defaults.set(aUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)

        // Precondition: prior account starts clean.
        guard case .notLoaded = AccountStateStore.shared.state(for: aUUID) else {
            return XCTFail("Setup: fresh prior account must start at .notLoaded")
        }

        let log = CallLog()
        let token = Self.observePublication(log: log, manager: manager, priorUUID: aUUID)
        defer { NotificationCenter.default.removeObserver(token) }

        // Act — synchronous; the observer fires inside this assignment.
        // VERIFY: on the A→B path the setter's `cleanupActiveContentBeforeAccountSwitch`
        // touches the lazy `networkExecutor` (→ `AppContainer.production()`); this
        // test assumes that build emits NO second `.TPPCurrentAccountDidChange` (so
        // the log holds exactly one record). The wiring suite's reselect test drives
        // the identical path today, so this holds — re-confirm if AppContainer
        // construction ever starts posting account-change notifications.
        manager.currentAccount = accountB

        let expected = [
            CallRecord(method: "currentAccountDidChangePublished", args: [
                "currentAccountId": bUUID,
                "priorAccountState": "detailsEvicted.libraryDeselected",
                "isAccountSwitching": "true",
            ])
        ]
        XCTAssertEqual(log.snapshot(), expected,
                       "On A→B, publication must follow both the id update (currentAccountId==B) and prior eviction, with isAccountSwitching still true")

        AccountStateStore.shared.reset(for: aUUID)
        AccountStateStore.shared.reset(for: bUUID)
    }

    // MARK: - Contract 2: redundant reassignment B → B

    /// Contract: reassigning the SAME account (prior == new) still publishes
    /// `.TPPCurrentAccountDidChange`, but does NOT evict the (unchanged) account
    /// and does NOT enter the switching state. Pins the `prev != newAccountId`
    /// eviction guard and the `shouldFinishSwitchingImmediately` fast-finish.
    ///
    /// Kill case: removing the `prev != newAccountId` guard on the eviction write
    /// → B would be evicted → `priorAccountState` reads `.detailsEvicted` → mismatch.
    func testReassign_BtoB_publishesWithoutEvictingOrSwitching() {
        let bUUID = "urn:uuid:decomp-switch-BB-\(UUID().uuidString)"
        let accountB = Self.makeAccount(uuid: bUUID)
        // Pre-advance B to a non-terminal, associated-value-free state so a
        // spurious eviction is unambiguously observable as a state change.
        accountB._setState(.basicInfoLoaded)

        let defaults = Self.testUserDefaults()
        defaults.set(bUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)

        let log = CallLog()
        let token = Self.observePublication(log: log, manager: manager, priorUUID: bUUID)
        defer { NotificationCenter.default.removeObserver(token) }

        manager.currentAccount = accountB

        let expected = [
            CallRecord(method: "currentAccountDidChangePublished", args: [
                "currentAccountId": bUUID,
                "priorAccountState": "basicInfoLoaded",
                "isAccountSwitching": "false",
            ])
        ]
        XCTAssertEqual(log.snapshot(), expected,
                       "B→B must publish but must NOT evict B nor enter the switching state")

        AccountStateStore.shared.reset(for: bUUID)
    }

    // MARK: - Contract 3: first selection nil → B

    /// Contract: the first-ever selection (prior == nil) publishes with the new id
    /// and does NOT enter the switching state (no prior content to clean up). Pins
    /// the `previousAccountId != nil` guard on the switch-detection block.
    ///
    /// Kill case: dropping the `previousAccountId != nil` guard → the switch block
    /// runs on first selection, setting `isAccountSwitching = true` → mismatch.
    func testFirstSelection_nilToB_publishesWithNewId_notSwitching() {
        let bUUID = "urn:uuid:decomp-switch-nilB-\(UUID().uuidString)"
        let accountB = Self.makeAccount(uuid: bUUID)

        // Fresh isolated defaults → currentAccountId starts nil.
        let defaults = Self.testUserDefaults()
        let manager = makeFreshAccountsManager(defaults: defaults)
        XCTAssertNil(manager.currentAccountId, "Setup: first selection requires a nil starting currentAccountId")

        let log = CallLog()
        // No prior uuid → record only currentAccountId + switching flag.
        let token = Self.observePublication(log: log, manager: manager, priorUUID: nil)
        defer { NotificationCenter.default.removeObserver(token) }

        manager.currentAccount = accountB

        let expected = [
            CallRecord(method: "currentAccountDidChangePublished", args: [
                "currentAccountId": bUUID,
                "isAccountSwitching": "false",
            ])
        ]
        XCTAssertEqual(log.snapshot(), expected,
                       "nil→B must publish with currentAccountId==B and must NOT enter the switching state")

        AccountStateStore.shared.reset(for: bUUID)
    }

    // MARK: - Contract 4: spy-order cleanup sequence (Wave 3 S3)

    /// Contract: on a real switch A → B, the setter drives its cleanup
    /// collaborators in a FIXED order —
    ///   cancelNonEssentialTasks → clearAllBorrowReauthState → evictDecodedImages
    ///   → resetCoverCircuitBreaker → (account-state eviction of A) → popToRoot
    ///   → isAccountSwitching reset.
    /// Every seam is now an injected double recording into one `CallLog`, so the
    /// ORDER is pinned directly against spies instead of inferred through a
    /// `NotificationCenter` round-trip. The account-state eviction is a store
    /// mutation (the injected `AccountStateStore` instance is not a `CallLog` spy),
    /// so it is pinned by its effect + its synchronous position between the cover
    /// reset and the async nav pop; `isAccountSwitching`'s deferred reset is pinned
    /// by the true-before / false-after state assertions.
    ///
    /// Kill cases (each flips this test red):
    ///  - Reordering any two of the four synchronous seam calls.
    ///  - Moving `evictDecodedImages` / `resetCoverCircuitBreaker` before the
    ///    `cleanupActiveContentBeforeAccountSwitch` call (they'd precede
    ///    cancel/borrow-clear in the log).
    ///  - Dropping the prior-account eviction → A stays `.notLoaded`.
    ///  - Resetting `isAccountSwitching` synchronously in the setter (F-032) →
    ///    the true-before assertion fails.
    ///  - Firing the nav pop synchronously → it appears in the pre-yield log.
    func testSwitch_AtoB_drivesCleanupSeamsInOrder() async {
        let aUUID = "urn:uuid:decomp-s3-A-\(UUID().uuidString)"
        let bUUID = "urn:uuid:decomp-s3-B-\(UUID().uuidString)"
        let accountB = Self.makeAccount(uuid: bUUID)

        let log = CallLog()
        let stateStore = AccountStateStore() // fresh, isolated — not `.shared`
        let spyExecutor = SpyAccountSwitchNetworkExecutor(log: log)
        let spyImageCache = SpySwitchImageCache(log: log)
        let spyBorrow = SpySwitchBorrowReauthResetter(log: log)

        let deps = AccountSwitchDependencies(
            imageCache: spyImageCache,
            accountStateStore: stateStore,
            resetCoverCircuitBreaker: { log.record("resetCoverCircuitBreaker") },
            networkExecutorProvider: { spyExecutor },
            popToRootForAccountSwitch: { log.record("popToRoot") }
        )

        let defaults = Self.testUserDefaults()
        defaults.set(aUUID, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(
            defaults: defaults,
            borrowReauthResetter: spyBorrow,
            switchDependencies: deps
        )

        guard case .notLoaded = stateStore.state(for: aUUID) else {
            return XCTFail("Setup: fresh prior account must start at .notLoaded in the injected store")
        }

        // Act — synchronous portion runs inline on the main actor.
        manager.currentAccount = accountB

        // Synchronous cleanup order: cancel + borrow-clear (inside
        // cleanupActiveContentBeforeAccountSwitch) then image evict + cover reset.
        XCTAssertEqual(log.snapshot().map(\.method),
                       ["cancelNonEssentialTasks", "clearAllBorrowReauthState",
                        "evictDecodedImages", "resetCoverCircuitBreaker"],
                       "synchronous cleanup seams must fire in this exact order")
        // Prior account A terminally evicted in the injected store (synchronous).
        XCTAssertEqual(switchStateLabel(stateStore.state(for: aUUID)),
                       "detailsEvicted.libraryDeselected",
                       "prior account A must be evicted before control returns")
        // Nav pop is deferred to the async cleanup Task — not yet fired.
        XCTAssertFalse(log.snapshot().contains { $0.method == "popToRoot" },
                       "nav pop-to-root must be deferred to the async cleanup, not synchronous")
        // isAccountSwitching reset is deferred (F-032).
        XCTAssertTrue(manager.isAccountSwitching,
                      "isAccountSwitching must still be true synchronously (reset is deferred)")

        // Let the @MainActor cleanup Task run (nav pop then flag reset).
        for _ in 0..<1000 {
            if log.snapshot().contains(where: { $0.method == "popToRoot" }),
               !manager.isAccountSwitching { break }
            await Task.yield()
        }

        XCTAssertEqual(log.snapshot().map(\.method),
                       ["cancelNonEssentialTasks", "clearAllBorrowReauthState",
                        "evictDecodedImages", "resetCoverCircuitBreaker", "popToRoot"],
                       "full cleanup order: nav pop must follow every synchronous seam")
        XCTAssertFalse(manager.isAccountSwitching,
                       "isAccountSwitching must be reset only AFTER the async nav cleanup completes")
    }

    /// Contract: first selection nil → B takes NO cleanup path — none of the
    /// switch seams fire (no prior content to clean up). Pins the
    /// `previousAccountId != nil` guard against the injected spies.
    ///
    /// Kill case: dropping the `previousAccountId != nil` guard → cancel / evict /
    /// cover reset / nav pop would fire on first selection → non-empty log.
    func testFirstSelection_nilToB_drivesNoCleanupSeams() async {
        let bUUID = "urn:uuid:decomp-s3-nilB-\(UUID().uuidString)"
        let accountB = Self.makeAccount(uuid: bUUID)

        let log = CallLog()
        let stateStore = AccountStateStore()
        let spyExecutor = SpyAccountSwitchNetworkExecutor(log: log)
        let spyImageCache = SpySwitchImageCache(log: log)
        let spyBorrow = SpySwitchBorrowReauthResetter(log: log)

        let deps = AccountSwitchDependencies(
            imageCache: spyImageCache,
            accountStateStore: stateStore,
            resetCoverCircuitBreaker: { log.record("resetCoverCircuitBreaker") },
            networkExecutorProvider: { spyExecutor },
            popToRootForAccountSwitch: { log.record("popToRoot") }
        )

        let defaults = Self.testUserDefaults() // currentAccountId starts nil
        let manager = makeFreshAccountsManager(
            defaults: defaults,
            borrowReauthResetter: spyBorrow,
            switchDependencies: deps
        )
        XCTAssertNil(manager.currentAccountId, "Setup: first selection requires a nil starting id")

        manager.currentAccount = accountB

        // Give any (erroneously scheduled) async cleanup a chance to run.
        for _ in 0..<50 { await Task.yield() }

        XCTAssertTrue(log.snapshot().isEmpty,
                      "nil→B must drive NO cleanup seams (no prior content)")
        XCTAssertFalse(manager.isAccountSwitching,
                       "first selection must not enter the switching state")
    }

    // MARK: - Helpers

    /// Register a synchronous (`queue: nil`) `.TPPCurrentAccountDidChange`
    /// observer that records the observable state AT PUBLICATION TIME into `log`.
    ///
    /// SEAM: the setter hard-codes `NotificationCenter.default` for publication and
    /// `AccountStateStore.shared` for the prior-account eviction. The extraction's
    /// `CurrentAccountStore` / `UserAccountPublisher` should expose a typed Combine
    /// publisher and take an injected state store so this ordering can be observed
    /// without a process-wide `NotificationCenter` round-trip.
    ///
    /// The closure is `@Sendable`; it captures only Sendable values
    /// (`AccountsManager` is `@unchecked Sendable`, `CallLog` is `@unchecked
    /// Sendable`, uuids are `String`) — never `self`.
    private static func observePublication(
        log: CallLog,
        manager: AccountsManager,
        priorUUID: String?
    ) -> NSObjectProtocol {
        return NotificationCenter.default.addObserver(
            forName: .TPPCurrentAccountDidChange,
            object: nil,
            queue: nil
        ) { _ in
            var args: [String: Any] = [
                "currentAccountId": manager.currentAccountId ?? "nil",
                "isAccountSwitching": manager.isAccountSwitching ? "true" : "false",
            ]
            if let priorUUID {
                args["priorAccountState"] = switchStateLabel(AccountStateStore.shared.state(for: priorUUID))
            }
            log.record("currentAccountDidChangePublished", args: args)
        }
    }

    /// Minimal account from a link-less publication; its `metadata.id` becomes the
    /// account UUID. No `authentication_document` link, so any drive is network-free.
    private static func makeAccount(uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "currentAccount-switch contract",
            id: uuid,
            title: "Switch Contract \(uuid.suffix(6))"
        )
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        return Account(publication: publication, imageCache: MockImageCache())
    }
}

// MARK: - Spies for the Wave 3 S3 switch-cleanup contract

/// Records `cancelNonEssentialTasks()` into a shared `CallLog`. Subclasses the real
/// `TPPNetworkExecutor` (the only way to observe the concrete cancel seam); every
/// other executor behavior is inherited but never exercised on the switch path.
fileprivate final class SpyAccountSwitchNetworkExecutor: TPPNetworkExecutor, @unchecked Sendable {
    let log: CallLog
    init(log: CallLog) {
        self.log = log
        super.init(cachingStrategy: .ephemeral)
    }
    override func cancelNonEssentialTasks() {
        log.record("cancelNonEssentialTasks")
    }
}

/// Records `evictDecodedImages()`; all other `ImageCacheType` surface is inert (the
/// switch setter only evicts). `@unchecked Sendable`: it holds only the thread-safe
/// `CallLog`.
fileprivate final class SpySwitchImageCache: ImageCacheType, @unchecked Sendable {
    let log: CallLog
    init(log: CallLog) { self.log = log }
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {}
    func get(for key: String) -> UIImage? { nil }
    func getAsync(for key: String) async -> UIImage? { nil }
    func remove(for key: String) {}
    func clear() {}
    func warmMemoryCache(for keys: [String]) async {}
    func evictDecodedImages() { log.record("evictDecodedImages") }
}

/// Records the account-switch borrow-reauth circuit-breaker clear (Wave 3 S1 seam).
fileprivate final class SpySwitchBorrowReauthResetter: BorrowReauthResetting, @unchecked Sendable {
    let log: CallLog
    init(log: CallLog) { self.log = log }
    func clearAllBorrowReauthState() { log.record("clearAllBorrowReauthState") }
}

/// Stable, associated-value-free `LoadState` label. Free function (nonisolated) so
/// the `@Sendable` notification observer can call it without capturing test state.
fileprivate func switchStateLabel(_ state: Account.LoadState) -> String {
    switch state {
    case .notLoaded:       return "notLoaded"
    case .basicInfoLoaded: return "basicInfoLoaded"
    case .detailsLoading:  return "detailsLoading"
    case .detailsLoaded:   return "detailsLoaded"
    case .detailsFailed:   return "detailsFailed"
    case .detailsEvicted(let reason):
        if case .libraryDeselected = reason { return "detailsEvicted.libraryDeselected" }
        return "detailsEvicted.other"
    }
}
