//
//  TPPUserAccountMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

/// `@unchecked Sendable`: production `TPPUserAccount` is lock-backed
/// (controlLock, 5a32a8cd2) and consumers may touch accounts across
/// concurrency domains — `TPPCredentialConcurrencyTests` drives this mock
/// from 50–100 concurrent threads. The mock HONORS that contract: all
/// underscore-backed override storage is guarded by a single `mockLock`
/// (segv-class fix, follow-up to wall entry 2026-07-05-sync-mock-race.md;
/// same recipe as `TPPBookRegistryMock`).
///
/// Locking rules (mirror of the TPPBookRegistryMock review):
/// - Public members take `mockLock` EXACTLY ONCE; no public member calls
///   another public/overridable member (or `super`) while holding it —
///   production getters route through OVERRIDDEN accessors
///   (`hasCredentials()` → `credentials`), so re-entering would deadlock.
///   Derivations use pure helpers on locked SNAPSHOTS instead
///   (`UserAccountAuthHelper.hasCredentials(_:)`).
/// - Production-locked members (`signInGeneration` → controlLock) are only
///   touched OUTSIDE `mockLock` — nesting stays one-directional
///   (production → mock via overridden getters), so no lock-order inversion.
/// - The mutable `shared` singleton is guarded by `sharedLock` (the F-008
///   in-flight-observer race on `resetShared` was previously unsynchronized).
/// - `atomicUpdate` records its call under the lock but runs the block
///   OUTSIDE it (each setter the block calls locks individually). This is
///   weaker than production's whole-block atomicity — acceptable for the
///   mock because tests assert call-recording, not cross-field invariants;
///   documented here so nobody assumes otherwise.
class TPPUserAccountMock: TPPUserAccount, @unchecked Sendable {
    /// Test-only fixed library UUID. Per-library isolation semantics are
    /// exercised separately via `TPPMultiLibraryAccountMock` /
    /// `TPPPerAccountIsolationTests`; here a single shared instance is fine.
    static let testLibraryUUID = "test-library-mock"

    private let mockLock = NSLock()

    /// Counts `removeAll()` invocations so reset tests can assert this
    /// library's credentials were cleared.
    private var _removeAllCallCount = 0
    private(set) var removeAllCallCount: Int {
        get { mockLock.withLock { _removeAllCallCount } }
        set { mockLock.withLock { _removeAllCallCount = newValue } }
    }

    // Swift 6: a mutable `static var` is rejected even when lock-guarded via a
    // computed wrapper (the underlying storage is still global mutable state).
    // Hold it in a LockIsolated box (immutable `static let` binding) instead.
    private static let _shared = LockIsolated<TPPUserAccountMock>(
        TPPUserAccountMock(libraryUUID: testLibraryUUID))
    private static var shared: TPPUserAccountMock {
        get { _shared.value }
        set { _shared.value = newValue }
    }

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

    private var __authDefinition: AccountDetails.Authentication?
    var _authDefinition: AccountDetails.Authentication? {
        get { mockLock.withLock { __authDefinition } }
        set { mockLock.withLock { __authDefinition = newValue } }
    }
    override var authDefinition: AccountDetails.Authentication? {
        get { _authDefinition }
        set { _authDefinition = newValue }
    }

    private var __credentials: TPPCredentials?
    var _credentials: TPPCredentials? {
        get { mockLock.withLock { __credentials } }
        set { mockLock.withLock { __credentials = newValue } }
    }
    override var credentials: TPPCredentials? {
        get { _credentials }
        set { _credentials = newValue }
    }

    private var _authorizationIdentifier: String?
    override var authorizationIdentifier: String? {
        mockLock.withLock { _authorizationIdentifier }
    }
    override func setAuthorizationIdentifier(_ identifier: String) {
        mockLock.withLock { _authorizationIdentifier = identifier }
    }

    private var _deviceID: String?
    override var deviceID: String? {
        mockLock.withLock { _deviceID }
    }
    override func setDeviceID(_ newValue: String) {
        mockLock.withLock { _deviceID = newValue }
    }

    private var _userID: String?
    override var userID: String? {
        mockLock.withLock { _userID }
    }
    override func setUserID(_ newValue: String) {
        mockLock.withLock { _userID = newValue }
    }

    private var _adobeVendor: String?
    override var adobeVendor: String? {
        mockLock.withLock { _adobeVendor }
    }
    override func setAdobeVendor(_ newValue: String) {
        mockLock.withLock { _adobeVendor = newValue }
    }

    private var _provider: String?
    override var provider: String? {
        mockLock.withLock { _provider }
    }
    override func setProvider(_ newValue: String) {
        mockLock.withLock { _provider = newValue }
    }

    private var _patron: [String: Any]?
    override var patron: [String: Any]? {
        mockLock.withLock { _patron }
    }
    override func setPatron(_ newValue: [String: Any]) {
        mockLock.withLock { _patron = newValue }
    }

    private var _adobeToken: String?
    override var adobeToken: String? {
        mockLock.withLock { _adobeToken }
    }
    override func setAdobeToken(_ newValue: String) {
        mockLock.withLock { _adobeToken = newValue }
    }
    override func setAdobeToken(_ token: String, patron: [String: Any]) {
        mockLock.withLock {
            _adobeToken = token
            _patron = patron
        }
    }

    private var _licensor: [String: Any]?
    override var licensor: [String: Any]? {
        mockLock.withLock { _licensor }
    }
    override func setLicensor(_ newValue: [String: Any]) {
        mockLock.withLock { _licensor = newValue }
    }

    private var _cookies: [HTTPCookie]?
    override var cookies: [HTTPCookie]? {
        mockLock.withLock { _cookies }
    }
    override func setCookies(_ newValue: [HTTPCookie]) {
        mockLock.withLock { _cookies = newValue }
    }

    override var legacyAuthToken: String? {
        return nil
    }

    private var _authToken: String?
    override var authToken: String? {
        mockLock.withLock { _authToken }
    }

    override func setAuthToken(_ token: String, barcode: String?, pin: String?, expirationDate: Date?) {
        mockLock.withLock {
            _authToken = token
            __credentials = .token(authToken: token, barcode: barcode, pin: pin, expirationDate: expirationDate)
            // Mirror real TPPUserAccount.setAuthToken: a fresh token clears any
            // persisted .credentialsStale flag.
            _authState = .loggedIn
        }
    }

    // MARK: - Auth State

    private var _authState: TPPAccountAuthState = .loggedOut
    override var authState: TPPAccountAuthState {
        // If we have credentials but state is loggedOut, derive loggedIn
        // state. The derivation uses the PURE helper on a locked snapshot —
        // calling self.hasCredentials() here would re-enter mockLock via the
        // overridden `credentials` getter.
        let (state, creds) = mockLock.withLock { (_authState, __credentials) }
        if state == .loggedOut && UserAccountAuthHelper.hasCredentials(creds) {
            return .loggedIn
        }
        return state
    }

    override func setAuthState(_ state: TPPAccountAuthState) {
        mockLock.withLock { _authState = state }
    }

    override func markCredentialsStale() {
        // Atomic derive-and-write: the guard and the transition happen under
        // ONE lock acquisition (a read-then-write through the public members
        // would TOCTOU-race concurrent markLoggedIn/setAuthToken calls).
        mockLock.withLock {
            let derived: TPPAccountAuthState =
                (_authState == .loggedOut && UserAccountAuthHelper.hasCredentials(__credentials))
                ? .loggedIn : _authState
            guard derived == .loggedIn else { return }
            _authState = .credentialsStale
        }
    }

    override func markLoggedIn() {
        mockLock.withLock { _authState = .loggedIn }
    }

    override class func credentialSnapshot(for libraryUUID: String?) -> CredentialSnapshot {
        let mock = shared
        // One lock acquisition for a CONSISTENT snapshot; all derivation on
        // the snapshot afterwards (helpers are pure).
        let (creds, state, authDef) = mock.mockLock.withLock {
            (mock.__credentials, mock._authState, mock.__authDefinition)
        }
        let hasCreds = UserAccountAuthHelper.hasCredentials(creds)
        let hasToken: Bool
        if let creds = creds, case .token = creds {
            hasToken = true
        } else {
            hasToken = false
        }

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
            authDefinition: authDef,
            cookies: nil
        )
    }

    private var _atomicUpdateCallCount = 0
    var atomicUpdateCallCount: Int {
        get { mockLock.withLock { _atomicUpdateCallCount } }
        set { mockLock.withLock { _atomicUpdateCallCount = newValue } }
    }
    private var _atomicUpdateLibraryUUIDs: [String?] = []
    var atomicUpdateLibraryUUIDs: [String?] {
        get { mockLock.withLock { _atomicUpdateLibraryUUIDs } }
        set { mockLock.withLock { _atomicUpdateLibraryUUIDs = newValue } }
    }

    override func atomicUpdate(for libraryUUID: String?,
                                _ block: (TPPUserAccount) -> Void) {
        mockLock.withLock {
            _atomicUpdateCallCount += 1
            _atomicUpdateLibraryUUIDs.append(libraryUUID)
        }
        // Block runs OUTSIDE the lock: it calls back into this mock's locked
        // setters, and holding mockLock across it would self-deadlock. See
        // the class doc for the (documented) weaker-than-production
        // atomicity this implies.
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
        let fresh = TPPUserAccountMock(libraryUUID: testLibraryUUID)
        shared = fresh
        fresh.removeAll()
    }

    // MARK: - Clean everything up

    override func removeAll() {
        mockLock.withLock {
            _removeAllCallCount += 1
            _adobeToken = nil
            _patron = nil
            _adobeVendor = nil
            _provider = nil
            _userID = nil
            _deviceID = nil
            __authDefinition = nil
            _authToken = nil
            __credentials = nil
            _cookies = nil
            _authorizationIdentifier = nil
            _authState = .loggedOut
        }
        // Production-locked member (controlLock) — touched OUTSIDE mockLock
        // so lock nesting stays one-directional (see class doc).
        signInGeneration = 0
    }
}
