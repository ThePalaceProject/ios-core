//
//  TriageBotKeyAdminTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TriageBotKeyAdminTests: XCTestCase {

    /// In-memory stand-in for `AnthropicKeyStore` so the admin logic is tested
    /// without the real Keychain (errSecMissingEntitlement in the unit host).
    private final class SpyStore: AnthropicKeyStoring {
        var stored: String?
        private(set) var writeArgs: [String] = []
        private(set) var deleteCount = 0

        func read() -> String? { stored }

        @discardableResult
        func write(_ key: String) -> Bool {
            writeArgs.append(key)
            stored = key
            return true
        }

        @discardableResult
        func delete() -> Bool {
            deleteCount += 1
            let had = stored != nil
            stored = nil
            return had
        }
    }

    func testSave_trimsSurroundingWhitespace_beforeStoring() {
        let spy = SpyStore()
        let admin = TriageBotKeyAdmin(store: spy)

        let didSave = admin.save("  sk-ant-abc123  \n")

        XCTAssertTrue(didSave, "a non-empty key must be saved")
        XCTAssertEqual(spy.writeArgs, ["sk-ant-abc123"],
                       "save must trim surrounding whitespace/newlines before storing")
    }

    func testSave_whitespaceOnly_isRejected_andLeavesExistingKeyIntact() {
        let spy = SpyStore()
        spy.stored = "existing-key"
        let admin = TriageBotKeyAdmin(store: spy)

        let didSave = admin.save("   \n\t ")

        XCTAssertFalse(didSave, "a whitespace-only paste must not be stored")
        XCTAssertTrue(spy.writeArgs.isEmpty, "no write may be issued for an empty paste")
        XCTAssertEqual(spy.stored, "existing-key",
                       "rejecting an empty paste must not clobber the existing key")
    }

    func testHasStoredKey_isFalseForNilOrEmpty_trueForNonEmpty() {
        let spy = SpyStore()
        let admin = TriageBotKeyAdmin(store: spy)

        XCTAssertFalse(admin.hasStoredKey, "no key stored → false")

        spy.stored = ""
        XCTAssertFalse(admin.hasStoredKey, "empty-string key → false (treated as no key)")

        spy.stored = "sk-ant-xyz"
        XCTAssertTrue(admin.hasStoredKey, "non-empty key → true")
    }

    func testClear_deletesTheStoredKey() {
        let spy = SpyStore()
        spy.stored = "sk-ant-xyz"
        let admin = TriageBotKeyAdmin(store: spy)

        let didClear = admin.clear()

        XCTAssertTrue(didClear, "clear must report it removed a present key")
        XCTAssertEqual(spy.deleteCount, 1, "clear must call the store's delete exactly once")
        XCTAssertNil(spy.stored, "clear must remove the key from the store")
    }
}
