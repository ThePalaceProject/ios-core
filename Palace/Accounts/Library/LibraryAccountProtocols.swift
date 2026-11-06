//
//  LibraryAccountProtocols.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

@objc protocol TPPCurrentLibraryAccountProvider: NSObjectProtocol {
    var currentAccount: Account? { get }
}

/// Resolves per-library `TPPUserAccount` instances. Prefer this over
/// `TPPUserAccount.sharedAccount(libraryUUID:)` — instances returned by
/// this protocol have immutable keychain keys and are not subject to the
/// TOCTOU race in the singleton's mutable `libraryUUID` pattern.
@objc protocol TPPUserAccountResolving: NSObjectProtocol {
    func userAccount(for libraryUUID: String) -> TPPUserAccount
    var currentUserAccount: TPPUserAccount { get }
}

@objc protocol TPPLibraryAccountsProvider: TPPCurrentLibraryAccountProvider, TPPUserAccountResolving {
    var tppAccountUUID: String { get }
    var currentAccountId: String? { get }
    func account(_ uuid: String) -> Account?
    /// Announces where the current sign-in attempt is. Required, so every
    /// provider a sign-in can run against decides what to do with it.
    func reportSignInProgress(_ progress: SignInProgress)
}
