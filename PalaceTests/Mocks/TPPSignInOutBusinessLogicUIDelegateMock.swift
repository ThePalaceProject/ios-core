//
//  TPPSignInOutBusinessLogicUIDelegateMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 2/3/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

/// `@unchecked Sendable`: this mock is shared across concurrency domains in
/// sign-in tests, so all mutable stored state is guarded by a single `NSLock`
/// via locked computed accessors — mirroring `TPPBookRegistryMock`. Property
/// names, types, and `@objc` annotations are preserved so no call site changes.
class TPPSignInOutBusinessLogicUIDelegateMock: NSObject, TPPSignInOutBusinessLogicUIDelegate, @unchecked Sendable {

    private let lock = NSLock()

    // MARK: - Call Tracking for Tests
    private var _didCallWillSignOut = false
    var didCallWillSignOut: Bool {
        get { lock.withLock { _didCallWillSignOut } }
        set { lock.withLock { _didCallWillSignOut = newValue } }
    }

    private var _didCallDidFinishDeauthorizing = false
    var didCallDidFinishDeauthorizing: Bool {
        get { lock.withLock { _didCallDidFinishDeauthorizing } }
        set { lock.withLock { _didCallDidFinishDeauthorizing = newValue } }
    }

    private var _didFinishDeauthorizingHandler: (() -> Void)?
    var didFinishDeauthorizingHandler: (() -> Void)? {
        get { lock.withLock { _didFinishDeauthorizingHandler } }
        set { lock.withLock { _didFinishDeauthorizingHandler = newValue } }
    }

    // MARK: - Sign-In Flow Tracking
    private var _didCallWillSignIn = false
    var didCallWillSignIn: Bool {
        get { lock.withLock { _didCallWillSignIn } }
        set { lock.withLock { _didCallWillSignIn = newValue } }
    }

    private var _didCallDidCompleteSignIn = false
    var didCallDidCompleteSignIn: Bool {
        get { lock.withLock { _didCallDidCompleteSignIn } }
        set { lock.withLock { _didCallDidCompleteSignIn = newValue } }
    }

    private var _didCallDidCancelSignIn = false
    var didCallDidCancelSignIn: Bool {
        get { lock.withLock { _didCallDidCancelSignIn } }
        set { lock.withLock { _didCallDidCancelSignIn = newValue } }
    }

    private var _didCallDidReceiveCredentials = false
    var didCallDidReceiveCredentials: Bool {
        get { lock.withLock { _didCallDidReceiveCredentials } }
        set { lock.withLock { _didCallDidReceiveCredentials = newValue } }
    }

    private var _willSignInCallCount = 0
    var willSignInCallCount: Int {
        get { lock.withLock { _willSignInCallCount } }
        set { lock.withLock { _willSignInCallCount = newValue } }
    }

    private var _didCompleteSignInCallCount = 0
    var didCompleteSignInCallCount: Int {
        get { lock.withLock { _didCompleteSignInCallCount } }
        set { lock.withLock { _didCompleteSignInCallCount = newValue } }
    }

    private var _didReceiveCredentialsCallCount = 0
    var didReceiveCredentialsCallCount: Int {
        get { lock.withLock { _didReceiveCredentialsCallCount } }
        set { lock.withLock { _didReceiveCredentialsCallCount = newValue } }
    }

    private var _didCompleteSignInHandler: (() -> Void)?
    var didCompleteSignInHandler: (() -> Void)? {
        get { lock.withLock { _didCompleteSignInHandler } }
        set { lock.withLock { _didCompleteSignInHandler = newValue } }
    }

    // Track isLoading state transitions
    private var _isLoading = false
    var isLoading: Bool {
        get { lock.withLock { _isLoading } }
        set { lock.withLock { _isLoading = newValue } }
    }

    private var _loadingStateChanges: [Bool] = []
    var loadingStateChanges: [Bool] {
        get { lock.withLock { _loadingStateChanges } }
        set { lock.withLock { _loadingStateChanges = newValue } }
    }

    func businessLogicWillSignOut(_ businessLogic: TPPSignInBusinessLogic) {
        didCallWillSignOut = true
    }

    // MARK: - Sign-Out Error Tracking
    private var _didCallSignOutError = false
    var didCallSignOutError: Bool {
        get { lock.withLock { _didCallSignOutError } }
        set { lock.withLock { _didCallSignOutError = newValue } }
    }

    private var _signOutErrorCallCount = 0
    var signOutErrorCallCount: Int {
        get { lock.withLock { _signOutErrorCallCount } }
        set { lock.withLock { _signOutErrorCallCount = newValue } }
    }

    private var _lastSignOutErrorHTTPStatusCode: Int?
    var lastSignOutErrorHTTPStatusCode: Int? {
        get { lock.withLock { _lastSignOutErrorHTTPStatusCode } }
        set { lock.withLock { _lastSignOutErrorHTTPStatusCode = newValue } }
    }

    private var _signOutErrorHandler: ((Error?, Int) -> Void)?
    var signOutErrorHandler: ((Error?, Int) -> Void)? {
        get { lock.withLock { _signOutErrorHandler } }
        set { lock.withLock { _signOutErrorHandler = newValue } }
    }

    func businessLogic(_ logic: TPPSignInBusinessLogic,
                       didEncounterSignOutError error: Error?,
                       withHTTPStatusCode httpStatusCode: Int) {
        didCallSignOutError = true
        signOutErrorCallCount += 1
        lastSignOutErrorHTTPStatusCode = httpStatusCode
        signOutErrorHandler?(error, httpStatusCode)
    }

    func businessLogicDidFinishDeauthorizing(_ logic: TPPSignInBusinessLogic) {
        didCallDidFinishDeauthorizing = true
        didFinishDeauthorizingHandler?()
    }

    func businessLogicDidCancelSignIn(_ businessLogic: TPPSignInBusinessLogic) {
        didCallDidCancelSignIn = true
        isLoading = false
        loadingStateChanges.append(false)
    }

    private var _context = "Unit Tests Context"
    var context: String {
        get { lock.withLock { _context } }
        set { lock.withLock { _context = newValue } }
    }

    func businessLogicWillSignIn(_ businessLogic: TPPSignInBusinessLogic) {
        didCallWillSignIn = true
        willSignInCallCount += 1
        isLoading = true
        loadingStateChanges.append(true)
    }

    func businessLogicDidCompleteSignIn(_ businessLogic: TPPSignInBusinessLogic) {
        didCallDidCompleteSignIn = true
        didCompleteSignInCallCount += 1
        isLoading = false
        loadingStateChanges.append(false)
        didCompleteSignInHandler?()
    }

    func businessLogicDidReceiveCredentials(_ businessLogic: TPPSignInBusinessLogic) {
        didCallDidReceiveCredentials = true
        didReceiveCredentialsCallCount += 1
        // Simulate the real behavior: keep loading true as DRM processing starts
        isLoading = true
    }

    func businessLogic(_ logic: TPPSignInBusinessLogic,
                       didEncounterValidationError error: Error?,
                       userFriendlyErrorTitle title: String?,
                       andMessage message: String?) {
    }

    func dismiss(animated flag: Bool, completion: (() -> Void)?) {
        completion?()
    }

    func present(_ viewControllerToPresent: UIViewController,
                 animated flag: Bool,
                 completion: (() -> Void)?) {
        completion?()
    }

    private var _username: String? = "username"
    var username: String? {
        get { lock.withLock { _username } }
        set { lock.withLock { _username = newValue } }
    }

    private var _pin: String? = "pin"
    var pin: String? {
        get { lock.withLock { _pin } }
        set { lock.withLock { _pin = newValue } }
    }

    private var _usernameTextField: UITextField?
    var usernameTextField: UITextField? {
        get { lock.withLock { _usernameTextField } }
        set { lock.withLock { _usernameTextField = newValue } }
    }

    private var _PINTextField: UITextField?
    var PINTextField: UITextField? {
        get { lock.withLock { _PINTextField } }
        set { lock.withLock { _PINTextField = newValue } }
    }

    private var _forceEditability: Bool = false
    var forceEditability: Bool {
        get { lock.withLock { _forceEditability } }
        set { lock.withLock { _forceEditability = newValue } }
    }
}
