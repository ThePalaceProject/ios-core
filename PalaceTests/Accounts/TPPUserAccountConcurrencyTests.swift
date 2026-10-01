//
//  TPPUserAccountConcurrencyTests.swift
//
//  Pins the atomicity of `TPPUserAccount.incrementSignInGeneration()`.
//  `signInGeneration` decides whether a stale sign-out callback wipes freshly
//  re-authenticated credentials, so a lost update is a credential-integrity
//  defect. Single-threaded sign-out tests catch arithmetic regressions but
//  cannot tell a locked read-modify-write from a get-then-set; only concurrent
//  callers expose that.
//

import XCTest
@testable import Palace

@MainActor
final class TPPUserAccountConcurrencyTests: XCTestCase {

  /// Concurrent increments must each count exactly once.
  ///
  /// Mutant killed: replacing the locked RMW in `incrementSignInGeneration()`
  /// with `signInGeneration += 1` (a get-then-set across two `controlLock`
  /// acquisitions), or releasing the lock before the write completes. Both drop
  /// the final value below `start + iterations` under contention — a lost
  /// update. An atomic RMW lands exactly on `start + iterations` every run.
  func testIncrementSignInGeneration_underConcurrentCallers_countsExactlyOncePerCall() {
    // Explicit type annotation: direct `TPPUserAccount(...)` construction is
    // forbidden by TPPUserAccountIsolationLintTests, so the sanctioned factory
    // seam is the SUT constructor here.
    let account: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated()
    let start = account.signInGeneration
    let iterations = 10_000

    DispatchQueue.concurrentPerform(iterations: iterations) { _ in
      account.incrementSignInGeneration()
    }

    XCTAssertEqual(
      account.signInGeneration,
      start + iterations,
      "incrementSignInGeneration() must be an atomic read-modify-write — a "
      + "get-then-set (or an early unlock) loses updates under contention, "
      + "which would let a stale sign-out wipe freshly-re-authed credentials."
    )
  }
}
