//
//  BookRegistrySyncTimeoutSeamTests.swift
//  PalaceTests
//
//  Pins the readiness-timeout BOUND that `BookRegistrySync.sync` hands across the
//  `AccountScopeProviding` seam (HelpSpot #18414).
//
//  WHY THIS FILE EXISTS — the regression it prevents:
//
//  The 3.2.3 hotfix bounded registry sync's account-readiness await at 30s. A
//  wedged per-UUID `authentication_document` fetch parks the account at
//  `.detailsLoading`; unbounded, that await never returns, registry sync never
//  completes, and My Books spins forever with no self-heal short of a sign-out.
//
//  The Wave 3 S2 seam extraction then moved the await out of the engine and behind
//  `AccountScopeProviding.loansURL(forAccount:)` — and dropped `timeout:` in the
//  move. Every existing test stayed green, because the hotfix's timeout test
//  exercises `Account.awaitReady(timeout:)` — the HELPER — directly, never the
//  production caller. The bug shipped to develop invisibly and re-surfaced in the
//  field (HelpSpot #18619 "screen is not showing any books", #18624 "never finished
//  searching, just kept spinning").
//
//  So this suite tests the PRODUCER: that the engine actually passes a finite bound.
//  Its sibling (`AccountScopeAdapterTests.testLoansURL_accountWedgedAtDetailsLoading…`)
//  proves the adapter on the other side of the seam honors it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace
@testable import PalaceBookRegistry

/// Spy `AccountScopeProviding` that records the readiness bound it is handed and
/// then reports "anonymous" (nil loans URL) so `sync` unwinds immediately — the
/// timeout hand-off is the only behavior under test.
private final class TimeoutRecordingAccountScope: AccountScopeProviding, @unchecked Sendable {
    let accountID: String
    private let lock = NSLock()
    private var _received: [TimeInterval] = []

    /// Every `readinessTimeout` value the engine passed, in call order.
    var receivedTimeouts: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    init(accountID: String) { self.accountID = accountID }

    var currentAccountID: String? { accountID }

    var accountDidChangePublisher: AnyPublisher<Void, Never> {
        Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher()
    }

    /// True so `sync` clears the no-credentials gate and reaches the readiness await.
    func hasCredentials(forAccount accountID: String) -> Bool { true }

    func loansURL(forAccount accountID: String, readinessTimeout: TimeInterval) async throws -> URL? {
        record(readinessTimeout)
        return nil   // anonymous → sync reverts to .loaded and returns
    }

    /// Synchronous so the lock is never taken from the `async` body above
    /// (`NSLock.lock()` is unavailable from asynchronous contexts).
    private func record(_ timeout: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _received.append(timeout)
    }
}

@MainActor
final class BookRegistrySyncTimeoutSeamTests: XCTestCase {

    private var store: BookRegistryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = BookRegistryStore()
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    private func makeSync(scope: any AccountScopeProviding) -> BookRegistrySync {
        let appContainer = makeTestAppContainer()
        return BookRegistrySync(
            store: store,
            accountScope: scope,
            dependencies: RegistryExternalDependencies(
                downloadService: { appContainer.downloadCenter },
                loansFeedFetcher: { appContainer.opdsFeedService },
                sideloadedIdentifiers: { [] },
                registryDirectory: { TPPBookContentMetadataFilesHelper.directory(for: $0) },
                onAvailabilityChange: { _, _ in }
            )
        )
    }

    /// Contract: `sync` must request the loans URL with a FINITE readiness bound.
    ///
    /// Kill case: restore the unbounded `accountScope.loansURL(forAccount:)` call and
    /// this no longer compiles; widen the bound to `.infinity` or `.greatestFiniteMagnitude`
    /// (a "technically bounded" cheat that still hangs My Books) and the assertions fail.
    func testSync_passesFiniteReadinessBoundAcrossTheAccountScopeSeam() async {
        let scope = TimeoutRecordingAccountScope(accountID: "seam-\(UUID().uuidString)")
        let sync = makeSync(scope: scope)

        let resolved = expectation(description: "sync unwinds through the anonymous-account path")
        sync.sync(currentState: .loaded, setState: { _ in }) { _, _ in resolved.fulfill() }
        // Bounded wait, not a deadline poll: bounded — the spy reports anonymous (nil loans URL), so sync() unwinds through its own completion on the next main hop. The completion is guaranteed to fire, not polled for.
        await fulfillment(of: [resolved], timeout: 5)  // STARVE-001-OK

        XCTAssertEqual(scope.receivedTimeouts.count, 1,
                       "sync must resolve the loans URL through the seam exactly once")

        guard let bound = scope.receivedTimeouts.first else { return }
        XCTAssertTrue(bound.isFinite,
                      "an infinite/absent bound IS the #18414 wedge — registry sync would never complete")
        XCTAssertGreaterThan(bound, 0,
                            "a non-positive bound would fail every cold launch before details load")
        XCTAssertEqual(bound, BookRegistrySync.authReadinessTimeout, accuracy: 0.001,
                       "the engine owns the policy value — it must pass its own authReadinessTimeout, not an ad-hoc literal")
    }

    /// The published bound must stay in the range the #18414 fix chose: long enough to
    /// cover a slow-but-healthy cold-launch auth-doc fetch, short enough that a wedge
    /// self-heals inside one user's patience window rather than requiring a sign-out.
    ///
    /// Kill case: change `authReadinessTimeout` to 0 (breaks every cold launch) or to
    /// 600 (restores the practical hang) and this fails.
    func testAuthReadinessTimeout_staysWithinTheChosenSelfHealWindow() {
        XCTAssertEqual(BookRegistrySync.authReadinessTimeout, 30, accuracy: 0.001,
                       "3.2.3 shipped a 30s bound; changing it is a UX decision, not a refactor side effect")
    }
}
