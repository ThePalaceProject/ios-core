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
    private var account: Account!

    override func setUpWithError() throws {
        try super.setUpWithError()
        usernameField = UITextField()
        pinField = UITextField()
        inputProvider = MockInputProvider()
        inputProvider.usernameTextField = usernameField
        inputProvider.PINTextField = pinField
        account = TPPLibraryAccountMock().tppAccount
    }

    override func tearDown() {
        usernameField = nil
        pinField = nil
        inputProvider = nil
        account = nil
        super.tearDown()
    }

    // MARK: - ASCII Enforcement

    func testRejectsNonASCIICharacters() {
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: nil,
            inputProvider: inputProvider
        )

        let result = validation.textField(
            usernameField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "\u{00E9}" // e with acute accent
        )
        XCTAssertFalse(result, "Non-ASCII characters should be rejected")
    }

    func testAcceptsASCIICharacters() {
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
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: nil,
            inputProvider: inputProvider
        )

        // With nil businessLogic, hasBarcodeAndPIN defaults to false, so editing is allowed
        let result = validation.textFieldShouldBeginEditing(usernameField)
        XCTAssertTrue(result)
    }

    // MARK: - Username 25-character limit

    func testRejectsUsernameLongerThan25Characters() {
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: nil,
            inputProvider: inputProvider
        )
        usernameField.text = String(repeating: "a", count: 25)

        let result = validation.textField(
            usernameField,
            shouldChangeCharactersIn: NSRange(location: 25, length: 0),
            replacementString: "b"
        )
        XCTAssertFalse(result, "Adding a 26th character to a 25-char username must be rejected")
    }

    func testAcceptsUsernameAtExactly25Characters() {
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: nil,
            inputProvider: inputProvider
        )
        usernameField.text = String(repeating: "a", count: 24)

        let result = validation.textField(
            usernameField,
            shouldChangeCharactersIn: NSRange(location: 24, length: 0),
            replacementString: "b"
        )
        XCTAssertTrue(result, "25-character usernames must be accepted")
    }

    func testRejectsUsernameRangeOutsideTextBounds() {
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: nil,
            inputProvider: inputProvider
        )
        usernameField.text = "abc"

        let result = validation.textField(
            usernameField,
            shouldChangeCharactersIn: NSRange(location: 5, length: 0),
            replacementString: "x"
        )
        XCTAssertFalse(result, "Range past end of text must be rejected to avoid out-of-bounds replace")
    }

    // MARK: - PIN passcode length (with businessLogic)

    func testRejectsPINLongerThanAuthPasscodeLength() throws {
        let businessLogic = makeBusinessLogicWithBasicAuth()
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: businessLogic,
            inputProvider: inputProvider
        )
        // NYPL fixture sets passcode maximum_length = 12 for basic auth
        pinField.text = String(repeating: "1", count: 12)

        let result = validation.textField(
            pinField,
            shouldChangeCharactersIn: NSRange(location: 12, length: 0),
            replacementString: "3"
        )
        XCTAssertFalse(result, "PIN longer than auth.authPasscodeLength must be rejected")
    }

    func testAcceptsPINAtExactlyAuthPasscodeLength() throws {
        let businessLogic = makeBusinessLogicWithBasicAuth()
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: businessLogic,
            inputProvider: inputProvider
        )
        pinField.text = String(repeating: "1", count: 11)

        let result = validation.textField(
            pinField,
            shouldChangeCharactersIn: NSRange(location: 11, length: 0),
            replacementString: "3"
        )
        XCTAssertTrue(result, "PIN at exactly authPasscodeLength must be accepted")
    }

    // MARK: - shouldBeginEditing with businessLogic

    func testShouldNotBeginEditingWhenBusinessLogicHasBarcodeAndPIN() throws {
        inputProvider.forceEditability = false
        let businessLogic = makeBusinessLogicWithBasicAuth()
        businessLogic.userAccount.setBarcode("user", PIN: "1234")
        let validation = TPPUserAccountFrontEndValidation(
            account: account,
            businessLogic: businessLogic,
            inputProvider: inputProvider
        )

        let result = validation.textFieldShouldBeginEditing(usernameField)
        XCTAssertFalse(result,
                       "When credentials are already stored and forceEditability is off, fields must lock")
    }

    // MARK: - Helpers

    private func makeBusinessLogicWithBasicAuth() -> TPPSignInBusinessLogic {
        TPPUserAccountMock.resetShared()
        let libraryMock = TPPLibraryAccountMock()
        let logic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock())
        logic.selectedAuthentication = libraryMock.basicAuthentication
        return logic
    }
}
