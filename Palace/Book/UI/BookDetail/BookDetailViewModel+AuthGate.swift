//
//  BookDetailViewModel+AuthGate.swift
//  Palace
//
//  The decision behind the detail screen's sign-in gate (PP-5449).
//

import Foundation
import PalaceBookModel

extension BookDetailViewModel {

    /// The request a gated action sends. Only a borrow opens the sign-in sheet
    /// itself when the server refuses a barcode/PIN (`BorrowOperation`); a
    /// fulfilment download or a book open shows an error instead.
    enum GatedRequest: Equatable {
        case borrow
        case other
    }

    /// Get borrows only a book that is not on loan. A ready hold's Get and a
    /// loan's Download are not routed through the borrow refusal path.
    static func gatedRequest(forDownloadFrom state: TPPBookState) -> GatedRequest {
        state == .unregistered ? .borrow : .other
    }

    /// Whether the gate asks the patron to sign in before running the action.
    static func promptsSignInBeforeAction(for account: TPPUserAccount,
                                          request: GatedRequest) -> Bool {
        promptsSignInBeforeAction(needsAuth: account.needsAuth,
                                  hasCredentials: account.hasCredentials(),
                                  authState: account.authState,
                                  authDefinition: account.authDefinition,
                                  request: request)
    }

    static func promptsSignInBeforeAction(needsAuth: Bool,
                                          hasCredentials: Bool,
                                          authState: TPPAccountAuthState,
                                          authDefinition: AccountDetails.Authentication?,
                                          request: GatedRequest) -> Bool {
        let needsSignIn = needsAuth && !hasCredentials
        // .credentialsStale means we still hold credentials but a 401
        // has marked the session expired. For browser sign-in, reading the
        // cached book proceeds straight to a hung reader (no fresh
        // fulfillment, no fresh DRM grant) without an intervening sign-in,
        // so re-auth is forced here. HelpSpot 17716 (Cornell SAML).
        // A barcode/PIN borrow goes to the server instead: it may still accept
        // them, and a refusal opens the sign-in sheet there (PP-5449).
        let serverDecides = authDefinition?.isBasic == true && request == .borrow
        let needsReauth = authState == .credentialsStale && !serverDecides
        return needsSignIn || needsReauth
    }
}
