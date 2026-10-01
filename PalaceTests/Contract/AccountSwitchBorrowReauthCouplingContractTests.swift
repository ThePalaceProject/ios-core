//
//  AccountSwitchBorrowReauthCouplingContractTests.swift
//  PalaceTests
//
//  Pins the account-switch reset of the per-book borrow-reauth circuit breaker
//  (`MyBooksDownloadCenter.clearAllBorrowReauthState()`, called from
//  `AccountsManager.cleanupActiveContentBeforeAccountSwitch`): 1st auth-error
//  borrow → reauth offered; 2nd for the same book → generic error; after the clear
//  → reauth offered again. Without the reset, a patron who switches libraries after
//  a failed borrow never sees a reauth prompt
//  (docs/architecture/god-class-decomposition-plan.md §3a-2/§3a-3).
//  No network or UIKit; the breaker is cleared in setUp and tearDown.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class AccountSwitchBorrowReauthCouplingContractTests: XCTestCase {

    private var log: CallLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The reauth breaker is a process-wide static — start every scenario
        // from a clean breaker so a prior test can't pre-trip it.
        BorrowOperation.clearAllBorrowReauthState()
        log = CallLog()
    }

    override func tearDownWithError() throws {
        // Do not leak a tripped breaker into downstream suites.
        BorrowOperation.clearAllBorrowReauthState()
        log = nil
        try super.tearDownWithError()
    }

    // MARK: - Contract 1: breaker trips on the 2nd auth-error for the same book

    /// First auth-error borrow → reauth (`presentSignInModal`). Second for the
    /// same book → breaker suppresses reauth → generic error alert
    /// (`presentBorrowErrorAlert`). This is the state the account switch clears.
    ///
    /// Regressions caught:
    ///  - Removing the circuit-breaker guard (BorrowOperation.swift:626) → the
    ///    2nd attempt would ALSO present the sign-in modal → sequence
    ///    [presentSignInModal, presentSignInModal] ≠ snapshot.
    ///  - Never marking the breaker → same drift.
    func testRepeatAuthErrorSameBook_secondAttemptSuppressedToGenericAlert() async {
        let account = Self.noCredentialsNeedsAuthAccount()
        let book = Self.book(identifier: "reauth-coupling-C1")
        let op = makeOperation(userAccount: account, bookIdentifier: book.identifier, log: log)

        await borrowExpectingThrow(op, book)   // attempt 1 → reauth
        await borrowExpectingThrow(op, book)   // attempt 2 → breaker → generic alert

        ContractSnapshot.assert(log, named: "repeatSameBook_tripsBreaker")
    }

    // MARK: - Contract 2: account switch (clearAll) re-enables reauth

    /// THE coupling contract. After the breaker has tripped for a book, calling
    /// `clearAllBorrowReauthState()` — exactly what
    /// `AccountsManager.cleanupActiveContentBeforeAccountSwitch` invokes on a
    /// library switch — must re-offer reauth for that book.
    ///
    /// Regressions caught:
    ///  - `clearAllBorrowReauthState()` no-op'd / dropped from the switch path →
    ///    the 3rd attempt stays suppressed → [modal, alert, alert] ≠ snapshot.
    func testClearAllAfterBreakerTripped_reenablesReauthForSameBook() async {
        let account = Self.noCredentialsNeedsAuthAccount()
        let book = Self.book(identifier: "reauth-coupling-C2")
        let op = makeOperation(userAccount: account, bookIdentifier: book.identifier, log: log)

        await borrowExpectingThrow(op, book)   // attempt 1 → reauth (modal)
        await borrowExpectingThrow(op, book)   // attempt 2 → breaker → alert

        // Simulate the account switch's Downloads-side cleanup.
        BorrowOperation.clearAllBorrowReauthState()

        await borrowExpectingThrow(op, book)   // attempt 3 → reauth AGAIN (modal)

        ContractSnapshot.assert(log, named: "clearAll_reenablesReauth")
    }

    // MARK: - Contract 3: clearAll is a GLOBAL wipe (all books, not just current)

    /// Two independent books each trip their own breaker. A SINGLE
    /// `clearAllBorrowReauthState()` must reset BOTH — the switch clears the
    /// whole tracker, not one entry. Pins `reauthTracker.clearAll()` semantics
    /// (BorrowOperation.swift:121/142).
    ///
    /// Regression caught:
    ///  - Replacing `clearAll()` with a single-book `clear(currentBookId)` → book
    ///    B's post-clear attempt would stay suppressed → the final two records
    ///    would read [modal(A), alert(B)] instead of [modal(A), modal(B)].
    func testClearAll_resetsBreakerForEveryBook_notJustOne() async {
        let account = Self.noCredentialsNeedsAuthAccount()
        let bookA = Self.book(identifier: "reauth-coupling-C3-A")
        let bookB = Self.book(identifier: "reauth-coupling-C3-B")
        let opA = makeOperation(userAccount: account, bookIdentifier: bookA.identifier, log: log)
        let opB = makeOperation(userAccount: account, bookIdentifier: bookB.identifier, log: log)

        await borrowExpectingThrow(opA, bookA) // modal(A)
        await borrowExpectingThrow(opA, bookA) // alert(A) — A tripped
        await borrowExpectingThrow(opB, bookB) // modal(B)
        await borrowExpectingThrow(opB, bookB) // alert(B) — B tripped

        BorrowOperation.clearAllBorrowReauthState() // one global wipe

        await borrowExpectingThrow(opA, bookA) // modal(A) — reset
        await borrowExpectingThrow(opB, bookB) // modal(B) — reset (proves GLOBAL)

        ContractSnapshot.assert(log, named: "clearAll_isGlobalAcrossBooks")
    }

    // MARK: - Contract 4: the breaker is keyed PER-BOOK (isolation, no clear)

    /// Contrast to Contract 3: WITHOUT any clear, a tripped breaker on book A
    /// must NOT suppress book B's FIRST auth-error borrow. Pins that the tracker
    /// keys on `book.identifier` (BorrowOperation.swift:118–120) — the property
    /// that makes the account-switch's global clear meaningful rather than moot.
    ///
    /// Regression caught:
    ///  - Keying the breaker on a constant / ignoring the book id → book B's
    ///    first attempt would be suppressed → [modal(A), alert(A), alert(B)]
    ///    instead of [modal(A), alert(A), modal(B)].
    func testBreakerIsPerBook_trippedABookDoesNotSuppressAnother() async {
        let account = Self.noCredentialsNeedsAuthAccount()
        let bookA = Self.book(identifier: "reauth-coupling-C4-A")
        let bookB = Self.book(identifier: "reauth-coupling-C4-B")
        let opA = makeOperation(userAccount: account, bookIdentifier: bookA.identifier, log: log)
        let opB = makeOperation(userAccount: account, bookIdentifier: bookB.identifier, log: log)

        await borrowExpectingThrow(opA, bookA) // modal(A)
        await borrowExpectingThrow(opA, bookA) // alert(A) — A tripped

        await borrowExpectingThrow(opB, bookB) // modal(B) — B's FIRST attempt, unaffected

        ContractSnapshot.assert(log, named: "breakerIsPerBook")
    }

    // MARK: - Operation factory

    /// Builds a `BorrowOperation` whose closure seams record into `log`. The
    /// no-credentials + needs-auth account + a `fetchBook` that throws
    /// `.network(.unauthorized)` route every borrow into
    /// `handleBorrowAuthErrorIfNeeded`'s "no creds → sign-in modal" arm
    /// (BorrowOperation.swift:699), gated by the per-book circuit breaker.
    ///
    /// `presentSignInModal` receives no book argument, so the book identifier is
    /// captured at build time (`bookIdentifier`) for a stable snapshot record.
    /// The modal completion is stored, never called — no retry recursion.
    private func makeOperation(
        userAccount: TPPUserAccountMock,
        bookIdentifier: String,
        log: CallLog
    ) -> BorrowOperation {
        let callLog = log
        let capturedBookId = bookIdentifier
        let account = userAccount
        let authError = PalaceError.network(.unauthorized)

        let operation = BorrowOperation(
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
        return operation
    }

    /// Drive one borrow and swallow the expected rethrow. Every auth-error
    /// borrow rethrows (`.routeToReauth` / `.showGenericError` both throw).
    private func borrowExpectingThrow(_ op: BorrowOperation, _ book: TPPBook) async {
        do {
            _ = try await op.borrowAsync(book, attemptDownload: false)
            XCTFail("Auth-error borrow for '\(book.identifier)' must rethrow, not succeed")
        } catch {
            // expected — the routing decision is what the snapshot pins, via seams.
        }
    }

    // MARK: - Fixtures

    /// A no-credentials account whose auth definition `needsAuth`, so a borrow
    /// auth-error routes into the sign-in-modal recovery arm.
    private static func noCredentialsNeedsAuthAccount() -> TPPUserAccountMock {
        let account = TPPUserAccountMock()
        account._credentials = nil
        account._authDefinition = SyntheticBasicNeedsAuth.authentication
        return account
    }

    /// Deterministic-identifier book with a real default-acquisition href so
    /// `borrowAsync` reaches `fetchBook` (BorrowOperation.swift:382 guard).
    private static func book(identifier: String) -> TPPBook {
        TPPBookMocker.mockBook(identifier: identifier, title: "Title-\(identifier)")
    }
}

// MARK: - Local auth-definition fixture

/// Basic-auth `AccountDetails.Authentication` (`needsAuth == true`,
/// `isBrowserBased == false`) — routes borrow auth-errors into the
/// no-credentials sign-in-modal arm rather than the browser/OIDC arm. The
/// OPDS2 memberwise init is internal to PalaceCatalog, so JSON round-trip is
/// the supported construction path (same technique as the per-file
/// `SyntheticAuthDef` fixtures in the MyBooks suites).
private enum SyntheticBasicNeedsAuth {
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
