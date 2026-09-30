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
    /// `hasCredentials()` only says something is stored; an expired bearer token
    /// satisfies it and the server answers 401 with an OPDS auth-document body.
    ///
    /// An expired token is not always a doomed request, though: on 401,
    /// `TPPNetworkResponder` refreshes the token reactively and re-drives the
    /// task, independent of `enableTokenRefresh`. Blocking every expired token
    /// would remove that repair, so the gate blocks only when the token has
    /// expired and `isTokenRefreshRequired()` says no refresh can repair it.
    /// (That predicate is not identical to the responder's: the responder also
    /// requires `tokenURL != nil` on every arm.)
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

    /// - Parameter performRequest: injected request seam so tests can observe
    ///   whether the request was issued. Production passes nil and gets the
    ///   real executor.
    /// - Parameter userAccount: injected account seam so tests can stage
    ///   credentials. Production passes nil and gets the shared account for
    ///   this library's UUID.
    /// - Parameter enableTokenRefresh: whether the executor may proactively
    ///   refresh a near-expiry bearer token before issuing this request.
    ///   Defaults to `false`: background profile polls for arbitrary libraries
    ///   should not spend a token exchange. The Adobe borrow path passes `true`
    ///   so an expired session gets a fresh token and the current licensor
    ///   (PP-3649) instead of a 401 and a stale stored licensor. The executor
    ///   only refreshes token/OAuth credentials with a `tokenURL`, so this is a
    ///   no-op for basic auth and for a healthy session.
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
        // user. Skipping avoids a /patrons/me/ 401 storm on every cold relaunch,
        // since NotificationService calls this on each account rehydration (PP-4164).
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
        // `enableTokenRefresh` is passed through the seam so tests can observe it.
        let send = performRequest ?? { req, refresh, done in
            _ = AppContainer.production().networkExecutor.executeRequest(
                req, enableTokenRefresh: refresh, accountId: self.uuid, completion: done)
        }
        send(request.applyCustomUserAgent(), enableTokenRefresh) { result in
            // Non-Sendable values cross the main-queue hop in a box; see
            // `ProfileDocumentCompletionBox`.
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
