//
//  TPPReauthenticatorTests.swift
//  PalaceTests
//
//  Tests for reauthentication handling
//

import XCTest
@testable import Palace

/// Note: TPPReauthenticator requires UI presentation (SignInModalPresenter) which cannot
/// be tested in unit tests. Use TPPReauthenticatorMockTests for testing reauthentication logic.
final class TPPReauthenticatorTests: XCTestCase {

    // MARK: - Properties

    private var reauthenticator: TPPReauthenticator!
    private var userAccount: TPPUserAccountMock!

    // MARK: - Setup/Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        reauthenticator = TPPReauthenticator()
        userAccount = TPPUserAccountMock()
    }

    override func tearDownWithError() throws {
        reauthenticator = nil
        userAccount = nil
        try super.tearDownWithError()
    }

    // MARK: - Initialization Tests

    func testInit_createsDistinctInstances() {
        // The type is not a singleton — each init must produce a distinct object
        let second = TPPReauthenticator()
        XCTAssertFalse(reauthenticator === second,
                       "Two TPPReauthenticator instances must be distinct objects")
    }

    func testInit_isNSObjectSubclass() {
        XCTAssertTrue(reauthenticator is NSObject)
        // Objective-C interoperability: must also respond to basic NSObject messages
        XCTAssertNotNil(reauthenticator.description,
                        "NSObject subclass must provide a non-nil description")
    }

    func testInit_conformsToReauthenticatorProtocol() {
        XCTAssertTrue(reauthenticator is Reauthenticator)
        // Verify through protocol type rather than concrete type
        let asProtocol: Reauthenticator? = reauthenticator as? Reauthenticator
        XCTAssertNotNil(asProtocol,
                        "TPPReauthenticator must be castable to the Reauthenticator protocol")
    }

    func testAuthenticateIfNeeded_withNilCompletion_doesNotCrash() {
        // Should not crash when completion is nil
        // Note: This triggers UI presentation which won't complete in tests
        reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true, authenticationCompletion: nil)
        // Calling a second time with nil must also not crash (no stale state)
        reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false, authenticationCompletion: nil)
        XCTAssertNotNil(reauthenticator,
                        "Reauthenticator must remain valid after authenticateIfNeeded calls")
    }
}

// MARK: - Mock Reauthenticator Tests

final class TPPReauthenticatorMockTests: XCTestCase {

    private var mockReauthenticator: TPPReauthenticatorMock!
    private var userAccount: TPPUserAccountMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        mockReauthenticator = TPPReauthenticatorMock()
        userAccount = TPPUserAccountMock()
    }

    override func tearDownWithError() throws {
        mockReauthenticator = nil
        userAccount = nil
        try super.tearDownWithError()
    }

    func testMockReauthenticator_tracksReauthPerformed() {
        XCTAssertFalse(mockReauthenticator.authenticateIfNeededCalled)

        mockReauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true, authenticationCompletion: nil)

        XCTAssertTrue(mockReauthenticator.authenticateIfNeededCalled)
    }

    func testMockReauthenticator_callsCompletion() {
        var completionCallCount = 0
        mockReauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true) {
            completionCallCount += 1
        }
        // The mock must call the completion (unlike the real implementation which needs UI)
        XCTAssertEqual(completionCallCount, 1,
                       "Mock reauthenticator must call the completion exactly once")
        XCTAssertTrue(mockReauthenticator.authenticateIfNeededCalled,
                      "authenticateIfNeededCalled flag must be set after completion")
    }
}
