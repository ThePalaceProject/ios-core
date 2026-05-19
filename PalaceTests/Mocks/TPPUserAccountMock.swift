//
//  TPPUserAccountMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPUserAccountMock: TPPUserAccount {
    /// Test-only fixed library UUID. Per-library isolation semantics are
    /// exercised separately via `TPPMultiLibraryAccountMock` /
    /// `TPPPerAccountIsolationTests`; here a single shared instance is fine.
    static let testLibraryUUID = "test-library-mock"

    private static var shared = TPPUserAccountMock(libraryUUID: testLibraryUUID)

    /// Tests that call `TPPUserAccountMock.sharedAccount(libraryUUID:)` get
    /// the fixed shared mock regardless of UUID — preserves the old behaviour.
    /// Parent method is deprecated but still present as a thin delegate.
    override class func sharedAccount(libraryUUID: String?) -> TPPUserAccount {
        return shared
    }

    /// Convenience init used by older tests that assumed the legacy no-arg
    /// singleton init on `TPPUserAccount`. Delegates to the real per-account
    /// initializer with a fixed test UUID.
    convenience init() {
        self.init(libraryUUID: TPPUserAccountMock.testLibraryUUID)
    }

    // MARK: - Variable redefinitions to avoid keychain

    var _authDefinition: AccountDetails.Authentication?
    override var authDefinition: AccountDetails.Authentication? {
        get {
            return _authDefinition
        }
        set {
            _authDefinition = newValue
        }
    }

    var _credentials: TPPCredentials?
    override var credentials: TPPCredentials? {
        get {
            return _credentials
        }
        set {
            _credentials = newValue
        }
    }

    private var _authorizationIdentifier: String?
    override var authorizationIdentifier: String? {
        return _authorizationIdentifier
    }
    override func setAuthorizationIdentifier(_ identifier: String) {
        _authorizationIdentifier = identifier
    }

    private var _deviceID: String?
    override var deviceID: String? {
        return _deviceID
    }
    override func setDeviceID(_ newValue: String) {
        _deviceID = newValue
    }

    private var _userID: String?
    override var userID: String? {
        return _userID
    }
    override func setUserID(_ newValue: String) {
        _userID = newValue
    }

    private var _adobeVendor: String?
    override var adobeVendor: String? {
        return _adobeVendor
    }
    override func setAdobeVendor(_ newValue: String) {
        _adobeVendor = newValue
    }

    private var _provider: String?
    override var provider: String? {
        return _provider
    }
    override func setProvider(_ newValue: String) {
        _provider = newValue
    }

    private var _patron: [String: Any]?
    override var patron: [String: Any]? {
        return _patron
    }
    override func setPatron(_ newValue: [String: Any]) {
        _patron = newValue
    }

    private var _adobeToken: String?
    override var adobeToken: String? {
        return _adobeToken
    }
    override func setAdobeToken(_ newValue: String) {
        _adobeToken = newValue
    }
    override func setAdobeToken(_ token: String, patron: [String: Any]) {
        _adobeToken = token
        _patron = patron
    }

    private var _licensor: [String: Any]?
    override var licensor: [String: Any]? {
        return _licensor
    }
    override func setLicensor(_ newValue: [String: Any]) {
        _licensor = newValue
    }

    private var _cookies: [HTTPCookie]?
    override var cookies: [HTTPCookie]? {
        return _cookies
    }
    override func setCookies(_ newValue: [HTTPCookie]) {
        _cookies = newValue
    }

    override var legacyAuthToken: String? {
        return nil
    }

    private var _authToken: String?
    override var authToken: String? {
        return _authToken
    }

    override func setAuthToken(_ token: String, barcode: String?, pin: String?, expirationDate: Date?) {
        _authToken = token
        _credentials = .token(authToken: token, barcode: barcode, pin: pin, expirationDate: expirationDate)
        // Mirror real TPPUserAccount.setAuthToken: a fresh token clears any
        // persisted .credentialsStale flag.
        _authState = .loggedIn
    }

    // MARK: - Auth State

    private var _authState: TPPAccountAuthState = .loggedOut
    override var authState: TPPAccountAuthState {
        // If we have credentials but state is loggedOut, derive loggedIn state
        if _authState == .loggedOut && hasCredentials() {
            return .loggedIn
        }
        return _authState
    }

    override func setAuthState(_ state: TPPAccountAuthState) {
        _authState = state
    }

    override func markCredentialsStale() {
        guard authState == .loggedIn else { return }
        _authState = .credentialsStale
    }

    override func markLoggedIn() {
        _authState = .loggedIn
    }

    override class func credentialSnapshot(for libraryUUID: String?) -> CredentialSnapshot {
        let mock = shared
        let creds = mock._credentials
        let hasCreds = mock.hasCredentials()
        let hasToken: Bool
        if let creds = creds, case .token = creds {
            hasToken = true
        } else {
            hasToken = false
        }

        let state: TPPAccountAuthState = mock._authState

        var barcode: String?
        var pin: String?
        if let creds = creds {
            switch creds {
            case let .barcodeAndPin(barcode: b, pin: p):
                barcode = b
                pin = p
            case let .token(_, barcode: b, pin: p, _):
                barcode = b
                pin = p
            default:
                break
            }
        }

        var authToken: String?
        if let creds = creds, case let .token(token, _, _, _) = creds {
            authToken = token
        }

        return CredentialSnapshot(
            hasCredentials: hasCreds,
            hasAuthToken: hasToken,
            authState: state,
            barcode: barcode,
            pin: pin,
            authToken: authToken,
            authDefinition: mock.authDefinition,
            cookies: nil
        )
    }

    var atomicUpdateCallCount = 0
    var atomicUpdateLibraryUUIDs: [String?] = []

    override func atomicUpdate(for libraryUUID: String?,
                                _ block: (TPPUserAccount) -> Void) {
        atomicUpdateCallCount += 1
        atomicUpdateLibraryUUIDs.append(libraryUUID)
        block(self)
    }

    /// Resets the shared singleton to a fresh, fully-cleared instance.
    ///
    /// Call this in every test's `setUpWithError`. The fresh instance has all
    /// underscore-backed storage at its initial nil/empty values, AND we
    /// defensively call `removeAll()` to handle the case where a prior test
    /// left state on the old `shared` reference that an in-flight async
    /// observer is still mutating (which would race with a new instance
    /// being assigned to `shared`). The redundant clear is intentional —
    /// belt-and-suspenders against the F-008 pollution class.
    ///
    /// F-008 (TPPSignInBusinessLogicExtendedTests.testRegistrationIs
    /// Possible_notSignedInAndLibraryHasSignUpUrl_returnsTrue) hit this
    /// vector: precondition `XCTAssertFalse(isSignedIn())` passed but the
    /// production check `isSignedIn()` inside `registrationIsPossible()`
    /// then returned true — credentials had appeared on the shared mock
    /// between the two calls. Tests that need guaranteed-clean credentials
    /// also call `businessLogic.userAccount.removeAll()` at the top of the
    /// test body as defense-in-depth.
    static func resetShared() {
        shared = TPPUserAccountMock(libraryUUID: testLibraryUUID)
        shared.removeAll()
    }

    // MARK: - Clean everything up

    override func removeAll() {
        _adobeToken = nil
        _patron = nil
        _adobeVendor = nil
        _provider = nil
        _userID = nil
        _deviceID = nil
        _authDefinition = nil
        _authToken = nil
        _credentials = nil
        _cookies = nil
        _authorizationIdentifier = nil
        _authState = .loggedOut
        signInGeneration = 0
    }
}
