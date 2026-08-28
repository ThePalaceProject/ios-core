---
name: a-retried-request-carried-whichever-library-was-current
created: 2026-08-28
author: claude-opus-5
type: bugfix
tracking: PP-4986 — token refresh retries queued requests with the currently selected library's credentials. Same boundary as PP-4969 / PP-4978 / F-034 / PP-4020.
related_prs: []
---

# Intent: PP-4986 — a retried request carried whichever library was current

## Reproduction

1. Sign in to library A and start a request — a catalog fetch, a loans fetch,
   or a download. All four download-task producers and the `executeRequest`
   data-task path are covered.
2. Switch to library B while that request is still in flight.
3. The request 401s; the executor refreshes the token and retries it.

The retry carries **library B's** bearer to **library A's** server. Before this
change the rebuild called `request(for:)` — the account-less overload — which
resolves credentials from whatever library is selected at drain time.

Reproduced as a failing test rather than by hand:

    ("Bearer bearerB") is not equal to ("Bearer freshA")

## Root cause

The retry rebuild resolved credentials at DRAIN time, and nothing in the queue
recorded which library each request belonged to — `retryQueue` held bare
`URLSessionTask`s, so there was no account to pass.

A first attempt recorded the account at refresh-START. Review rejected it:
every production enqueue site resolves `currentAccountId` anyway
(`TPPNetworkResponder:655` at 401-receipt; `BackgroundDownloadHandler:207`
passes nil), so it only narrowed the window from drain-time to 401-time and a
switch BEFORE the 401 still leaked. Its test hand-injected an account through a
test seam — a value no production path computes — so it passed on a fix that did
not work.

The account is only known to be correct at DISPATCH, which is where it is now
captured.

## Claims
- Stamps the dispatching account onto each task in
  `TPPNetworkExecutor.performDataTask` via `TaskProvenance` (encoded into
  `URLSessionTask.taskDescription` as `key=value;` pairs).
- The token-refresh retry rebuild reads that provenance back and passes it to
  `request(for:accountId:)`, so a retry authenticates as the library the request
  was DISPATCHED for rather than the one selected at drain time.
- Carries provenance onto the replacement task, so a retry that itself 401s does
  not fall back to the current account.
- `TokenRefreshCoordinator.retryQueue` holds `(task, accountIdAtRefreshStart)`
  pairs; that field is the fallback only, and is named for what it actually is.

## Anti-claims
- Does NOT change which account a refresh TARGETS, the single-flight claim, the
  watchdog's force-release, or cancellation semantics for stranded requests.
- Does NOT cover `NotificationService.deleteToken(for:)`. It dispatches via
  `addBearerAndExecute`, which calls the two-argument `executeRequest` and has no
  account parameter, so the new overload cannot serve it. It is invoked for
  arbitrary accounts and is wrong at DISPATCH rather than only on retry — a wider
  pre-existing defect. Closing it needs `accountId` on `addBearerAndExecute`.
- Does NOT redirect the download-side refresh DECISION
  (`BackgroundDownloadHandler`). The CREDENTIALS there are correct for the paths this change
  stamps. One KNOWN BOUND remains, documented at
  `MyBooksDownloadCenter.swift:2130`: the transfer-retry re-issue re-stamps the
  CURRENT account, so a switch between start and transfer-retry still misroutes
  that one path. Pre-existing and unchanged here; what remains is the TRIGGER
  reading the current library's staleness. Needs an injected seam for two
  `AppContainer.production()` reads at that site.
- Does NOT claim `URLSessionTask.response` is unfabricatable — an earlier draft
  said so and it is false; this repo overrides it in five test files. That claim
  is withdrawn.
- Does NOT rebuild method, body, or headers on retry — pre-existing, unchanged.

## Files in scope
- `Palace/Network/TPPNetworkExecutor.swift`
- `Palace/Network/TPPRequestExecuting.swift`
- `Palace/MyBooks/MyBooksDownloadCenter.swift`
- `Palace/MyBooks/DownloadStateManager.swift`
- `Palace/MyBooks/BackgroundDownloadHandler.swift`
- `Palace/MyBooks/RightsManagementDispatcher.swift`
- `Palace/MyBooks/DownloadTaskPersistence.swift` (comment only)
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` and its `+OIDC` / `+SAML` /
  `+SignOut` extensions
- `Palace/Accounts/Library/Account+profileDocument.swift`
- `PalaceTests/Network/MultiLibraryTokenIsolationTests.swift`
- `PalaceTests/Network/TaskProvenanceTests.swift`
- `PalaceTests/MyBooks/MyBooksDownloadCenterAccountScopeSeamTests.swift`
- `Palace.xcodeproj/project.pbxproj` (test-target registration)

## Verification
Red-then-green, and discriminating against the REJECTED fix. A first attempt
recorded the account at refresh-start; review showed every production enqueue
site resolves `currentAccountId` anyway, so it only narrowed the window from
drain-time to 401-time. Its test hand-injected an account no production path
computes, so it passed on a fix that did not work.

The test now drives production's shape — dispatch a real request while A is
current, switch to B, pass **B** as the refresh-start account (what the responder
actually computes), and assert A wins because the task knows:

    mutant (rebuild ignores task provenance = the rejected narrowing fix)
      -> test_QueuedRetry_UsesTheDispatchAccount_NotTheOneCurrentAt401 FAILED by name
         ("Bearer bearerB") is not equal to ("Bearer freshA")
    restored -> full scheme, 0 failures (see the commit body for the count at that tip)
