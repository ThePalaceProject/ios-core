//
//  TPPReauthenticator.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/18/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

protocol Reauthenticator: NSObject {
    func authenticateIfNeeded(_ user: TPPUserAccount,
                              usingExistingCredentials: Bool,
                              authenticationCompletion: (() -> Void)?)
}

/// This class is a front-end for taking care of situations where an
/// already authenticated user somehow sees its requests fail with a 401
/// HTTP status as it the request lacked proper authentication.
///
/// This typically involves refreshing the authentication token and, depending
/// on the chosen authentication method, opening up a sign-in VC to interact
/// with the user.
///
/// This class takes care of initializing the VC's UI, its business logic,
/// opening up the VC when needed, and performing the log-in request under
/// the hood when no user input is needed.
@objc class TPPReauthenticator: NSObject, Reauthenticator {

    /// Test-observable counter of how many times `authenticateIfNeeded`
    /// has been invoked on this instance. Used by security tests to
    /// verify single-flight behavior at upstream call sites
    /// (e.g. `TokenRefreshInterceptor.isRequestingCredentials` dedupe).
    /// Not used for any production logic.
    public private(set) var authenticateCallCount: Int = 0

    /// Re-authenticates the user. This may involve presenting the sign-in
    /// modal UI or not, depending on the sign-in business logic.
    ///
    /// - Parameters:
    ///   - user: The current user.
    ///   - usingExistingCredentials: Use the existing credentials for `user`.
    ///   - authenticationCompletion: Code to run after the authentication
    ///   flow completes.
    @objc func authenticateIfNeeded(_ user: TPPUserAccount,
                                    usingExistingCredentials: Bool,
                                    authenticationCompletion: (() -> Void)?) {
        authenticateCallCount += 1
        Task { @MainActor in
            Log.info(#file, "TPPReauthenticator: Re-authentication requested, using existing credentials: \(usingExistingCredentials)")

            // Use new SwiftUI sign-in modal
            SignInModalPresenter.presentSignInModalForCurrentAccount {
                Log.info(#file, "TPPReauthenticator: Re-authentication completed")
                authenticationCompletion?()
            }
        }
    }
}
