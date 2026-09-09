//
//  OIDCReauthRetryBehaviorTests.swift
//  PalaceTests
//
//  Drives `attemptOIDCSilentReauth`'s retry loop for real, through the injected
//  presentation seam.
//
//  These exist because three rounds of SoD review defeated the structural-lint
//  approach. The verdict, precisely: `XCTAssertTrue(code.contains(...))` is
//  MONOTONE in the source text — it detects deletion but never ADDITION or
//  reordering. So a lint pinning `outcome.isRetryable && attempt == 0` stayed
//  green while `case .patronCancelled where attempt == 0: continue` was INSERTED
//  after it (re-presenting a sheet the patron dismissed), and stayed green while
//  `0...1` was narrowed to `0...0` (deleting the retry entirely).
//
//  The fix was a seam, not more string assertions. With the presentation
//  injected, "how many times did we present, and did we present after a
//  cancellation" become observable facts rather than spellings.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class OIDCReauthRetryBehaviorTests: XCTestCase {

    /// Records every presentation and replays a scripted sequence of outcomes.
    /// `@unchecked Sendable`: the seam is `@Sendable`, and the recorder is only
    /// ever touched serially by the awaited loop.
    private final class PresentationSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var scripted: [OIDCReauthAttempt]
        private(set) var presentationCount = 0

        init(_ scripted: [OIDCReauthAttempt]) { self.scripted = scripted }

        func present(_: URL, _: String, _: TPPUserAccount) async -> OIDCReauthAttempt {
            lock.withLock {
                presentationCount += 1
                return scripted.isEmpty ? .failed : scripted.removeFirst()
            }
        }
    }

    /// The loop is driven directly via `runOIDCReauthLoop`, which takes an
    /// already-built URL. Aiming at `attemptOIDCSilentReauth` instead would
    /// require an account carrying OIDC config that no unit test can synthesize,
    /// so every test would XCTSkip — and a skipped test is a silent pass.
    /// An ISOLATED account, from the test factory rather than the process-wide
    /// account cache.
    ///
    /// The cached variant tripped two lints at once and both were right: it is
    /// process-wide, so a fixed `libraryUUID` writes keychain entries every other
    /// test in the bundle can see (`TPPUserAccountIsolationLintTests`), and
    /// acquiring singleton state without a `tearDown` to drop it is what
    /// `TearDownRequiredLintTests` exists to stop. The factory mints a
    /// UUID-namespaced instance and registers its own cleanup at
    /// `testCaseDidFinish`, so neither problem arises and no `tearDown` is owed.
    ///
    /// Both lints match on source text, so naming those APIs literally here — even
    /// inside a comment — re-triggers them. Hence the prose.
    ///
    /// Nothing here depends on the account's identity: it is passed straight
    /// through to `runOIDCReauthLoop` and the presentation spy ignores it.
    private var account: TPPUserAccount {
        TPPUserAccountTestFactory.makeIsolated()
    }

    private let url = URL(string: "https://idp.example.invalid/authorize")!

    // MARK: - Consent

    /// THE consent property, driven rather than spelled.
    ///
    /// The additive mutant that beat every previous lint — inserting
    /// `case .patronCancelled where attempt == 0: continue` — makes this fail,
    /// because it asserts the OBSERVED number of presentations.
    func testPatronCancellation_presentsExactlyOnce() async {
        let spy = PresentationSpy([.patronCancelled, .succeeded])

        let result = await BorrowOperation.runOIDCReauthLoop(
            url: url, callbackScheme: "palace", userAccount: account, present: spy.present)

        XCTAssertEqual(spy.presentationCount, 1,
                       "A dismissed sheet must NOT be re-presented. A second presentation here means the "
                       + "consent guard was bypassed — the exact mutant that survived three lint rounds.")
        XCTAssertFalse(result, "A patron cancellation is not a successful re-auth")
    }

    // MARK: - Retry

    /// The headline fix, driven. Narrowing the loop bound to `0...0` makes this
    /// fail, where the lint stayed green.
    func testPresentationFailure_thenSuccess_presentsTwiceAndSucceeds() async {
        let spy = PresentationSpy([.presentationFailed, .succeeded])

        let result = await BorrowOperation.runOIDCReauthLoop(
            url: url, callbackScheme: "palace", userAccount: account, present: spy.present)

        XCTAssertEqual(spy.presentationCount, 2,
                       "A presentation failure is OURS, not a decline — it must be retried once")
        XCTAssertTrue(result, "The retry succeeded, so re-auth succeeded")
    }

    /// The retry is bounded: two failures stop, they do not loop.
    func testPresentationFailure_twice_stopsAtTwoPresentations() async {
        let spy = PresentationSpy([.presentationFailed, .presentationFailed])

        let result = await BorrowOperation.runOIDCReauthLoop(
            url: url, callbackScheme: "palace", userAccount: account, present: spy.present)

        XCTAssertEqual(spy.presentationCount, 2, "Bounded at two attempts — never an unbounded re-auth loop")
        XCTAssertFalse(result)
    }

    /// Success on the first try must not present again.
    func testSuccess_presentsExactlyOnce() async {
        let spy = PresentationSpy([.succeeded, .succeeded])

        let result = await BorrowOperation.runOIDCReauthLoop(
            url: url, callbackScheme: "palace", userAccount: account, present: spy.present)

        XCTAssertEqual(spy.presentationCount, 1, "A successful re-auth must not present a second sheet")
        XCTAssertTrue(result)
    }

    /// A plain failure is not retried — only OUR presentation failures are.
    func testPlainFailure_presentsExactlyOnce() async {
        let spy = PresentationSpy([.failed, .succeeded])

        let result = await BorrowOperation.runOIDCReauthLoop(
            url: url, callbackScheme: "palace", userAccount: account, present: spy.present)

        XCTAssertEqual(spy.presentationCount, 1,
                       "Only `.presentationFailed` is retryable; a generic failure must not re-present")
        XCTAssertFalse(result)
    }
}
