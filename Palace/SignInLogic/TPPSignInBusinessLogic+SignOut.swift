//
// TPPSignInBusinessLogic+SignOut.swift
// The Palace Project
//
// Created by Ettore Pasquini on 11/3/20.
// Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import WebKit
import PalaceLogging

/// Sendable carrier for the non-Sendable `() -> Void` sign-out `completion`
/// closure captured by WebKit's `@Sendable` `removeData` completion closures in
/// `performFinalSignOutCleanup` (the two `self == nil` fallback branches) and
/// `clearWebViewData`. Boxing avoids marking those `completion` params
/// `@Sendable` — whose ultimate source is `completeLogOutProcess`'s
/// `{ [weak self] in … }` closure capturing the non-Sendable
/// `TPPSignInBusinessLogic self` (see handoff §F); making `completion`
/// `@Sendable` cannot be done while the class is neither `Sendable` nor
/// `@MainActor`. INVARIANT — the boxed closure is invoked exactly once, on the
/// main queue: every `removeData` call site here runs inside a
/// `DispatchQueue.main.async` (or WebKit's main-thread completion), and each
/// sign-out path calls `completion` on exactly one terminal branch. Mirrors
/// `ForceResetCompletionBox` / `VoidWorkBox`.
private final class SignOutCompletionBox: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}

extension TPPSignInBusinessLogic {

    // MARK: - Sign-Out Race Condition Guard
    //
    // Race condition: sign-out request returns 401 (token expired after idle)
    // → DRM deauthorization starts asynchronously → user signs back in before
    // DRM callback fires → callback triggers completeLogOutProcess() which
    // clears the user's NEW credentials.
    //
    // Fix: performLogOut() captures the userAccount's signInGeneration.
    // finalizeSignIn() increments it (via cancelPendingSignOut).
    // completeLogOutProcess() checks if it changed — if so, the user
    // re-authenticated and we skip cleanup.
    //
    // The counter lives on the TPPUserAccount (shared per library) so that
    // it works across different business-logic instances for the same library,
    // while being naturally isolated per library. No global mutable state.

    /// Reference-stable sentinel type for the two associated-object keys.
    /// Swift 6 `complete` mode rejects `static var …Key = 0` (its address was
    /// used as the association key) as "nonisolated global shared mutable
    /// state." A trivial empty `final class` is `Sendable`, and
    /// `Unmanaged.passUnretained(key).toOpaque()` yields the same stable
    /// `UnsafeRawPointer` on every call — a drop-in replacement for `&intKey`
    /// that carries no mutable state. The associated *values* remain unchanged
    /// (`Int` snapshot / `Bool` in-progress flag).
    private final class AssocKey: Sendable {}
    private static let signOutSnapshotKey = AssocKey()
    private static let signOutInProgressKey = AssocKey()

    /// The signInGeneration captured when performLogOut() was called.
    private var signOutSnapshot: Int {
        get { objc_getAssociatedObject(self, Unmanaged.passUnretained(Self.signOutSnapshotKey).toOpaque()) as? Int ?? -1 }
        set { objc_setAssociatedObject(self, Unmanaged.passUnretained(Self.signOutSnapshotKey).toOpaque(), newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Guards against re-entrant performLogOut() calls. A second call while
    /// sign-out is in progress would re-set isLoading=true and potentially
    /// leave the UI stuck in a "Signing Out..." spinner.
    private var isSignOutInProgress: Bool {
        get { objc_getAssociatedObject(self, Unmanaged.passUnretained(Self.signOutInProgressKey).toOpaque()) as? Bool ?? false }
        set { objc_setAssociatedObject(self, Unmanaged.passUnretained(Self.signOutInProgressKey).toOpaque(), newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Called by finalizeSignIn() to invalidate any in-flight sign-out
    /// for this library's user account.
    func cancelPendingSignOut() {
        userAccount.incrementSignInGeneration()
    }

    // MARK: - Test seams (§10.4)
    //
    // The race-condition guard uses `objc_setAssociatedObject` /
    // `objc_getAssociatedObject` to attach `signOutSnapshot` and
    // `isSignOutInProgress` to the `TPPSignInBusinessLogic` instance.
    // That keeps the production surface clean (no stored properties on
    // an extension) but makes the snapshot value hard to observe from a
    // test across the race window. Tests that want to assert the
    // generation snapshot directly can read it via the `#if DEBUG`
    // accessors below.
    #if DEBUG
    /// The `signInGeneration` captured at the start of the current
    /// `performLogOut()` call. Returns -1 if no sign-out has run yet.
    /// Test-only — production code reads the associated-object slot
    /// directly via `signOutSnapshot`.
    @objc var signOutSnapshotForTests: Int {
        signOutSnapshot
    }

    /// Whether a sign-out is currently in flight. Useful for verifying
    /// the re-entrancy guard from a test without scheduling a deferred
    /// DRM callback. Test-only.
    @objc var isSignOutInProgressForTests: Bool {
        isSignOutInProgress
    }
    #endif

    /// Main entry point for logging a user out.
    ///
    /// - Important: Requires to be called from the main thread.
    func performLogOut() {
        guard !isSignOutInProgress else {
            Log.warn(#file, "Sign-out already in progress — ignoring re-entrant call")
            return
        }
        isSignOutInProgress = true
        signOutSnapshot = userAccount.signInGeneration

        #if FEATURE_DRM_CONNECTOR
        uiDelegate?.businessLogicWillSignOut(self)

        guard var request = self.makeRequest(for: .signOut, context: "Sign Out") else {
            Log.error(#file, "Unable to create sign-out request — completing with local cleanup")
            isSignOutInProgress = false
            completeLogOutProcess()
            return
        }

        request.timeoutInterval = 45

        let barcode = userAccount.barcode
        networker.executeRequest(request, enableTokenRefresh: false) { [weak self] result in
            switch result {
            case .success(let data, let response):
                self?.processLogOut(data: data,
                                    response: response,
                                    for: request,
                                    barcode: barcode)
            case .failure(let errorWithProblemDoc, let response):
                // Do NOT call removeAll() here. Credential cleanup
                // is handled by completeLogOutProcess() after device
                // deauthorization. Calling it prematurely caused:
                // 1. Licensor wiped before deauthorizeDevice() could use it
                // 2. Double removeAll() → double notification → UI corruption
                // 3. Race condition with re-authentication
                self?.processLogOutError(errorWithProblemDoc,
                                         response: response,
                                         for: request,
                                         barcode: barcode)
            }
        }

        #else
        // `performLogOut()` requires the main thread (see doc comment above), so
        // assert the isolation the now-@MainActor `TPPAlertUtils.alert(...)` call
        // needs in Swift 6 complete-mode. Matches the sibling `+UI.swift` treatment.
        MainActor.assumeIsolated {
            if self.bookRegistry.isSyncing {
                let alert = TPPAlertUtils.alert(
                    title: "SettingsAccountViewControllerCannotLogOutTitle",
                    message: "SettingsAccountViewControllerCannotLogOutMessage")
                uiDelegate?.present(alert, animated: true, completion: nil)
                isSignOutInProgress = false
            } else {
                completeLogOutProcess()
            }
        }
        #endif
    }

    #if FEATURE_DRM_CONNECTOR
    private func processLogOut(data: Data,
                               response: URLResponse?,
                               for request: URLRequest,
                               barcode: String?) {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        let profileDoc: UserProfileDocument
        do {
            profileDoc = try UserProfileDocument.fromData(data)
        } catch {
            Log.error(#file, "Unable to parse user profile at sign out (HTTP \(statusCode)): Adobe device deauthorization won't be possible. Proceeding with local cleanup.")
            TPPErrorLogger.logUserProfileDocumentAuthError(
                error as NSError,
                summary: "SignOut: unable to parse user profile doc",
                barcode: barcode,
                metadata: [
                    "Request": request.loggableString,
                    "Response": response ?? "N/A",
                    "HTTP status code": statusCode
                ])
            // Proceed to deauthorize even without a fresh licensor token.
            // The user's intent is to sign out — don't leave them stuck.
            self.deauthorizeDevice()
            return
        }

        if let drm = profileDoc.drm?.first,
           let clientToken = drm.clientToken, drm.vendor != nil {

            // Set the fresh Adobe token info into the user account so that the
            // following `deauthorizeDevice` call can use it.
            self.userAccount.setLicensor(drm.licensor)
            Log.info(#file, "Licensor token updated to \(clientToken) for adobe user ID \(self.userAccount.userID ?? "N/A")")
        } else {
            Log.error(#file, "Licensor token invalid: \(profileDoc.toJson())")
        }

        self.deauthorizeDevice()
    }

    private func processLogOutError(_ errorWithProblemDoc: TPPUserFriendlyError,
                                    response: URLResponse?,
                                    for request: URLRequest,
                                    barcode: String?) {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 401 {
            // A 401 on sign-out is expected when the session/token
            // expired during idle. The user's intent is to sign out, so
            // proceed with local cleanup silently instead of showing the
            // confusing "Unexpected Credentials" error.
            Log.info(#file, "Sign-out returned 401 (token expired) — proceeding with local cleanup")
        } else {
            TPPErrorLogger.logNetworkError(
                errorWithProblemDoc,
                summary: "SignOut: server error",
                request: request,
                response: response,
                metadata: [
                    "AuthMethod": self.selectedAuthentication?.methodDescription ?? "N/A",
                    "Hashed barcode": barcode?.md5hex() ?? "N/A",
                    "HTTP status code": statusCode])

            self.uiDelegate?.businessLogic(self,
                                           didEncounterSignOutError: errorWithProblemDoc,
                                           withHTTPStatusCode: statusCode)
        }

        // Always attempt local device deauthorization + cleanup regardless
        // of the server error code. This ensures the user is logged out
        // locally even if the server rejected the request.
        self.deauthorizeDevice()
    }
    #endif

    private func completeLogOutProcess() {
        // Check if this sign-out operation is still valid. A stale
        // DRM deauthorization callback can fire after the user has already
        // re-authenticated — in that case we must not wipe their new credentials.
        guard userAccount.signInGeneration == signOutSnapshot else {
            Log.warn(#file, "Stale sign-out for library \(libraryAccountID) — user re-authenticated. Skipping credential cleanup")
            isSignOutInProgress = false
            // `TPPMainThreadRun.asyncIfNeeded` (non-`@Sendable` closure) instead
            // of `DispatchQueue.main.async` (whose closure IS `@Sendable`): the
            // latter trips the `complete`-mode "capture of non-Sendable self in
            // a @Sendable closure" diagnostic. Behavior-equivalent — this is the
            // terminal UI callback of the stale path with no downstream ordering
            // dependency; sync-if-already-on-main is indistinguishable here.
            TPPMainThreadRun.asyncIfNeeded { [weak self] in
                guard let self else { return }
                self.uiDelegate?.businessLogicDidFinishDeauthorizing(self)
            }
            return
        }

        // Deregister FCM token BEFORE removing credentials (DELETE request needs auth)
        // Also reset the flag so token re-registers on next sign-in
        if let account = libraryAccountsProvider.account(libraryAccountID) {
            NotificationService.shared.deleteToken(for: account)
            account.hasUpdatedToken = false
        }

        bookDownloadsCenter.reset(libraryAccountID)
        bookRegistry.reset(libraryAccountID)

        // Capture the access token before removeAll() wipes it.
        // CM logout endpoints (OIDC and SAML SLO / PP-3452) require
        // Authorization: Bearer <token>; we need this for the API calls
        // in performFinalSignOutCleanup.
        let cmLogoutAccessToken: String? = {
            let needsToken = selectedAuthentication?.isOidc == true
                || selectedAuthentication?.samlLogoutHref != nil
            return needsToken ? userAccount.authToken : nil
        }()

        userAccount.removeAll()
        selectedIDP = nil
        samlHelper.clearState()
        dispatch(.signOutCompleted)

        AppContainer.production().networkExecutor.clearCache()
        URLCache.shared.removeAllCachedResponses()

        // Clear the IdP session before notifying the UI that sign-out is complete.
        //
        // OAuth: patron authenticates via WKWebView, so clearing WKWebView data
        // invalidates the IdP session on this device.
        //
        // SAML: if the CM advertises a logout link (PP-3452), call the CM's
        // saml_logout_redirect endpoint with Bearer — this invalidates the
        // server-side credential and, if the IdP supports SLO, the IdP session.
        // Then clear WKWebView data to invalidate local cookies.
        //
        // OIDC: the CM's logout endpoint is an authenticated REST API — we call
        // it directly with the captured access token, no browser involved.
        //
        // CRITICAL: all async steps must finish BEFORE notifying the UI delegate.
        performFinalSignOutCleanup(cmLogoutAccessToken: cmLogoutAccessToken) { [weak self] in
            // `asyncIfNeeded` (non-`@Sendable`) instead of `DispatchQueue.main.async`
            // to avoid the `complete`-mode non-Sendable-`self`-in-`@Sendable`-closure
            // diagnostic. Terminal UI callback; behavior-equivalent.
            TPPMainThreadRun.asyncIfNeeded { [weak self] in
                guard let self = self else { return }
                self.isSignOutInProgress = false
                self.uiDelegate?.businessLogicDidFinishDeauthorizing(self)
            }
        }
    }

    /// Routes to the appropriate IdP session-clearing step based on auth type.
    ///
    /// OIDC: authenticated API call to CM end-session endpoint, then WKWebView cleanup.
    /// SAML + logout link present (PP-3452): authenticated API call to CM
    ///   saml_logout_redirect, then WKWebView cleanup.
    /// Everything else: WKWebView cleanup only.
    // Swift 6 `complete`: the `completion`-capturing WebKit `removeData`
    // `@Sendable` closures in the `self == nil` fallback branches below (and in
    // `clearWebViewData`) capture a non-Sendable `() -> Void`. Its ultimate
    // source is `completeLogOutProcess`'s `{ [weak self] in … }` closure, which
    // captures the non-Sendable `TPPSignInBusinessLogic self`, so `completion`
    // cannot be made `@Sendable` while the class is neither `Sendable` nor
    // `@MainActor` (handoff §F). We box it (`SignOutCompletionBox`) so the
    // `@Sendable` `removeData` closures capture a Sendable carrier — runtime
    // behavior unchanged (all hops land on main), no unsafe cast on the sign-out
    // critical path.
    private func performFinalSignOutCleanup(cmLogoutAccessToken: String? = nil,
                                            completion: @escaping () -> Void) {
        if selectedAuthentication?.isOidc == true {
            oidcLogOut(accessToken: cmLogoutAccessToken) { [weak self] in
                guard let self = self else {
                    // self deallocated — still clear WebView data and call completion
                    // to ensure the UI state is reset.
                    let completionBox = SignOutCompletionBox(completion)
                    DispatchQueue.main.async {
                        let dataStore = WKWebsiteDataStore.default()
                        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
                        dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
                            if let cookies = HTTPCookieStorage.shared.cookies {
                                for cookie in cookies { HTTPCookieStorage.shared.deleteCookie(cookie) }
                            }
                            completionBox.call()
                        }
                    }
                    return
                }
                self.clearWebViewData(completion: completion)
            }
        } else if selectedAuthentication?.samlLogoutHref != nil {
            samlLogOut(accessToken: cmLogoutAccessToken) { [weak self] in
                guard let self = self else {
                    let completionBox = SignOutCompletionBox(completion)
                    DispatchQueue.main.async {
                        let dataStore = WKWebsiteDataStore.default()
                        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
                        dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
                            if let cookies = HTTPCookieStorage.shared.cookies {
                                for cookie in cookies { HTTPCookieStorage.shared.deleteCookie(cookie) }
                            }
                            completionBox.call()
                        }
                    }
                    return
                }
                self.clearWebViewData(completion: completion)
            }
        } else {
            clearWebViewData(completion: completion)
        }
    }

    /// Clears all WebView data including cookies, cache, local storage, and session data.
    /// This ensures SAML/OAuth identity providers are fully signed out.
    /// - Parameter completion: Called when all WebView data and cookies have been cleared.
    ///  This is critical for SAML sign-out to prevent IdP auto-sign-in.
    private func clearWebViewData(completion: @escaping () -> Void) {
        // Skip WebKit cleanup in test environments (no UI context)
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            completion()
            return
        }
        #endif

        // Swift 6 `complete`: box the non-Sendable `completion` before the WebKit
        // `removeData` `@Sendable` completion closure captures it (see
        // `SignOutCompletionBox`); invoked once on the main queue.
        let completionBox = SignOutCompletionBox(completion)
        // WebKit operations MUST run on the main thread
        DispatchQueue.main.async {
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

            // Use modifiedSince with distantPast to clear ALL data.
            // This is more reliable than fetch+remove, which may not call
            // its completion handler when there are no records to remove.
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
                // Also clear shared cookie storage (synchronous)
                if let cookies = HTTPCookieStorage.shared.cookies {
                    for cookie in cookies {
                        HTTPCookieStorage.shared.deleteCookie(cookie)
                    }
                }

                completionBox.call()
            }
        }
    }

    #if FEATURE_DRM_CONNECTOR
    private func deauthorizeDevice() {
        guard let licensor = userAccount.licensor else {
            Log.warn(#file, "No Licensor available to deauthorize device. Will remove user credentials anyway.")
            TPPErrorLogger.logInvalidLicensor(withAccountID: libraryAccountID)
            completeLogOutProcess()
            return
        }

        var licensorItems = (licensor["clientToken"] as? String)?
            .replacingOccurrences(of: "\n", with: "")
            .components(separatedBy: "|")
        let tokenPassword = licensorItems?.last
        licensorItems?.removeLast()
        let tokenUsername = licensorItems?.joined(separator: "|")
        let adobeUserID = userAccount.userID
        let adobeDeviceID = userAccount.deviceID

        if let drmAuthorizer = drmAuthorizer {
            drmAuthorizer.deauthorize(
                withUsername: tokenUsername,
                password: tokenPassword,
                userID: adobeUserID,
                deviceID: adobeDeviceID) { [weak self] success, error in
                if !success {
                    // DRM deauthorization failures are expected (e.g., E_DEACT_USER_MISMATCH when user changes PIN)
                    // Just log locally and continue - the user should still be able to log out
                    Log.warn(#file, "DRM deauthorization failed (expected): \(error?.localizedDescription ?? "unknown")")
                }

                // Check if self was deallocated during the DRM callback
                guard let strongSelf = self else {
                    // Skip WebKit cleanup in test environments (no UI context)
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                        return
                    }
                    #endif

                    // Even if self is nil, we need to complete the logout process
                    // Call static/global cleanup methods directly
                    DispatchQueue.main.async {
                        let dataStore = WKWebsiteDataStore.default()
                        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
                        dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
                            if let cookies = HTTPCookieStorage.shared.cookies {
                                for cookie in cookies {
                                    HTTPCookieStorage.shared.deleteCookie(cookie)
                                }
                            }
                        }
                    }
                    return
                }

                strongSelf.completeLogOutProcess()
            }
        } else {
            self.completeLogOutProcess()
        }
    }
    #endif
}
