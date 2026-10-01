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
import PalaceKeychain
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

  /// A new account's first touch can come from several threads at once, as in
  /// `TPPNetworkExecutor.executeRequest`. Runs in the ThreadSanitizer lane,
  /// which reported lazily built keychain variables racing here (CI run 36934646693).
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

  /// Keychain keys are a persistence contract: an updated app must find what an
  /// earlier build stored. Keys carry the library UUID, except for NYPL's.
  func testKeychainKeys_carryLibraryUUID_exceptForNYPL() {
    let libraryUUID = "test-uuid-\(UUID().uuidString)"
    let account: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated(libraryUUID: libraryUUID)
    account.setDeviceID("device-library")
    XCTAssertEqual(TPPKeychain.shared.object(forKey: "TPPAccountDeviceIDKey_\(libraryUUID)") as? String,
                   "device-library")

    // The factory's teardown `removeAll()` clears these keys again.
    let nyplKey = "TPPAccountDeviceIDKey"
    let nypl: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated(libraryUUID: AccountsManager.TPPAccountUUIDs[0])
    nypl.setDeviceID("device-nypl")
    XCTAssertEqual(TPPKeychain.shared.object(forKey: nyplKey) as? String, "device-nypl")
  }
}
