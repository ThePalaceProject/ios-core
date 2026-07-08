//
//  TPPReauthenticator.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/18/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceLogging

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
    internal private(set) var authenticateCallCount: Int = 0

    /// Test-only override for the `AppContainer` from which the
    /// `signInModalSheetPresenter` is resolved. Production reads through
    /// `AppContainer.production()`; tests set this to a container built
    /// via Module B's `withSignInModalSheetPresenter(_:)` modifier so a
    /// spy presenter can be injected.
    ///
    /// **Scope:** the override is only consulted when XCTest is the host
    /// process (`XCTestConfigurationFilePath` env var is set). In every
    /// other build — sim runs, dev TestFlight, App Store — the override
    /// is structurally ignored, so the seam cannot leak into user-visible
    /// reauthentication paths even if a developer accidentally writes to
    /// it from non-test code.
    ///
    /// swarm_d8f11437 Module A wave 4 — closes wall-failure cs_9a267b63
    /// (architect rev_bc20951b). Without this seam, the wiring test
    /// `testReauth_TPPReauthenticator_authenticateIfNeeded_drivesSpyPresenterViaAppContainerSeam`
    /// cannot drive a spy presenter through the production
    /// `authenticateIfNeeded` path.
    ///
    /// MUST be reset to nil in test teardown to avoid bleed between tests.
    @MainActor
    internal static var _testContainerOverride: AppContainer?

    /// Tightens `#if DEBUG` to unit-test-only by checking for the XCTest
    /// configuration env var. DEBUG also covers sim runs / dev TestFlight,
    /// where a leaked override would silently re-route production reauth.
    @MainActor
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

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

            // swarm_18b0d071 Module A wave 3 — proof-of-pattern migration
            // from the static `SignInModalPresenter` API to the
            // SwiftUI-observable `SignInModalSheetPresenter` facade.
            // swarm_d8f11437 Module A wave 4 — completes the migration
            // for the remaining 9 call sites; the test-only
            // `_testContainerOverride` seam is consulted ONLY when running
            // under XCTest (not in dev/sim/TestFlight builds), so the
            // override cannot leak into user-visible reauthentication.
            let container = TPPReauthenticator.isRunningUnderXCTest
                ? (TPPReauthenticator._testContainerOverride ?? AppContainer.production())
                : AppContainer.production()
            let presenter = container.signInModalSheetPresenter
            presenter.presentSignInModalForCurrentAccount {
                Log.info(#file, "TPPReauthenticator: Re-authentication completed")
                authenticationCompletion?()
            }
        }
    }
}
