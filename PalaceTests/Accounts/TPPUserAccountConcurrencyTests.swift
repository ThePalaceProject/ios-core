//
//  TPPUserAccountConcurrencyTests.swift
//  PalaceTests
//
//  Pins the atomicity guarantee of `TPPUserAccount.incrementSignInGeneration()`
//  — the sole behavioral reason that method exists over a plain
//  `signInGeneration += 1`. `signInGeneration` gates whether a stale sign-out
//  callback wipes freshly-re-authenticated credentials (see
//  TPPSignInBusinessLogic+SignOut.cancelPendingSignOut), so a lost update
//  under contention is a real credential-integrity defect, not a cosmetic race.
//
//  This lives in its own test because the existing single-threaded
//  TPPSignInBusinessLogicSignOutTests coverage kills the arithmetic mutants
//  (`+= 1` → `+= 0` / no-op) but CANNOT distinguish an atomic locked
//  read-modify-write from a non-atomic get-then-set (two separate lock
//  acquisitions = TOCTOU). Only concurrent callers expose that.
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
