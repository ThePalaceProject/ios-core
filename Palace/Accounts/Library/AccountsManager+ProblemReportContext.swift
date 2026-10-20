//
//  AccountsManager+ProblemReportContext.swift
//  Palace
//
//  Callers snapshot this context and pass it to the problem-report composer, so
//  ErrorHandling does not depend on AccountsManager. The patron reference comes
//  from the given library (or the current account) and is hashed before it
//  leaves here (PP-4818); the library display name is always the current
//  account's, even when a different library was selected.
//

import Foundation

extension AccountsManager {
    func problemReportContext(forLibrary libraryUUID: String?) -> SupportReportContext {
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
        return SupportReportContext(
            rawPatronIdentifier: account.authorizationIdentifier,
            libraryName: currentAccount?.name,
            libraryUUID: resolvedID
        )
    }
}
