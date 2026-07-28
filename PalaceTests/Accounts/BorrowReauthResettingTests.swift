//
//  BorrowReauthResettingTests.swift
//  PalaceTests
//
//  god-class decomposition Wave 3, seam S1 — the ONE hard, un-inverted
//  Accounts→Downloads STATIC edge, now injected via `BorrowReauthResetting`.
//
//  WHAT THIS PINS
//  ==============
//  `AccountsManager.cleanupActiveContentBeforeAccountSwitch(from:to:)` clears the
//  process-global per-book borrow-reauth circuit breaker on every real library
//  switch. Wave 3 S1 replaces the static
//  `MyBooksDownloadCenter.clearAllBorrowReauthState()` call with an injected
//  `borrowReauthResetter.clearAllBorrowReauthState()`. This suite pins:
//
//   1. On a real A→B switch the injected resetter is invoked EXACTLY ONCE, and
//      the invocation is ordered BEFORE the async navigation cleanup completes
//      (isAccountSwitching still true, i.e. the clear is synchronous in the
//      setter, not deferred to the async Task) — spy injection.
//   2. A redundant same-account reassignment (B→B) does NOT invoke the resetter
//      (the switch-detection guard) — spy injection.
//   3. A switch to a nil account (leaving a library) DOES invoke the resetter.
//   4. END-TO-END WIRING: an `AccountsManager` using the REAL default resetter
//      (`DownloadCenterBorrowReauthResetter`, the same one `AppContainer` wires)
//      actually resets `BorrowOperation`'s breaker across a switch — a book whose
//      breaker has tripped is offered re-auth AGAIN after the switch. This closes
//      the "forgot to wire a real resetter" gap the default arg would otherwise
//      mask: a no-op default (FORBIDDEN) or a dropped :995 call fails this test.
//
//  The breaker behavior itself (trip on 2nd auth-error, per-book keying, global
//  clear) is pinned separately by the write-ahead
//  `AccountSwitchBorrowReauthCouplingContractTests`. Contract 4 here observes it
//  ONLY as the money-path proof that the injected/default resetter is real.
//
//  DETERMINISM: no sleeps, no network. The new account is NOT registered in
//  `accountSets`, so the setter's `driveCurrentAccountAuthDocIfNeeded()` resolves
//  nil and fires no network fetch. `fetchBook` throws synchronously; the sign-in
//  modal completion is recorded but never invoked (no retry recursion). Per-test
//  isolated `UserDefaults` keeps `currentAccountIdentifierKey` off `.standard`.
//  The process-global breaker is cleared in setUp AND tearDown.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class BorrowReauthResettingTests: PalaceWiringTestCase {

    // MARK: - Spy

    /// Records how many times the account-switch reset seam fires. `@unchecked
    /// Sendable` (the protocol requires `Sendable`); the counter is guarded by a
    /// lock, though every invocation in these tests is synchronous on the main
    /// thread inside the `currentAccount` setter.
    private final class SpyBorrowReauthResetter: BorrowReauthResetting, @unchecked Sendable {
        private let lock = NSLock()
        private var _callCount = 0
        var callCount: Int { lock.withLock { _callCount } }
        func clearAllBorrowReauthState() { lock.withLock { _callCount += 1 } }
    }

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Start from a clean process-global breaker so Contract 4 can't inherit a
        // pre-tripped entry from a prior suite.
        BorrowOperation.clearAllBorrowReauthState()
    }

    override func tearDownWithError() throws {
        // Do not leak a tripped breaker into downstream suites.
        BorrowOperation.clearAllBorrowReauthState()
        // Directly-constructed (spy-path) managers aren't tracked by the base's
        // private list, so cancel their background work here. Idempotent.
        for manager in managersToCancel {
            manager.cancelBackgroundWork()
        }
        managersToCancel.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Contract 1: real switch A→B invokes the resetter exactly once, before async nav cleanup

    /// On a real library switch the injected resetter fires exactly once, and it
    /// fires SYNCHRONOUSLY in the setter — before the async navigation cleanup
    /// Task (which resets `isAccountSwitching`) has completed. We assert both
    /// facts at the instant the synchronous assignment returns.
    ///
    /// Kill cases:
    ///  - Dropping the `borrowReauthResetter.clearAllBorrowReauthState()` call
    ///    (:995) → callCount == 0 → fail.
    ///  - Calling it twice → callCount == 2 → fail.
    ///  - Moving the clear into the async nav-cleanup Task → at return callCount
    ///    would still be 0 (Task not yet run) → fail.
    func testSwitch_AtoB_invokesResetterExactlyOnce_beforeAsyncNavCleanup() {
        let aUUID = "urn:uuid:s1-A-\(UUID().uuidString)"
        let bUUID = "urn:uuid:s1-B-\(UUID().uuidString)"
        let accountB = Self.makeAccount(uuid: bUUID)

        let spy = SpyBorrowReauthResetter()
        let defaults = Self.testUserDefaults()
        defaults.set(aUUID, forKey: currentAccountIdentifierKey)
        let manager = makeManager(defaults: defaults, resetter: spy)

        // Act — synchronous.
        manager.currentAccount = accountB

        XCTAssertEqual(spy.callCount, 1,
                       "A real A→B switch must invoke the borrow-reauth resetter exactly once")
        XCTAssertTrue(manager.isAccountSwitching,
                      "The reset must fire synchronously in the setter, before the async nav cleanup resets isAccountSwitching")

        AccountStateStore.shared.reset(for: aUUID)
        AccountStateStore.shared.reset(for: bUUID)
    }

    // MARK: - Contract 2: redundant reassignment B→B does NOT invoke the resetter

    /// Reassigning the SAME account is not a switch — the cleanup block (and its
    /// breaker clear) must not run, or every redundant reassignment would wipe
    /// in-flight breaker state.
    ///
    /// Kill case: dropping the `previousAccountId != newAccountId` guard on the
    /// switch-detection block → the resetter fires on B→B → callCount == 1 → fail.
    func testReassign_BtoB_doesNotInvokeResetter() {
        let bUUID = "urn:uuid:s1-BB-\(UUID().uuidString)"
        let accountB = Self.makeAccount(uuid: bUUID)

        let spy = SpyBorrowReauthResetter()
        let defaults = Self.testUserDefaults()
        defaults.set(bUUID, forKey: currentAccountIdentifierKey)
        let manager = makeManager(defaults: defaults, resetter: spy)

        manager.currentAccount = accountB

        XCTAssertEqual(spy.callCount, 0,
                       "A redundant B→B reassignment must NOT invoke the borrow-reauth resetter")

        AccountStateStore.shared.reset(for: bUUID)
    }

    // MARK: - Contract 3: switch to nil (leaving a library) invokes the resetter

    /// Deselecting the current library (A→nil) is a real switch away from A and
    /// must clear the breaker so a later reselect starts with a fresh breaker.
    ///
    /// Kill case: narrowing the switch-detection guard to require a non-nil NEW
    /// account → A→nil would skip the clear → callCount == 0 → fail.
    func testSwitch_AtoNil_invokesResetter() {
        let aUUID = "urn:uuid:s1-Anil-\(UUID().uuidString)"

        let spy = SpyBorrowReauthResetter()
        let defaults = Self.testUserDefaults()
        defaults.set(aUUID, forKey: currentAccountIdentifierKey)
        let manager = makeManager(defaults: defaults, resetter: spy)

        manager.currentAccount = nil

        XCTAssertEqual(spy.callCount, 1,
                       "Leaving a library (A→nil) must invoke the borrow-reauth resetter exactly once")

        AccountStateStore.shared.reset(for: aUUID)
    }

    // MARK: - Contract 4: the REAL default resetter actually resets the breaker across a switch

    /// End-to-end money-path proof. Using an `AccountsManager` with the REAL
    /// default `DownloadCenterBorrowReauthResetter` (the exact resetter
    /// `AppContainer` wires), a book whose per-book breaker has TRIPPED
    /// (2nd auth-error borrow suppressed to a generic alert) is offered re-auth
    /// AGAIN after a library switch — proving the default/wired resetter really
    /// reaches `BorrowOperation.reauthTracker.clearAll()`.
    ///
    /// Kill cases:
    ///  - A no-op default resetter (FORBIDDEN) → attempt 3 stays suppressed →
    ///    sequence [modal, alert, alert] ≠ [modal, alert, modal] → fail.
    ///  - Dropping the :995 clear call → same drift → fail.
    func testRealDefaultResetter_acrossSwitch_reenablesReauthForTrippedBook() async {
        let log = CallLog()
        let userAccount = Self.noCredentialsNeedsAuthAccount()
        let book = Self.book(identifier: "s1-reauth-reenable")
        let op = Self.makeBorrowOperation(userAccount: userAccount,
                                          bookIdentifier: book.identifier,
                                          log: log)

        // Trip the breaker for this book: attempt 1 → sign-in modal, attempt 2 →
        // breaker suppresses re-auth → generic alert.
        await Self.borrowExpectingThrow(op, book)
        await Self.borrowExpectingThrow(op, book)

        // Drive a real A→B switch on a manager using the REAL default resetter.
        // Its `cleanupActiveContentBeforeAccountSwitch` invokes
        // DownloadCenterBorrowReauthResetter → MyBooksDownloadCenter →
        // BorrowOperation.clearAllBorrowReauthState() on the same process-global
        // tracker `op` reads.
        let aUUID = "urn:uuid:s1-C4-A-\(UUID().uuidString)"
        let bUUID = "urn:uuid:s1-C4-B-\(UUID().uuidString)"
        let accountB = Self.makeAccount(uuid: bUUID)
        let defaults = Self.testUserDefaults()
        defaults.set(aUUID, forKey: currentAccountIdentifierKey)
        // No `resetter:` arg → the production default DownloadCenterBorrowReauthResetter.
        let manager = makeFreshAccountsManager(defaults: defaults)
        manager.currentAccount = accountB

        // Attempt 3 for the SAME book: breaker was cleared → re-auth offered again.
        await Self.borrowExpectingThrow(op, book)

        let expected = [
            CallRecord(method: "presentSignInModal", args: ["book": book.identifier]),
            CallRecord(method: "presentBorrowErrorAlert", args: ["book": book.identifier]),
            CallRecord(method: "presentSignInModal", args: ["book": book.identifier]),
        ]
        XCTAssertEqual(log.snapshot(), expected,
                       "The real/default resetter must reset BorrowOperation's breaker across an account switch, so the tripped book is offered re-auth again (3rd attempt = modal, not alert)")

        AccountStateStore.shared.reset(for: aUUID)
        AccountStateStore.shared.reset(for: bUUID)
    }

    // MARK: - Manager helper (spy injection)

    /// Construct a fresh `AccountsManager` with an injected resetter and per-test
    /// defaults, pinning the background-loadCatalogs opt-out (like the base's
    /// `makeFreshAccountsManager`) and registering it for teardown cancellation.
    private func makeManager(defaults: UserDefaults, resetter: any BorrowReauthResetting) -> AccountsManager {
        #if DEBUG
        AccountsManager.deferInitialLoadCatalogsForTesting = true
        #endif
        let manager = AccountsManager(defaults: defaults, borrowReauthResetter: resetter)
        managersToCancel.append(manager)
        return manager
    }

    /// Directly-constructed managers (spy path) aren't tracked by the base's
    /// private list; `tearDownWithError` cancels their background work.
    private var managersToCancel: [AccountsManager] = []

    // MARK: - Account / book fixtures

    /// Minimal account from a link-less publication; its `metadata.id` becomes the
    /// account UUID. No `authentication_document` link → any drive is network-free.
    private static func makeAccount(uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "S1 borrow-reauth resetter",
            id: uuid,
            title: "S1 Account \(uuid.suffix(6))"
        )
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        return Account(publication: publication, imageCache: MockImageCache())
    }

    private static func book(identifier: String) -> TPPBook {
        TPPBookMocker.mockBook(identifier: identifier, title: "Title-\(identifier)")
    }

    // MARK: - BorrowOperation harness (for Contract 4 — mirrors the write-ahead coupling suite)

    /// A no-credentials account whose auth definition `needsAuth`, so a borrow
    /// auth-error routes into the sign-in-modal recovery arm.
    private static func noCredentialsNeedsAuthAccount() -> TPPUserAccountMock {
        let account = TPPUserAccountMock()
        account._credentials = nil
        account._authDefinition = SyntheticBasicNeedsAuthS1.authentication
        return account
    }

    /// Builds a `BorrowOperation` whose closure seams record into `log`. The
    /// no-credentials + needs-auth account + a `fetchBook` that throws
    /// `.network(.unauthorized)` route every borrow into the "no creds → sign-in
    /// modal" arm, gated by the per-book circuit breaker. The modal completion is
    /// recorded, never invoked — no retry recursion.
    private static func makeBorrowOperation(
        userAccount: TPPUserAccountMock,
        bookIdentifier: String,
        log: CallLog
    ) -> BorrowOperation {
        let callLog = log
        let capturedBookId = bookIdentifier
        let account = userAccount
        let authError = PalaceError.network(.unauthorized)

        return BorrowOperation(
            bookRegistry: TPPBookRegistryMock(),
            downloadAnnouncementService: DownloadAnnouncementService(),
            errorActivityTracker: .shared,
            debugSettings: DebugSettings(),
            userRetryTracker: .shared,
            userAccountProvider: { account },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { _, _, _ in
                throw authError
            },
            presentBorrowErrorAlert: { _, _, _, _, book, _ in
                callLog.record("presentBorrowErrorAlert", args: ["book": book.identifier])
            },
            presentSignInModal: { _ in
                callLog.record("presentSignInModal", args: ["book": capturedBookId])
            },
            attemptOIDCReauth: { false }
        )
    }

    /// Drive one borrow and swallow the expected rethrow (auth-error borrows
    /// always rethrow — both `.routeToReauth` and `.showGenericError` throw).
    private static func borrowExpectingThrow(_ op: BorrowOperation, _ book: TPPBook) async {
        do {
            _ = try await op.borrowAsync(book, attemptDownload: false)
            XCTFail("Auth-error borrow for '\(book.identifier)' must rethrow, not succeed")
        } catch {
            // expected
        }
    }
}

// MARK: - Local auth-definition fixture

/// Basic-auth `AccountDetails.Authentication` (`needsAuth == true`,
/// `isBrowserBased == false`) — routes borrow auth-errors into the
/// no-credentials sign-in-modal arm. The OPDS2 memberwise init is internal to
/// PalaceCatalog, so JSON round-trip is the supported construction path.
private enum SyntheticBasicNeedsAuthS1 {
    static var authentication: AccountDetails.Authentication {
        let json = """
        {
          "type": "http://opds-spec.org/auth/basic",
          "description": "Basic auth",
          "labels": {"login": "Barcode", "password": "PIN"}
        }
        """
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }
}
