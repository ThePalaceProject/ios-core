//
//  MyBooksDownloadCenter+ChallengeAccount.swift
//  Palace
//
//  PP-4969 — which account's credentials answer an authentication challenge on a
//  book download.
//
//  The challenge must be answered with the account the download was started
//  for, not the one current when the challenge arrives; otherwise a library
//  switch mid-download sends one library's card to another library's server
//  (same boundary as F-034 / PP-4020 in `AccountCredentialResolver`). The
//  lookup needs the actor-isolated task→book map, so it relies on the `async`
//  challenge callback (PP-4895).
//

import Foundation

extension MyBooksDownloadCenter {

    /// The account whose credentials should answer an authentication challenge on
    /// `task` — the account the download was STARTED for, not whichever is
    /// current now.
    ///
    /// Resolved in two hops: `stateManager.taskIdentifierToBook` gives the book,
    /// and that book's durable started-task record gives the `account` written
    /// at download start.
    ///
    /// Correctness rests on bookID keying, not call ordering: records upsert by
    /// bookID, so there is at most one per book and it names the account the
    /// download started under. Re-issued tasks (`RightsManagementDispatcher`,
    /// `BackgroundDownloadHandler.followAcquisitionLink`) carry that account
    /// forward via `persistReissuedTask` (PP-5023), including across a changed
    /// book id; launch reconciliation's adopt seeds from the record itself.
    /// `persistStartedTaskRecord` writes nothing when it can resolve no URL, so
    /// a live task can still be unrecorded.
    ///
    /// Falls back to `userAccount` when either hop misses, so this can only
    /// narrow the set of challenges answered with the wrong credential.
    func challengeAccount(
        for task: URLSessionTask,
        challenge: URLAuthenticationChallenge
    ) async -> TPPUserAccount {
        // Only HTTP basic consumes credentials, so skip the file read for server
        // trust and other methods (every TLS handshake reaches here). Coupled to
        // `TPPBasicAuth.handleChallenge`: if that switch starts consuming
        // credentials for another method, change this guard too.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic else {
            return userAccount
        }
        guard let book = await stateManager.taskIdentifierToBook.get(task.taskIdentifier) else {
            return userAccount
        }
        guard let startedAccountID = stateManager
            .persistedRecords()
            .first(where: { $0.bookID == book.identifier })?
            .account,
            !startedAccountID.isEmpty
        else {
            return userAccount
        }
        return userAccount(forCapturedId: startedAccountID)
    }
}
