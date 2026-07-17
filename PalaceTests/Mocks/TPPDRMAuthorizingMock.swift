//
//  TPPDRMAuthorizingMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

/// `@unchecked Sendable`: `TPPDRMAuthorizing` completions are `@Sendable`, so this
/// mock is captured across concurrency domains in concurrent DRM tests. It HONORS
/// that contract: every mutable stored property is guarded by a single `NSLock`
/// (mirroring `TPPBookRegistryMock`). `let` constants and computed accessors are
/// inherently thread-safe and are left unguarded.
class TPPDRMAuthorizingMock: NSObject, TPPDRMAuthorizing, @unchecked Sendable {

    private let lock = NSLock()

    private var _workflowsInProgress = false
    var workflowsInProgress: Bool {
        get { lock.withLock { _workflowsInProgress } }
        set { lock.withLock { _workflowsInProgress = newValue } }
    }

    let deviceID = "drmDeviceID"
    let userID = "drmUserID"

    // MARK: - Configurable Test Properties

    /// Controls what `isUserAuthorized` returns. Default is `true`.
    private var _isUserAuthorizedReturnValue = true
    var isUserAuthorizedReturnValue: Bool {
        get { lock.withLock { _isUserAuthorizedReturnValue } }
        set { lock.withLock { _isUserAuthorizedReturnValue = newValue } }
    }

    /// Tracks whether `authorize` was called.
    private var _authorizeWasCalled = false
    var authorizeWasCalled: Bool {
        get { lock.withLock { _authorizeWasCalled } }
        set { lock.withLock { _authorizeWasCalled = newValue } }
    }

    /// Counts how many times `authorize` was called.
    private var _authorizeCallCount = 0
    var authorizeCallCount: Int {
        get { lock.withLock { _authorizeCallCount } }
        set { lock.withLock { _authorizeCallCount = newValue } }
    }

    /// Tracks whether `deauthorize` was called.
    private var _deauthorizeWasCalled = false
    var deauthorizeWasCalled: Bool {
        get { lock.withLock { _deauthorizeWasCalled } }
        set { lock.withLock { _deauthorizeWasCalled = newValue } }
    }

    /// Counts how many times `deauthorize` was called.
    private var _deauthorizeCallCount = 0
    var deauthorizeCallCount: Int {
        get { lock.withLock { _deauthorizeCallCount } }
        set { lock.withLock { _deauthorizeCallCount = newValue } }
    }

    /// When true, `deauthorize` captures the completion instead of calling it
    /// immediately. Call `completeDeferredDeauthorize()` to fire the callback.
    private var _shouldDeferDeauthorize = false
    var shouldDeferDeauthorize: Bool {
        get { lock.withLock { _shouldDeferDeauthorize } }
        set { lock.withLock { _shouldDeferDeauthorize = newValue } }
    }

    /// Captured deauthorization completion for simulating slow DRM callbacks.
    private var _deferredDeauthCompletion: ((Bool, Error?) -> Void)?
    private(set) var deferredDeauthCompletion: ((Bool, Error?) -> Void)? {
        get { lock.withLock { _deferredDeauthCompletion } }
        set { lock.withLock { _deferredDeauthCompletion = newValue } }
    }

    func isUserAuthorized(_ userID: String!, withDevice device: String!) -> Bool {
        return isUserAuthorizedReturnValue
    }

    func authorize(withVendorID vendorID: String!, username: String!, password: String!, completion: (@Sendable (Bool, Error?, String?, String?) -> Void)!) {
        authorizeWasCalled = true
        authorizeCallCount += 1
        completion(true, nil, deviceID, userID)
    }

    func deauthorize(withUsername username: String!, password: String!, userID: String!, deviceID: String!, completion: (@Sendable (Bool, Error?) -> Void)!) {
        deauthorizeWasCalled = true
        deauthorizeCallCount += 1
        if shouldDeferDeauthorize {
            deferredDeauthCompletion = completion
        } else {
            completion(true, nil)
        }
    }

    /// Fires the previously captured deauthorization completion.
    func completeDeferredDeauthorize(success: Bool = true, error: Error? = nil) {
        deferredDeauthCompletion?(success, error)
        deferredDeauthCompletion = nil
    }

    /// Resets all tracking properties. Call in test tearDown.
    func reset() {
        isUserAuthorizedReturnValue = true
        authorizeWasCalled = false
        authorizeCallCount = 0
        deauthorizeWasCalled = false
        deauthorizeCallCount = 0
        shouldDeferDeauthorize = false
        deferredDeauthCompletion = nil
    }
}
