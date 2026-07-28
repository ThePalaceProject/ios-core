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
    func problemReportContext(forLibrary libraryUUID: String?) -> (patronIdentifier: String?, libraryName: String?) {
        let account: TPPUserAccount
        if let id = libraryUUID ?? currentAccountId {
            account = userAccount(for: id)
        } else {
            account = currentUserAccount
        }
        return (account.authorizationIdentifier, currentAccount?.name)
    }
}
