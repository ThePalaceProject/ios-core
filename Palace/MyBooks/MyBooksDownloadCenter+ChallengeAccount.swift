//
//  MyBooksDownloadCenter+ChallengeAccount.swift
//  Palace
//
//  PP-4969 — which account's credentials answer an authentication challenge on a
//  book download.
//
//  The hub's challenge callback used to resolve credentials through `userAccount`,
//  which is `injectedUserAccount ?? accountsManager.currentUserAccount` — the
//  account current WHEN THE CHALLENGE ARRIVES, not the account the download was
//  started for. A patron who switches libraries mid-download therefore had the
//  challenge answered with the new library's card, so one library's server
//  received a credential belonging to another. That is the same credential-
//  isolation boundary as the long-standing cross-account leak invariant recorded
//  in `AccountCredentialResolver` (F-034 / PP-4020).
//
//  The hub's own doc on `userAccount` has said so for a while: it calls itself the
//  legacy resolver-fallback path, and directs new code on the download path to
//  `userAccount(forCapturedId:)` because that one is "deterministic across
//  library-swap windows". This is that redirection, finally applied to the
//  challenge site.
//
//  Why it could not be done before PP-4969's predecessor: the callback was
//  synchronous, and the task→book map it needs is actor-isolated. PP-4895 moved
//  the callback to the SDK's `async` requirement (for unrelated reasons — the
//  completion-handler form was silently failing to register), and an `await`
//  became available inside it for the first time.
//
//  Lives in a collaborator rather than the hub because `MyBooksDownloadCenter` is
//  under a god-class LOC freeze whose contract is "land your fix by EXTRACTING
//  into a collaborator, not by growing the hub". The hub keeps a one-line call.
//

import Foundation

extension MyBooksDownloadCenter {

    /// The account whose credentials should answer an authentication challenge on
    /// `task` — the account the download was STARTED for, not whichever is
    /// current now.
    ///
    /// Resolved by two hops the class already relies on everywhere else:
    ///   1. `stateManager.taskIdentifierToBook`, the live map the progress,
    ///      completion and transient-retry paths all key off, gives the book.
    ///      Reached through `stateManager` rather than the hub's `private`
    ///      convenience accessor, so no production visibility widens for this.
    ///   2. the durable started-task record for that book carries the `account`
    ///      written at download start (`persistStartedTaskRecord`).
    ///
    /// WHAT THIS RESTS ON — bookID keying, not call ordering. An earlier draft of
    /// this comment claimed every seeding site writes the record first; that is a
    /// false census and review caught it. Of the five sites that seed
    /// `taskIdentifierToBook`, four now ATTEMPT a record — the two start paths via
    /// `persistStartedTaskRecord`, and the two re-issue paths via
    /// `persistReissuedTask`/`upsert` as of PP-5023. "Attempt", not "write":
    /// `persistStartedTaskRecord` returns without writing when it can resolve no
    /// URL, so one of the four can still leave a live task unrecorded. That bound
    /// is stated where the guard lives; repeated here because a census in THIS
    /// comment being a shade too strong is what review blocked on twice. The fifth
    /// site is adopt, which is seeded FROM a record:
    ///
    ///   * the two download-START paths write the record via
    ///     `persistStartedTaskRecord` (`MyBooksDownloadCenter` :1748, :2179) and
    ///     then register (:1751, :2181, reaching
    ///     `DownloadTaskLifecycleService` :85).
    ///   * the bearer-token re-issue (`RightsManagementDispatcher`) and the
    ///     follow-up/rights re-issue (`BackgroundDownloadHandler.followAcquisitionLink`)
    ///     seed a NEW task and, as of PP-5023, write a record for it via
    ///     `DownloadStateManager.persistReissuedTask`. That call CARRIES the
    ///     account forward from the existing record rather than restamping the
    ///     current one, precisely so this resolver keeps returning the library the
    ///     download started under.
    ///   * launch reconciliation's adopt (`MyBooksDownloadCenter` :2274) seeds
    ///     from the persisted record itself.
    ///
    /// All five are correct for the same reason: hop 2 keys by bookID, and
    /// `DownloadTaskPersistence.record` upserts by bookID, so at most one record
    /// exists per book and it names the account that book's download started
    /// under. A re-issued task therefore inherits the right account precisely
    /// BECAUSE the lookup ignores task identity — which also makes task-identifier
    /// reuse across background sessions irrelevant. Adopt is correct by
    /// construction, being seeded from that same record.
    ///
    /// A re-issue whose book identifier differs from the original's USED to lose
    /// — it missed the record and landed on the floor below. PP-5023 closed that:
    /// `followAcquisitionLink` passes `inheritingFrom: originalBook.identifier`,
    /// so the account crosses to the new id and this resolver finds it.
    ///
    /// Degrades to `userAccount` — today's behaviour, unchanged — when either hop
    /// misses. A task with no live mapping or no durable record is a task this
    /// method knows nothing about, and guessing would be worse than the status
    /// quo. That is a deliberate floor, not an oversight: it means this change can
    /// only ever narrow the set of challenges answered with the wrong credential,
    /// never widen it.
    func challengeAccount(
        for task: URLSessionTask,
        challenge: URLAuthenticationChallenge
    ) async -> TPPUserAccount {
        // Only HTTP basic consumes credentials — `TPPBasicAuth.handleChallenge`
        // answers server trust and unsupported methods without reading the
        // provider at all. So for those, skip the lookup below rather than paying
        // a synchronous file read and JSON decode on, among other things, every
        // TLS handshake this delegate is asked about. Whatever is returned here
        // cannot reach the answer for those spaces, so this is an I/O guard, not
        // a second place that decides dispositions.
        //
        // COUPLED TO `TPPBasicAuth.handleChallenge`: this is a second encoding of
        // "only basic consumes credentials", in a different module. If that switch
        // ever grows a credential-consuming space (Digest, say), this guard would
        // silently starve it of the started-for account while the disposition
        // switch handled it happily. `TPPBasicAuth` carries the matching pointer
        // back here. Change them together.
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
