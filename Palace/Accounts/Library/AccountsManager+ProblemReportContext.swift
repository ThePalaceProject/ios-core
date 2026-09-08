//
//  AccountsManager+ProblemReportContext.swift
//  Palace
//
//  Wave 1c (cycle 2): the problem-report composer no longer reaches into
//  AccountsManager (ErrorHandling↔Accounts cycle back-edge). Callers snapshot
//  this context and pass values in. Replicates the exact pre-wave resolution
//  from ProblemReportEmail.beginComposing(to:presentingViewController:book:libraryUUID:):
//  a specific library's patron ID when the UUID (or current account id) is
//  known, else the current user account; library display name is always the
//  CURRENT account's (matching the old generateBody behavior even when a
//  different library was selected).
//

import Foundation

extension AccountsManager {
    func problemReportContext(
        forLibrary libraryUUID: String?
    ) -> (patronIdentifier: String?, libraryName: String?, libraryUUID: String?) {
        let account: TPPUserAccount
        let resolvedID = libraryUUID ?? currentAccountId
        if let id = resolvedID {
            account = userAccount(for: id)
        } else {
            account = currentUserAccount
        }
        // PP-5078: the resolved ID is returned alongside the name because the two
        // resolve independently. The patron ID comes from `account` (looked up by
        // ID), while the name comes from `currentAccount`, which stays nil until
        // the library registry has loaded. In that window the app knows WHICH
        // library is selected but cannot name it — the exact state that produced
        // problem reports with a populated Patron ID and a blank Library line.
        return (account.authorizationIdentifier, currentAccount?.name, resolvedID)
    }
}
