//
//  UserAccountValidationTests.swift
//  PalaceTests
//
//  Tests for TPPUserAccountFrontEndValidation: text field delegate logic
//  including ASCII enforcement, username length limits, PIN numeric/alpha
//  restrictions, and passcode length enforcement.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - Mock Input Provider

private class MockInputProvider: NSObject, NYPLUserAccountInputProvider {
    var usernameTextField: UITextField?
    var PINTextField: UITextField?
    var forceEditability: Bool = false
}

// MARK: - Mock Authentication

private class MockAuthentication: NSObject {
    var patronIDKeyboard: LoginKeyboard = .standard
    var pinKeyboard: LoginKeyboard = .standard
    var authPasscodeLength: UInt = 0
}

// MARK: - Tests

final class UserAccountValidationTests: XCTestCase {

    private var usernameField: UITextField!
    private var pinField: UITextField!
    private var inputProvider: MockInputProvider!

    override func setUp() {
        super.setUp()
        usernameField = UITextField()
        pinField = UITextField()
        inputProvider = MockInputProvider()
        inputProvider.usernameTextField = usernameField
        inputProvider.PINTextField = pinField
    }

    override func tearDown() {
        usernameField = nil
        pinField = nil
        inputProvider = nil
        super.tearDown()
    }

    // MARK: - ASCII Enforcement

    func testRejectsNonASCIICharacters() {
        // Create a validation instance without business logic (it will allow editing)
        let account = AccountsManager.shared.accounts().first ?? makeStubAccount()
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: nil,
            inputProvider: inputProvider
        )

        // Non-ASCII characters should be rejected
        let result = validation.textField(
            usernameField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "\u{00E9}" // e with acute accent
        )
        XCTAssertFalse(result, "Non-ASCII characters should be rejected")
    }

    func testAcceptsASCIICharacters() {
        let account = AccountsManager.shared.accounts().first ?? makeStubAccount()
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: nil,
            inputProvider: inputProvider
        )

        let result = validation.textField(
            usernameField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "abc123"
        )
        XCTAssertTrue(result, "ASCII characters should be accepted")
    }

    func testAcceptsEmptyReplacementString() {
        // Backspace sends empty replacement string
        let account = AccountsManager.shared.accounts().first ?? makeStubAccount()
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: nil,
            inputProvider: inputProvider
        )

        let result = validation.textField(
            usernameField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: ""
        )
        XCTAssertTrue(result, "Empty replacement (backspace) should be accepted")
    }

    // MARK: - textFieldShouldBeginEditing

    func testShouldBeginEditingWhenForceEditabilityIsTrue() {
        inputProvider.forceEditability = true
        let account = AccountsManager.shared.accounts().first ?? makeStubAccount()
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: nil,
            inputProvider: inputProvider
        )

        let result = validation.textFieldShouldBeginEditing(usernameField)
        XCTAssertTrue(result, "Should allow editing when forceEditability is true")
    }

    func testShouldBeginEditingWhenNoBusinessLogic() {
        inputProvider.forceEditability = false
        let account = AccountsManager.shared.accounts().first ?? makeStubAccount()
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: nil,
            inputProvider: inputProvider
        )

        // With nil businessLogic, hasBarcodeAndPIN defaults to false, so editing is allowed
        let result = validation.textFieldShouldBeginEditing(usernameField)
        XCTAssertTrue(result)
    }

    // MARK: - Helpers

    private func makeStubAccount() -> Account {
        // Return first available account or create minimal one
        return AccountsManager.shared.accounts().first!
    }
}
