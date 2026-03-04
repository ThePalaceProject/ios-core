//
//  TPPKeychainStoredVariableTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPKeychainStoredVariableTests: XCTestCase {

    private let testQueue = DispatchQueue(label: "test.keychain.queue")
    private let testKey = "test_keychain_var_\(UUID().uuidString)"

    override func tearDown() {
        // Clean up test keychain entries
        TPPKeychain.shared()?.removeObject(forKey: testKey)
        super.tearDown()
    }

    // MARK: - Initialization

    func testInit_setsKey() {
        let variable = TPPKeychainVariable<String>(key: testKey, accountInfoQueue: testQueue)
        XCTAssertEqual(variable.key, testKey)
    }

    // MARK: - Read/Write String

    func testWrite_andRead_string() {
        let variable = TPPKeychainVariable<String>(key: testKey, accountInfoQueue: testQueue)

        variable.write("test-value")
        let result = variable.read()

        XCTAssertEqual(result, "test-value")
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
        TPPKeychain.shared()?.removeObject(forKey: newKey)
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

        TPPKeychain.shared()?.removeObject(forKey: uniqueKey)
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
}
