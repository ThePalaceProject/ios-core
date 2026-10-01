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

  /// The first touch of an account's keychain storage can come from several
  /// threads at once: `TPPNetworkExecutor.executeRequest` reads
  /// `authDefinition` and `credentials` from whichever thread issued the
  /// request, and a fresh instance (the no-account placeholder on first
  /// launch, or a library just added) has never been touched. Every thread
  /// must end up sharing ONE keychain variable per key.
  ///
  /// When two threads each build a variable for the same key and the later
  /// store wins, a write made through the discarded variable is invisible to
  /// the survivor's cache, so the account reads back no credentials although
  /// the keychain holds them. ThreadSanitizer reports the unsynchronized first
  /// access itself (CI run 36934646693: `_authDefinition.getter`), which is
  /// why this class is in the TSan lane; the assertion below catches the lost
  /// write when the interleaving lands without TSan.
  func testFirstTouchFromConcurrentThreads_writeIsVisibleToEveryLaterRead() {
    let accountCount = 100
    let threadsPerAccount = 8

    for index in 0..<accountCount {
      let account: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated()
      let token = "token-\(index)"

      DispatchQueue.concurrentPerform(iterations: threadsPerAccount) { thread in
        if thread == 0 {
          account.credentials = .token(authToken: token)
        } else {
          _ = account.authDefinition
          _ = account.credentials
        }
      }

      XCTAssertEqual(
        account.authToken,
        token,
        "account \(index): the token written during the first concurrent touch "
        + "must be readable afterwards — a nil here means the write went through "
        + "a keychain variable that a racing first access then replaced."
      )
    }
  }

  /// An account keeps the same keychain variables across reads, so a value
  /// another instance writes under the same key is seen only after
  /// `invalidateCredentialCaches()` (the account-switch path relies on that).
  func testKeychainVariables_persistAcrossReads_untilCachesAreInvalidated() {
    let libraryUUID = "test-uuid-\(UUID().uuidString)"
    let reader: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated(libraryUUID: libraryUUID)
    let writer: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated(libraryUUID: libraryUUID)

    reader.credentials = .token(authToken: "first")
    writer.credentials = .token(authToken: "second")

    XCTAssertEqual(reader.authToken, "first",
                   "a second read must use the variable (and cache) the first write populated")

    reader.invalidateCredentialCaches()

    XCTAssertEqual(reader.authToken, "second",
                   "after invalidation the account must re-read the keychain")
  }
}
