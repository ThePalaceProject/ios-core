//
//  BookDetailViewModel+AuthGate.swift
//  Palace
//
//  The decision behind the detail screen's sign-in gate (PP-5449).
//

import Foundation

extension BookDetailViewModel {

    /// Whether the gate asks the patron to sign in before running the action.
    static func promptsSignInBeforeAction(needsAuth: Bool,
                                          hasCredentials: Bool,
                                          authState: TPPAccountAuthState,
                                          authDefinition: AccountDetails.Authentication?) -> Bool {
        let needsSignIn = needsAuth && !hasCredentials
        // .credentialsStale means we still hold credentials but a 401
        // has marked the session expired. For browser sign-in, reading the
        // cached book proceeds straight to a hung reader (no fresh
        // fulfillment, no fresh DRM grant) without an intervening sign-in,
        // so re-auth is forced here. HelpSpot 17716 (Cornell SAML).
        // Barcode/PIN go to the server instead: it may still accept them,
        // and a refusal opens the sign-in sheet there (PP-5449).
        let needsReauth = authState == .credentialsStale && authDefinition?.isBasic != true
        return needsSignIn || needsReauth
    }
}
