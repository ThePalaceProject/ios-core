//
//  TPPKeychainStoredVariableTests.swift
//  PalaceKeychainTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceKeychain

final class TPPKeychainStoredVariableTests: XCTestCase {

    private let testQueue = DispatchQueue(label: "test.keychain.queue")
    private let testKey = "test_keychain_var_\(UUID().uuidString)"

    override func tearDown() {
        // Clean up test keychain entries
        TPPKeychain.shared.removeObject(forKey: testKey)
        super.tearDown()
    }

    // MARK: - Initialization

    func testInit_setsKey() {
        let variable = TPPKeychainVariable<String>(key: testKey, accountInfoQueue: testQueue)
        XCTAssertEqual(variable.key, testKey)
        // Initially the keychain must have no value for this fresh key
        XCTAssertNil(variable.read(), "Fresh keychain variable must return nil before any write")
    }

    // MARK: - Read/Write String

    func testWrite_andRead_string() {
        let variable = TPPKeychainVariable<String>(key: testKey, accountInfoQueue: testQueue)

        variable.write("test-value")
        let result = variable.read()

        XCTAssertEqual(result, "test-value")
        XCTAssertNotNil(result, "Written value must be readable back as non-nil")
        XCTAssertNotEqual(result, "wrong-value", "Read value must match exactly what was written")
    }

    func testWrite_nil_clearsValue() {
        let variable = TPPKeychainVariable<String>(key: testKey, accountInfoQueue: testQueue)

        variable.write("initial")
        XCTAssertNotNil(variable.read())

        variable.write(nil)
        // After writing nil, reading should return nil
        let result = variable.read()
        XCTAssertNil(result)
    }

    func testRead_noValue_returnsNil() {
        let uniqueKey = "nonexistent_key_\(UUID().uuidString)"
        let variable = TPPKeychainVariable<String>(key: uniqueKey, accountInfoQueue: testQueue)

        let result = variable.read()
        XCTAssertNil(result)
        // Reading a second time must also return nil (no side effects)
        XCTAssertNil(variable.read(), "Second read of unset key must also return nil")

        TPPKeychain.shared.removeObject(forKey: uniqueKey)
    }

    // MARK: - Key Change

    func testKeyChange_invalidatesCache() {
        let variable = TPPKeychainVariable<String>(key: testKey, accountInfoQueue: testQueue)

        variable.write("value-for-key-1")
        XCTAssertEqual(variable.read(), "value-for-key-1")

        // Change key — should invalidate cache
        let newKey = "test_keychain_var2_\(UUID().uuidString)"
        variable.key = newKey

        // Reading with new key should not return old key's value
        let result = variable.read()
        // New key has no value stored, so should be nil
        XCTAssertNil(result)

        // Cleanup
        TPPKeychain.shared.removeObject(forKey: newKey)
    }

    // MARK: - Codable Variable

    func testCodableVariable_writeAndRead() {
        let variable = TPPKeychainCodableVariable<[String]>(key: testKey, accountInfoQueue: testQueue)

        let testArray = ["one", "two", "three"]
        variable.write(testArray)

        let result = variable.read()
        XCTAssertEqual(result, testArray)
    }

    func testCodableVariable_nilValue_returnsNil() {
        let uniqueKey = "codable_test_\(UUID().uuidString)"
        let variable = TPPKeychainCodableVariable<[String]>(key: uniqueKey, accountInfoQueue: testQueue)

        let result = variable.read()
        XCTAssertNil(result)

        TPPKeychain.shared.removeObject(forKey: uniqueKey)
    }

    // MARK: - Transaction

    func testTransaction_performExecutesSynchronously() {
        let transaction = TPPKeychainVariableTransaction(accountInfoQueue: testQueue)
        var executed = false

        transaction.perform {
            executed = true
        }

        XCTAssertTrue(executed, "Transaction should execute the block")
    }

    // MARK: - Overwrite

    func testWrite_overwrite_updatesValue() {
        let variable = TPPKeychainVariable<String>(key: testKey, accountInfoQueue: testQueue)

        variable.write("first")
        XCTAssertEqual(variable.read(), "first")

        variable.write("second")
        XCTAssertEqual(variable.read(), "second")
    }

    // MARK: - Read serialization (Crashlytics 0bbbd8fe — EXC_BAD_ACCESS race)

    /// `read()` must return the value produced *inside* the synchronized block.
    /// This pins the contract that `perform` now yields a value; a regression
    /// that reverts to returning `cachedValue` after the block (the original
    /// torn-read bug) cannot satisfy this through the transaction seam.
    func testTransactionPerform_returnsValueComputedInsideLock() {
        let transaction = TPPKeychainVariableTransaction(accountInfoQueue: testQueue)

        let result: Int = transaction.perform {
            // Value originates entirely within the critical section.
            return 7 * 6
        }

        XCTAssertEqual(result, 42, "perform must return the value computed inside the synchronized block")
    }

    /// Regression test for the keychain read race. A background thread reading
    /// credentials while another thread signs out (`write(nil)`/overwrite) tore
    /// the returned value because the read happened outside the lock. With the
    /// read serialized, every non-nil `read()` must observe a *whole* value
    /// that was actually written — never a torn/garbage struct (which would
    /// crash on retain) — and the final state must be consistent.
    ///
    /// Note: this is a *probabilistic* mutation-killer — a revert to the
    /// unsynchronized `return cachedValue` won't tear on every run. A genuine
    /// tear crashes loudly (retain on a torn struct), and
    /// `testTransactionPerform_returnsValueComputedInsideLock` deterministically
    /// backstops the `perform<T>` signature the fix depends on.
    func testRead_underConcurrentWritesAndInvalidation_neverTearsValue() throws {
        try KeychainAvailability.skipIfUnavailable()

        struct Cred: Codable, Equatable, Hashable {
            let token: String
            let identifier: String
        }
        let key = "concurrent_cred_\(UUID().uuidString)"
        let variable = TPPKeychainCodableVariable<Cred>(key: key, accountInfoQueue: testQueue)
        defer { TPPKeychain.shared.removeObject(forKey: key) }

        // Two disjoint sentinels. A torn read would mix fields across the two
        // (or crash); `valid.contains` catches the mix.
        let a = Cred(token: "AAAAAAAAAAAAAAAA", identifier: "id-aaaa")
        let b = Cred(token: "BBBBBBBBBBBBBBBB", identifier: "id-bbbb")
        let valid: Set<Cred> = [a, b]
        variable.write(a)

        DispatchQueue.concurrentPerform(iterations: 4_000) { i in
            switch i % 3 {
            case 0:
                variable.write(i % 2 == 0 ? a : b)
            case 1:
                // Force a fresh keychain decode under contention.
                variable.invalidateCache()
            default:
                if let got = variable.read() {
                    XCTAssertTrue(valid.contains(got),
                                  "read() returned a torn/invalid value: \(got)")
                }
            }
        }

        let final = variable.read()
        XCTAssertTrue(final == a || final == b || final == nil,
                      "final state must be a whole written value or nil, got: \(String(describing: final))")
    }

    /// 0bbbd8fe SPECIFICALLY: a background URLSession continuation reading
    /// `TPPUserAccount.credentials` while the user signs out (`write(nil)`)
    /// tore the `TPPCredentials` struct — the exact Crashlytics signature
    /// (`TPPKeychainCodableVariable.read:114` EXC_BAD_ACCESS). The sibling test
    /// above mixes only `write(a/b)` (overwrite); this one drives the
    /// sign-out **`write(nil)`** clear concurrently with reads — the precise
    /// race that crashed — and asserts every `read()` observes a *whole*
    /// credential or `nil`, never a torn struct. With the read serialized
    /// inside `transaction.perform` (#1050) the nil-clear and the read can
    /// never interleave; a revert to the unsynchronized post-lock
    /// `return cachedValue` tears (and crashes on retain).
    func testRead_racingSignOutWriteNil_neverTearsCredentials() throws {
        try KeychainAvailability.skipIfUnavailable()

        struct Cred: Codable, Equatable, Hashable {
            let token: String
            let identifier: String
        }
        let key = "signout_cred_\(UUID().uuidString)"
        let variable = TPPKeychainCodableVariable<Cred>(key: key, accountInfoQueue: testQueue)
        defer { TPPKeychain.shared.removeObject(forKey: key) }

        let signedIn = Cred(token: "TOKEN-WHOLE-VALUE", identifier: "patron-0001")
        variable.write(signedIn)

        // Interleave: sign-in writes, sign-out clears (write(nil)), cache
        // invalidations (force a fresh keychain decode), and reads. A read may
        // legitimately observe `nil` (after a clear) or the whole credential —
        // but NEVER a partially-written / torn struct.
        DispatchQueue.concurrentPerform(iterations: 6_000) { i in
            switch i % 4 {
            case 0:
                variable.write(signedIn)        // sign-in
            case 1:
                variable.write(nil)             // sign-out — the 0bbbd8fe write
            case 2:
                variable.invalidateCache()      // force fresh decode under contention
            default:
                let got = variable.read()
                if let got {
                    XCTAssertEqual(got, signedIn,
                                   "read() returned a torn credential during sign-out: \(got)")
                }
            }
        }

        let final = variable.read()
        XCTAssertTrue(final == signedIn || final == nil,
                      "final credential must be whole or cleared, got: \(String(describing: final))")
    }
}
