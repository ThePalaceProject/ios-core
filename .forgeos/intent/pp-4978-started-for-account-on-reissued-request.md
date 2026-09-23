---
name: pp-4978-started-for-account-on-reissued-request
created: 2026-08-17
author: claude-opus-5
jira: PP-4978
---

**ADR refs:** none. The governing recorded decision is the credential-isolation
invariant at the head of `Palace/Accounts/Library/AccountCredentialResolver.swift`
— F-034 (cross-account credential leak, PP-4020) and F-016 (ride-out over the
account-switch window). Same boundary as PP-4969, which fixed the
challenge-answering half of this flow.

## Context

`BackgroundDownloadHandler` does a download's follow-up work — re-issuing the
request after an OPDS-entry / rights step, and deciding whether the token needs
refreshing. Both read the account that is **current right now**, not the account
the download was started under. A patron who switches libraries mid-download
therefore has follow-up work performed with the new library's credentials against
the original library's server.

PP-4969 fixed the challenge-answering side of the same flow and deliberately left
this one out, because answering a challenge and constructing a request are
different code paths and the fix belongs in its own revert unit.

## The census — four sites, ONE fixed here

Enumerated rather than assumed. Review corrected this twice, and the corrections
narrowed the change rather than widening it.

| site | reads | disposition |
|---|---|---|
| re-issued request's `Authorization` header | `delegate.userAccount.authToken` | **fixed** |
| token-refresh decision + `refreshTokenAndResume` | `currentUserAccount.isTokenRefreshRequired()` | **NOT fixed — see below** |
| `MyBooksSimplifiedBearerToken.refreshToken(from:completion:)` | `currentUserAccount.authToken` | not fixed; `static`, only a URL in scope |
| `RightsManagementDispatcher` `userAccountProvider()` | Adobe `userID`/`deviceID` for ACSM fulfillment | not fixed; DRM-binding, own decision record |

`RightsManagementDispatcher`'s bearer-token line was checked and is NOT an
instance — that token comes from the fulfillment document the server returned,
not from an account. An architect reviewer verified this independently. Its
*Adobe* account read is a separate, fourth site, which the first version of this
census missed entirely.

### Why the refresh half was dropped

An earlier version of this change fixed the refresh decision too, on the argument
that the decision and the action "must move together". Three reviewers
independently showed that was wrong, and the deciding evidence is simple:

`refreshTokenAndResume` rebuilds every queued request through
`TPPNetworkExecutor.request(for:)` — the one-argument overload, which resolves
`accountId: nil`, i.e. the CURRENT account. So even after refreshing the correct
account, the rebuilt requests carry the current library's bearer to the original
library's server. **Fixing the decision would have moved the leak, not closed
it.**

Two further defects in that same arm, found independently: the progress path's
`book` comes from `taskIdentifierToBook`, which the re-issue sets to the UPDATED
book, so the two sites would have keyed on different books — the very
"check one account, refresh another" the design claimed to prevent; and the two
helpers each read `persistedRecords()` separately, so a record removed between
them yields a split decision.

The refresh arm therefore needs `TPPNetworkExecutor`'s internal rebuild fixed
first. That is a change to the executor with its own blast radius, and it is
filed as **PP-4986** rather than bundled here.

## Claims

- adds `func userAccount(forCapturedId:) -> TPPUserAccount` to
  `BackgroundDownloadHandlerDelegate`. `MyBooksDownloadCenter` already implements
  it publicly, so this is a protocol line with **zero** production implementation
  change; the test spy gains the same forwarding member
- adds a single internal resolver on `BackgroundDownloadHandler` that maps a book
  to the account its download started under, via the durable started-task record
  (`stateManager.persistedRecords()`, keyed by `bookID`). Same two-hop shape and
  the same degradation floor PP-4969 established and three reviewers validated.
  It takes the delegate as a parameter rather than reading `self.delegate`, so
  there is no nil arm inventing a fallback — an earlier draft's fallback reached
  `AppContainer.production()` from a collaborator, against the composition-root
  rule
- routes the re-issued request's `Authorization` header through that account
  rather than the current one
- keys on `originalBook.identifier` at the re-issue site — the record is written
  at download start under the original book, so the original is the correct key
  even when the follow-up carries an updated book
- tests: a library switch mid-download must leave the re-issued request carrying
  the ORIGINAL library's token and must not send the current library's; a
  re-issue whose updated book has a DIFFERENT identifier must still resolve
  through the original book, which is the only test that discriminates the keying
  decision; and the resolver must fall back to today's behaviour when there is no
  record and when the record's account is empty

## Anti-claims

- does NOT change when a follow-up download happens, what it downloads, or the
  rights-management decision — only which account's credentials it carries
- does NOT change the token-refresh path in any way. An earlier draft did, and
  the arm was withdrawn — see the census above. `refreshTokenAndResume` is called
  exactly as before, with no `accountId`
- does NOT touch the durable record's contents or when it is written. It is read
  here, exactly as PP-4969 reads it
- does NOT promise the record is a true capture of the started-under account.
  `persistStartedTaskRecord` fires on the initial start AND on each transfer-retry
  re-issue, and the store upserts by book id — so a transfer retry occurring after
  a library switch rewrites the captured account to the then-current one, and this
  resolver returns that. The change still narrows the defect (every case where no
  retry intervened now resolves correctly, where none did before) but it does not
  eliminate it. Stated here and at the resolver, because the premise "written at
  download start" was the claim the whole fix rested on and it is only half true.
  Closing it means preserving the original account across a retry re-issue
- does NOT fix `MyBooksSimplifiedBearerToken.refreshToken(from:completion:)`. It
  is `static` with only a URL in scope, so correcting it means threading an
  account through its signature and auditing every caller — a different-shaped
  change that would widen this revert unit. Named in Not-done so it is enumerated
  rather than missed
- does NOT close the underlying race. If the record is absent the code still uses
  the current account, exactly as today, so via those arms this can only narrow
  — not widen — the set of
  requests carrying the wrong credential

## Test-harness note

The suite is based on `PalaceWiringTestCase` and mints its manager via
`makeFreshAccountsManager()`. That is the seam
`AccountsManagerIsolationLintTests` requires, and it matters for a reason beyond
the lint: the base class registers `cancelAndDrainBackgroundWork()` on teardown,
which a hand-rolled `AccountsManager()` silently skips. PP-4969 shipped that
hand-rolled form to CI and was caught; this branch never did.

## Files in scope

- `Palace/MyBooks/BackgroundDownloadHandler.swift`
- `PalaceTests/Mocks/MockBackgroundDownloadDelegate.swift`
- `PalaceTests/MyBooks/BackgroundDownloadTokenAccountTests.swift` (new)
- `Palace.xcodeproj/project.pbxproj` (test-target membership for the new file)

## Not done

Three account-derived sites on this path are deliberately left alone, each for a
different reason:

**The token-refresh decision** (`isTokenRefreshRequired()` →
`refreshTokenAndResume`). Redirecting it is unsafe until
`TPPNetworkExecutor.request(for:)` carries an account through the queued-request
rebuild — otherwise the refresh targets the right account and the retries still
send the current library's bearer. Filed as **PP-4986**, which also records the
two secondary defects review found in the naive version.

**`MyBooksSimplifiedBearerToken.refreshToken(from:completion:)`** reads
`AppContainer.production().accountsManager.currentUserAccount.authToken` to
authorize the CM fulfill request. `static`, with only a URL in scope, so fixing
it means threading an account through its signature and auditing every caller —
a different-shaped change that would widen this revert unit.

**`RightsManagementDispatcher`'s `userAccountProvider()`**, which supplies the
Adobe `userID`/`deviceID` for ACSM fulfillment. A fourth account-derived read
with DRM-binding consequences, and there is an existing decision record on the
resolver path in `MyBooksDownloadCenter` — but that rationale is about bearer
auth and sign-in refresh, not a library switch, so it does not settle this case.
Named here rather than left implied by a file marked "checked".
