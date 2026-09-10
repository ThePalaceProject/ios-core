//
//  Account+profileDocument.swift
//  Palace
//
//  Created by Vladimir Fedorov on 09.11.2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

extension Account {

    /// Whether stored credentials can authenticate a `/patrons/me/` request
    /// *right now*.
    ///
    /// Presence is not validity. `hasCredentials()` is
    /// `hasAuthToken || hasBarcodeAndPIN` — it answers "is something stored",
    /// not "will it work". An EXPIRED bearer token satisfies it, so the request
    /// goes out and the server answers 401 with the same OPDS auth-document
    /// body the gate above exists to avoid.
    ///
    /// But an expired token is not automatically a doomed request, and this is
    /// the distinction the gate has to make. The 401 refresh is REACTIVE and
    /// lives in the response delegate: `TPPNetworkResponder`'s
    /// `handleExpiredTokenIfNeeded` marks the credential stale and then calls
    /// `refreshTokenAndResume(task:)`, which stores a fresh token via
    /// `setAuthToken` — and that writes `.loggedIn`, healing the stale flag —
    /// and re-drives THIS task, so the profile fetch succeeds. That path never
    /// consults `enableTokenRefresh`; the flag gates only the executor's
    /// PRE-FLIGHT refresh. Blocking every expired token would therefore delete
    /// a repair that works today, and would delete it for exactly the
    /// credentials it can fire on: `isTokenExpired` is non-false only for
    /// `.token` with a non-nil expiry, and that expiry is written by the
    /// barcode/PIN→token exchange, which is precisely the shape the reactive
    /// refresh can repair.
    ///
    /// So the gate blocks only when the token has expired AND no refresh can
    /// repair it. `isTokenRefreshRequired()` answers that.
    ///
    /// It is NOT the responder's predicate, and an earlier version of this
    /// comment wrongly claimed reusing it meant the two "cannot drift". They
    /// already differ: `TPPNetworkResponder` requires `tokenURL != nil` in every
    /// arm, while `isTokenRefreshRequired`'s non-`isToken` branch does not
    /// (`UserAccountAuthState.swift`). The divergence is currently unreachable
    /// in production, but it is a real difference and saying otherwise was the
    /// same unmeasured-docstring defect this file exists to fix.
    ///
    /// Expressed as a pure function of three booleans, deliberately: the
    /// decision is falsifiable on its own, independent of any networking.
    ///
    /// This comment used to say a test "cannot observe whether the request was
    /// actually sent", because `getProfileDocument` reached
    /// `AppContainer.production()` internally. That was true of the original
    /// F-007 test — it asserted a nil result and sub-second timing against
    /// `example.invalid`, both of which hold whether or not the request goes
    /// out, and it survived deleting the gate entirely. It is no longer true:
    /// `getProfileDocument` now takes `performRequest:` and `userAccount:`
    /// seams, and `AccountProfileDocumentTests` drives the gate in BOTH
    /// directions through them. The claim is left here, corrected rather than
    /// deleted, because asserting an untestability that had stopped being true
    /// is the same unmeasured-docstring defect as above.
    ///
    /// `tokenHasExpired` is false for barcode/PIN credentials and for tokens
    /// with no expiry date, so basic-auth libraries are unaffected. OIDC stores
    /// no expiry either, so this arm cannot fire there.
    static func canAuthenticateProfileRequest(hasCredentials: Bool,
                                              tokenHasExpired: Bool,
                                              tokenRefreshWillRepair: Bool) -> Bool {
        guard hasCredentials else { return false }
        return !tokenHasExpired || tokenRefreshWillRepair
    }

    /// - Parameter performRequest: injected request seam. Production passes nil
    ///   and gets the real executor.
    ///
    ///   This exists because SoD review defeated the gate ADDITIVELY: inserting
    ///   `if userAccount.authTokenHasExpired { completion(nil); return }` above
    ///   the gate re-introduced the round-1 regression with the whole suite
    ///   green. A source-text lint cannot catch that — it is monotone, detecting
    ///   deletion but never insertion. Only observing whether the request was
    ///   actually issued can. An earlier version of this file claimed no such
    ///   seam was possible because the executor is reached through
    ///   `AppContainer.production()`; that claim was wrong, and this is the
    ///   refutation.
    /// - Parameter userAccount: injected account seam. Production passes nil and
    ///   gets the shared account for this library's UUID.
    ///
    ///   Without this the `performRequest:` seam below could only ever be driven
    ///   in ONE direction. The account was read from the process-wide cache
    ///   inside this method, so a test could not stage credentials, and every
    ///   seam test necessarily exercised the no-credentials path — where
    ///   `authTokenHasExpired` is false. Two independent reviewers found the
    ///   same live mutant because of it: inserting
    ///   `if userAccount.authTokenHasExpired { completion(nil); return }` above
    ///   the gate re-introduces the round-2 regression (blocking an
    ///   expired-but-repairable token deletes a repair that works) with the
    ///   whole suite green. A guard one level away from what it guards is the
    ///   defect this file already exists to fix, reached a third time.
    /// - Parameter enableTokenRefresh: whether the executor may proactively
    ///   refresh a near-expiry bearer token before issuing this request.
    ///
    ///   Defaults to `false`, which is what every pre-existing caller meant:
    ///   `NotificationService.updateToken()` and `LibrariesSectionViewModel`
    ///   fetch profiles for arbitrary — often non-current — libraries on
    ///   rehydration, and a background poll is not a reason to spend a token
    ///   exchange.
    ///
    ///   The Adobe borrow path passes `true`, and that asymmetry is the point.
    ///   `canAuthenticateProfileRequest` below deliberately lets an
    ///   EXPIRED-but-repairable token through, on the reasoning that a refresh
    ///   will fix it — but nothing repaired it: with refresh disabled the
    ///   expired bearer went out as-is, the CM answered 401, and
    ///   `AdobeLicensorRefresh.resolve` fell back to the stale stored licensor.
    ///   That is exactly the PP-3649 case (an expired session, a licensor older
    ///   than its 60 minutes), so the headline fix would have missed the case
    ///   it targets. `TPPNetworkExecutor:446` gates the refresh on
    ///   `authTokenNearExpiry && (isToken || isOauth) && tokenURL != nil`, and
    ///   `isTokenNearExpiry` is true for an already-expired token too — so this
    ///   is a no-op for basic auth and for a healthy session, and a repair
    ///   exactly where the gate above promised one.
    func getProfileDocument(
        performRequest: ((URLRequest, Bool, @escaping (NYPLResult<Data>) -> Void) -> Void)? = nil,
        userAccount injectedUserAccount: TPPUserAccount? = nil,
        enableTokenRefresh: Bool = false,
        completion: @escaping (_ profileDocument: UserProfileDocument?) -> Void
    ) {
        guard let profileHref = self.details?.userProfileUrl,
              let profileUrl = URL(string: profileHref)
        else {
            // Can be a normal situation, no active user account
            completion(nil)
            return
        }

        // The user-profile endpoint is authenticated; without credentials it
        // returns 401 with an OPDS auth-document body. Anonymous libraries
        // (Palace Bookshelf / DPLA) advertise a `userProfileUrl` in their
        // auth document but no app surface needs the result for an anonymous
        // user. Skip when no credentials are stored — chaos-qa dogfood-5
        // surfaced that NotificationService.updateToken() and deleteToken(for:)
        // call this on every account-change rehydration, producing a
        // /patrons/me/ 401 storm at every cold relaunch (PP-4164 → F-007 →
        // refined by F-DG5-002).
        let userAccount = injectedUserAccount ?? TPPUserAccount.sharedAccount(libraryUUID: self.uuid)
        if !Account.canAuthenticateProfileRequest(
            hasCredentials: userAccount.hasCredentials(),
            tokenHasExpired: userAccount.authTokenHasExpired,
            tokenRefreshWillRepair: userAccount.isTokenRefreshRequired()) {
            completion(nil)
            return
        }

        var request = URLRequest(url: profileUrl)
        // PP-4986: this is `self.uuid`'s profile, fetched with that library's
        // credentials — and `getProfileDocument` is called for non-current
        // libraries (LibrariesSectionViewModel). Naming the account keeps a 401
        // retry authenticating as this library rather than the selected one.
        // `enableTokenRefresh` is threaded THROUGH the seam, not read inside the
        // production closure, so a test can observe the value the caller asked
        // for. A flag only the un-injectable branch consults is a flag no test
        // can be wrong about — the same shape as the gate this file already
        // exists to make observable.
        let send = performRequest ?? { req, refresh, done in
            _ = AppContainer.production().networkExecutor.executeRequest(
                req, enableTokenRefresh: refresh, accountId: self.uuid, completion: done)
        }
        send(request.applyCustomUserAgent(), enableTokenRefresh) { result in
            // The executeRequest completion is a plain (non-Sendable) escaping
            // closure, so `completion` and the parsed `UserProfileDocument`
            // are captured safely here. They are carried across the main-queue
            // hop in a documented box — touched only on that single main-queue
            // block, never concurrently — to satisfy the `@Sendable`
            // `DispatchQueue.main.async`.
            switch result {
            case .success(let data, _):
                do {
                    let profileDocument = try UserProfileDocument.fromData(data)
                    let box = ProfileDocumentCompletionBox(completion: completion, document: profileDocument)
                    DispatchQueue.main.async {
                        box.completion(box.document)
                    }
                    return
                } catch {
                    self.errorReporter.report(error, summary: "Error parsing user profile document")
                }
            case .failure(let error, _):
                self.errorReporter.report(error, summary: "Error retrieveing user profile document")
            }
            let box = ProfileDocumentCompletionBox(completion: completion, document: nil)
            DispatchQueue.main.async {
                box.completion(box.document)
            }
        }
    }

}

/// Documented carrier for `getProfileDocument`'s network completion, which
/// hops to the main queue to invoke `completion` with the parsed document.
/// The `completion` closure and `UserProfileDocument` are non-Sendable;
/// they are only ever read on that single main-queue hop, never
/// concurrently, so they are safe to carry in an `@unchecked Sendable` box.
private struct ProfileDocumentCompletionBox: @unchecked Sendable {
    let completion: (UserProfileDocument?) -> Void
    let document: UserProfileDocument?
}
