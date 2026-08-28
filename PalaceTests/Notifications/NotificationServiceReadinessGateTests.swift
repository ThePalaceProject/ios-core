//
//  NotificationServiceReadinessGateTests.swift
//  PalaceTests
//
//  Runtime coverage for the PP-4958 readiness gate: `updateToken()` must not
//  reach token registration while the current account is still fetching its
//  authentication document.
//
//  THE OBSERVABLE, and why an earlier round wrongly concluded there wasn't one.
//
//  A first attempt counted `userAccount(for:)`. That is ambiguous: `updateToken()`
//  reads `currentUserAccount` in its own prologue, resolving the SAME uuid
//  registration would, so a second trigger whose claim was correctly REJECTED
//  looked identical to the gate failing. I concluded no unambiguous observable
//  existed and deleted the test. Two independent reviewers found the real one in
//  the same file.
//
//  Read counting was the second attempt and is ALSO unusable, for a different
//  reason: the test host re-enters `updateToken()` through the observers
//  `installNotificationObservers()` registers, and `decideHoldNavigation` reads
//  `currentAccount` as well, so neither the count nor its parity is stable. That
//  version passed in isolation and failed intermittently in the suite.
//
//  THE OBSERVABLE THAT WORKS: claim lifetime.
//
//  `RegistrationClaims` holds the account's slot from just after the account is
//  captured until the awaiting Task body RETURNS. So:
//
//      still claimed after a real budget  <=>  the readiness wait is parked
//      released                            <=>  the attempt ran to completion
//
//  Interfering triggers cannot corrupt this: a second trigger for the same uuid
//  is REJECTED before it enters the Task, so it never releases the slot. The
//  signal depends only on the mechanism under test.
//
//  Mutation-proven: replacing the readiness await with a no-op releases the
//  claim within milliseconds and fails `testUpdateToken_whileLoading_holdsTheClaim`.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

/// Minimal provider returning one account. Deliberately not added to the shared
/// `TPPLibraryAccountMock`, which many suites use.
private final class GateAccountsProvider: NSObject, TPPLibraryAccountsProvider, @unchecked Sendable {
    private let account: Account
    init(account: Account) { self.account = account; super.init() }

    var currentAccount: Account? { account }
    var currentAccountId: String? { account.uuid }
    var tppAccountUUID: String { account.uuid }
    func account(_ uuid: String) -> Account? { uuid == account.uuid ? account : nil }
    /// `TPPUserAccountMock`, not `TPPUserAccount` — `TPPUserAccountIsolationLintTests`
    /// bans raw `sharedAccount` in test code, and it caught this file. Nothing
    /// here depends on real credential storage: `updateToken()` reads
    /// `currentUserAccount.authState` for its log line only, and the readiness
    /// gate is reached regardless of what it says.
    func userAccount(for uuid: String) -> TPPUserAccount { TPPUserAccountMock.sharedAccount(libraryUUID: uuid) }
    var currentUserAccount: TPPUserAccount { userAccount(for: account.uuid) }
}

final class NotificationServiceReadinessGateTests: XCTestCase {

    /// Accounts parked at `.detailsLoading` by a test, so `tearDown` can resolve
    /// them.
    ///
    /// Without this, a test that deliberately leaves the gate holding leaks its
    /// `awaitReady` sleep for the full 45s bound — and that Task retains a
    /// `NotificationService` which the test-only initializer registered as a
    /// permanent `NotificationCenter` observer, so it wakes up inside whatever
    /// suite is running 45s later and files a `.residual` Crashlytics non-fatal
    /// from it. Multiplied by `-test-iterations 3`. This is precisely the leak
    /// `PP4958ReadinessPrimitiveTests` was deleted for, and a reviewer caught it
    /// here one round after that deletion.
    private var parkedAccounts: [Account] = []

    override func tearDown() {
        // Drive every parked account terminal FIRST, so any awaiter still
        // suspended in `awaitReady` resumes and its Task exits, then drain the
        // process-global store — the hygiene `AccountStateMachineTests`
        // already documents for this primitive.
        for account in parkedAccounts {
            account._setState(.detailsFailed(.readinessTimedOut(timeout: 0)))
        }
        parkedAccounts = []
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        super.tearDown()
    }

    private func makeFreshAccount(uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(
            updated: Date(), description: nil, id: uuid, title: "PP-4958 gate fixture"
        )
        return Account(
            publication: OPDS2Publication(links: [], metadata: metadata, images: nil),
            imageCache: MockImageCache()
        )
    }

    /// An account parked mid-load: no authentication document, so `details` is
    /// nil — precisely the PP-4958 state. Registration reaching it is the defect.
    private func makeLoadingAccount() -> Account {
        let account = makeFreshAccount(uuid: "gate-\(UUID().uuidString)")
        account._setState(.detailsLoading)
        XCTAssertNil(account.details, "precondition: the account must have no details, or this suite is not exercising PP-4958")
        parkedAccounts.append(account)
        return account
    }

    /// A real `AccountDetails`, built the way production builds it — through
    /// `authenticationDocument.didSet` — so driving the account terminal below is
    /// the same transition the auth-doc loader performs.
    private func makeDetails(for account: Account) throws -> AccountDetails {
        // XCTUnwrap, NOT XCTSkip. A skip here would silently disable the
        // central test for this fix — `whileLoading_holdsTheClaim` calls this
        // for its promptness witness — and a skipped test is indistinguishable
        // from a passing one on the board. If the fixture is missing, that is a
        // broken suite and it should say so.
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "nypl_authentication_document", withExtension: "json"),
                                "nypl_authentication_document.json missing from the PalaceTests bundle — this suite cannot exercise the PP-4958 gate without it")
        account.authenticationDocument = try OPDS2AuthenticationDocument.fromData(Data(contentsOf: url))
        return try XCTUnwrap(account.details,
                             "the auth-doc fixture did not populate account.details — driving the account terminal would be a no-op")
    }

    /// An account already terminal-loaded at call time — the fast path.
    private func makeLoadedAccount() throws -> Account {
        let account = makeFreshAccount(uuid: "gate-ready-\(UUID().uuidString)")
        account._setState(.detailsLoaded(try makeDetails(for: account)))
        return account
    }

    private func makeService(account: Account) -> NotificationService {
        NotificationService(
            authStatePublisher: PassthroughSubject<TPPAccountAuthState, Never>().eraseToAnyPublisher(),
            onAuthStateRetryRequested: {},
            accountsManager: GateAccountsProvider(account: account)
        )
    }

    /// Spins the main runloop until `condition` holds or the budget expires.
    /// A real budget matters: the registration hop lands via
    /// `DispatchQueue.main.async`, which `Task.yield()` does not pump — an
    /// impatient earlier version of this suite passed vacuously.
    private func wait(upTo seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - The gate holds

    /// THE test for this fix: while the account is stuck at `.detailsLoading`,
    /// the attempt must still be parked in the readiness wait.
    ///
    /// Mutation-proven — removing the await releases the claim in milliseconds.
    func testUpdateToken_whileLoading_holdsTheClaim() throws {
        let account = makeLoadingAccount()
        let service = makeService(account: account)

        service.updateToken()

        // The claim is taken BEFORE the Task starts, so "still claimed" would
        // also hold if the Task never ran at all — the cooperative-pool
        // starvation class. `testUpdateToken_onceTheAccountLoads_releasesTheClaim`
        // is what rules that out: it drives the same setup to completion, so a
        // Task that never starts fails there.
        XCTAssertTrue(wait(upTo: 0.3) { service.isRegistrationClaimed(account.uuid) },
                      "precondition: updateToken() must have claimed the account and entered the wait")

        let released = wait(upTo: 1.2) { !service.isRegistrationClaimed(account.uuid) }
        XCTAssertFalse(released,
                       "the attempt completed while the account was still .detailsLoading — registration ran with details nil, which is PP-4958")

        // PER-RUN promptness witness. The sibling
        // `whenAccountIsAlreadyReady_releasesWithinTheHoldingBudget` proves the
        // pool TYPICALLY schedules inside 1.2s, but it is a different run: it
        // cannot rule out that during THIS window the pool was merely slow, in
        // which case the assertion above is vacuous. A reviewer made exactly
        // that point. So drive a ready account through the same executor at the
        // same instant — if IT released, the pool was running, and "still
        // claimed" above means parked rather than starved.
        let readyAccount = try makeLoadedAccount()
        let readyService = makeService(account: readyAccount)
        readyService.updateToken()
        // 1.2s, matching the budget it validates and NOT wider. At 2.0 a
        // scheduling latency in [1.2, 2.0) would satisfy the witness while
        // leaving the assertion above vacuous — the witness has to be at least
        // as strict as the claim it underwrites, or it licenses the very gap it
        // exists to close.
        XCTAssertTrue(wait(upTo: 1.2) { !readyService.isRegistrationClaimed(readyAccount.uuid) },
                      "a ready account did not release either — the pool was starved during this window, so the assertion above proves nothing about the gate")

        // Converts "still claimed" into "provably PARKED". The claim is taken
        // synchronously BEFORE the Task is created, so the assertion above also
        // holds if the executor never scheduled the Task at all — under which a
        // gate-removed mutant would survive. Resolving the account here proves
        // the Task existed and was genuinely suspended in the readiness wait.
        account._setState(.detailsLoaded(try makeDetails(for: account)))
        XCTAssertTrue(wait(upTo: 5.0) { !service.isRegistrationClaimed(account.uuid) },
                      "the claim never released after the account went terminal — the Task was never running, so the assertion above proved nothing")
    }

    /// The top guard: an account already registered must not start an attempt
    /// at all. This change lengthened the window that guard protects, so it is
    /// worth a cell — and it kills the mutant that deletes the guard.
    func testUpdateToken_whenTokenAlreadyRegistered_doesNotClaimAtAll() {
        let account = makeLoadingAccount()
        account.hasUpdatedToken = true
        let service = makeService(account: account)

        service.updateToken()

        XCTAssertFalse(wait(upTo: 0.5) { service.isRegistrationClaimed(account.uuid) },
                       "an account whose token is already registered must not begin a readiness wait — that is duplicate CM traffic")
    }

    /// THE PROMPTNESS CONTROL for `testUpdateToken_whileLoading_holdsTheClaim`.
    ///
    /// That test reads "still claimed after 1.2s" as "parked in the readiness
    /// wait". A reviewer pointed out the gap: it is also true of a Task the
    /// cooperative pool simply scheduled LATE, and no test proved the executor
    /// schedules promptly at all. `onceTheAccountLoads` does not close it — it
    /// rules out never-starts, not starts-late, because it gives the Task a
    /// fresh 5s after driving the account terminal.
    ///
    /// This closes it from the other side: an account that is ALREADY ready
    /// needs no wait, so its claim must release inside the SAME 1.2s budget the
    /// holding test treats as "long enough to be meaningful". If the pool were
    /// slow enough to make that budget meaningless, this test fails too.
    func testUpdateToken_whenAccountIsAlreadyReady_releasesWithinTheHoldingBudget() throws {
        let account = try makeLoadedAccount()
        let service = makeService(account: account)

        service.updateToken()

        XCTAssertTrue(wait(upTo: 1.2) { !service.isRegistrationClaimed(account.uuid) },
                      "a ready account must not wait — if this budget is too short for the fast path, then 'still claimed after 1.2s' in the holding test proves nothing about being parked")
    }

    /// The other half, so the gate cannot pass by never opening at all: a gate
    /// welded shut satisfies the test above and breaks registration for everyone.
    func testUpdateToken_onceTheAccountLoads_releasesTheClaim() throws {
        let account = makeLoadingAccount()
        let service = makeService(account: account)

        service.updateToken()
        XCTAssertTrue(wait(upTo: 0.3) { service.isRegistrationClaimed(account.uuid) },
                      "precondition: the wait must be parked before the account loads, or this proves nothing about it opening")

        account._setState(.detailsLoaded(try makeDetails(for: account)))

        XCTAssertTrue(wait(upTo: 5.0) { !service.isRegistrationClaimed(account.uuid) },
                      "once the account reaches a terminal loaded state the wait must resume and the attempt complete")
    }
}
