//
//  AccountsManager+ProblemReportContext.swift
//  Palace
//
//  Callers snapshot this context and pass it to the problem-report composer, so
//  ErrorHandling does not depend on AccountsManager. Patron ID comes from the
//  given library (or the current account); the library display name is always
//  the current account's, even when a different library was selected.
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
        // PP-5078: the resolved ID is returned alongside the name because
        // `currentAccount` stays nil until the registry loads. In that window the
        // app knows which library is selected but cannot name it.
        return (account.authorizationIdentifier, currentAccount?.name, resolvedID)
    }
}
