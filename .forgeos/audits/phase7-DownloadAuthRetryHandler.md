---
name: audit-phase7-DownloadAuthRetryHandler
type: ephemeral
status: active
created: 2026-05-26
last_refresh: 2026-05-26
freshness_window: 180d
owners: [mybooks]
description: Phase 7 audit — DownloadAuthRetryHandler
---

# Phase 7 audit — DownloadAuthRetryHandler

**Audit target:** `Palace/MyBooks/DownloadAuthRetryHandler.swift` (307 LOC)
**Test file:** `PalaceTests/MyBooks/DownloadAuthRetryHandlerTests.swift` (340 LOC, 8 branch tests)
**Reference:** `git show 3.0.2:Palace/MyBooks/MyBooksDownloadCenter.swift` lines 1757-1942 (inline pre-extraction equivalent)

## Summary

**Verdict: 0 BUG, 3 NEEDS-TEST, 4 CLEAN.** No F-011/F-014/F-017-class defects. Decision-path logic line-matches the 3.0.2 inline source for all six branches. Test gaps cluster around (1) the auto-borrow `attemptDownload: true` parameter direction, (2) the auto-borrow post-completion `newState != .downloading && newState != .downloadSuccessful` predicate, and (3) the `.credentialPrompt` reauthStrategy case which falls through unexercised.

## File:line findings

### CLEAN-1 — Outer auth-needs-refresh predicate is preserved

`DownloadAuthRetryHandler.swift:95`
```swift
if httpResponse?.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: originalURL) == true {
```
Matches `MyBooksDownloadCenter.swift:1767` (3.0.2). Direction `== true`, no negation. The
`originalURL` and `problemDoc` arguments are forwarded identically. Not F-014.

### CLEAN-2 — `hasCredentials` / `loginRequired` predicate directions match 3.0.2

| Branch | new (3.1+) | 3.0.2 | match |
|--------|-----------|-------|-------|
| 401 + has-creds outer | `:97` `if hasCredentials {` | `:1769` `if hasCredentials {` | yes |
| 401 + no-creds inner | `:113` `} else if loginRequired {` | `:1839` `} else if loginRequired {` | yes |
| non-401 + no-creds outer | `:119` `} else if !hasCredentials && loginRequired {` | `:1853` `} else if !hasCredentials && loginRequired {` | yes |
| no-active-loan session-expiry | `:130` `if reauthStrategy == .browser && hasCredentials {` | `:1879` `if reauthStrategy == .browser && hasCredentials {` | yes |

No condition direction flipped. Not F-014.

### CLEAN-3 — `switch reauthStrategy` is exhaustive, no `default:`

`DownloadAuthRetryHandler.swift:101-112` enumerates `.browser`, `.tokenRefresh`,
`.credentialPrompt`, `.none` explicitly. Adding a new enum case to
`ReauthStrategy` would force a compile error, not silent fall-through. This is
the F-011 safety pattern applied correctly.

### CLEAN-4 — `markCredentialsStale()` side-effect preserved

`:99` (401 + hasCredentials path) and `:131` (no-active-loan + browser + hasCredentials
path) both call `userAccount.markCredentialsStale()`. Matches 3.0.2 `:1771` and `:1880`
respectively. Not F-017 (no observed side-effect dropped).

### NEEDS-TEST-1 — `attemptDownload: true` parameter is uncovered

**File:** `DownloadAuthRetryHandler.swift:229`
```swift
delegate?.startBorrow(for: book, attemptDownload: true, borrowCompletion: { [weak self] in
```

**Mutant that survives:** flip `attemptDownload: true` → `attemptDownload: false`.

**Why it matters:** if the auto-borrow doesn't include `attemptDownload: true`,
`BorrowOperation` does not auto-start the download after the loan is reissued
(`BorrowOperation.swift:435` gates download-start on `attemptDownload &&
mapping.state == .downloadNeeded`). The post-borrow completion callback at
`:235` then sees `newState != .downloading && != .downloadSuccessful` and
alerts the user — silently degrading auto-retry to "borrow succeeded, manual
re-tap required". This is exactly the F-014 shape: a boolean param flipped in
the extraction would produce a hard-to-diagnose UX regression that ships
silently.

**Why the existing test misses it:** `SpyDelegate.startBorrow` at
`DownloadAuthRetryHandlerTests.swift:336-338` accepts `attemptDownload: Bool`
but never records it:
```swift
func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
    startBorrowCalls.append((book, book.identifier))   // attemptDownload dropped
}
```
The Branch-6b test at `:286-306` only asserts the book identifier and the
post-state.

**Suggested fix:** record + assert the param.

```swift
// In SpyDelegate:
private(set) var startBorrowCalls: [(book: TPPBook, identifier: String, attemptDownload: Bool)] = []
func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
    startBorrowCalls.append((book, book.identifier, attemptDownload))
}

// In testHandle_noActiveLoan_basicAuth_triggersAutoBorrowAndAlertsOnBorrowFailure:
XCTAssertEqual(spyDelegate.startBorrowCalls.map { $0.attemptDownload }, [true],
    "Auto-borrow must request attemptDownload=true so BorrowOperation auto-starts download")
```

### NEEDS-TEST-2 — Auto-borrow completion-callback predicate is uncovered

**File:** `DownloadAuthRetryHandler.swift:232-241`
```swift
let newState = self.bookRegistry.state(for: book.identifier)
...
if newState != .downloading && newState != .downloadSuccessful {
    // Borrow failed or didn't result in download
    ...
    self.alertPresenter.alertForProblemDocument(problemDoc, error: failureError, book: book)
} else {
    Log.info(#file, ...)
}
```

**Mutants that survive:**
1. `!= .downloading` → `== .downloading` (test alerts on success, swallows on failure)
2. `&& newState != .downloadSuccessful` → `|| newState != .downloadSuccessful` (alert never fires)
3. Drop the `&& newState != .downloadSuccessful` clause entirely (rare-case noise on success)

**Why the existing test misses it:** `testHandle_noActiveLoan_basicAuth_triggersAutoBorrowAndAlertsOnBorrowFailure`
at `:286-306` **never invokes the borrowCompletion closure** — explicit
comment at `:293-296`:
> "we leave borrowCompletion uncalled so we focus on the dispatch contract"

The test name "AlertsOnBorrowFailure" is aspirational; the body asserts only
the dispatch, not the alert. The predicate inside the callback is 100%
uncovered.

**Suggested fix:** spy the borrow callback and drive both branches.

```swift
private final class SpyDelegate: DownloadAuthRetryHandlerDelegate {
    private(set) var startBorrowCalls: [(book: TPPBook, identifier: String, attemptDownload: Bool, completion: (() -> Void)?)] = []
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        startBorrowCalls.append((book, book.identifier, attemptDownload, borrowCompletion))
    }
}

func testAutoBorrow_whenBorrowSucceedsAndDownloadStarts_doesNotAlert() async throws {
    // ... setup as Branch 6b ...
    let handled = handler.handleAuthFailureIfApplicable(...)
    XCTAssertTrue(handled)

    // Simulate BorrowOperation flipping state to .downloading then invoking completion
    registry.setState(.downloading, for: book.identifier)
    spyDelegate.startBorrowCalls.first?.completion?()

    // No alert presented — verify alertPresenter was not used.
    // (Requires injecting a spy DownloadAlertPresenter or asserting on a
    //  spy AccessibilityAnnouncements / progressReporter signal.)
}

func testAutoBorrow_whenBorrowFails_alertsForProblemDoc() async throws {
    // ... setup as Branch 6b ...
    let handled = handler.handleAuthFailureIfApplicable(...)
    // State stays .unregistered (borrow failed)
    spyDelegate.startBorrowCalls.first?.completion?()

    // Assert alertPresenter.alertForProblemDocument was called with the
    // expected problemDoc + error + book — requires a spy or a stub
    // DownloadAlertPresenter (the production one in setUp uses a real
    // DownloadProgressReporter that emits to a publisher we can subscribe).
}
```

**Mutation-testing note:** This is also a good `palace_mutate.py --diff-only`
candidate because the predicate has 3 mutation points and the cache currently
shows 0% kill rate on those lines (predicted — confirm with a local run).

### NEEDS-TEST-3 — `.credentialPrompt` case is unexercised

**File:** `DownloadAuthRetryHandler.swift:109` — the case `.credentialPrompt, .none:`
arm of `switch reauthStrategy`.

**Mutant that survives:** removing `.credentialPrompt` from the case list and
adding `default:` falling through to alert. Compiler still passes (because
`.none` covers fallback semantics), behavior unchanged for `.none`, but
`.credentialPrompt` now hits the `default` (which is identical behavior — so
not a runtime bug today).

**Why it matters:** the F-011 pattern is *exactly* "previously-exhaustive
switch with `default:` silently drops a case". If a future
`AccountDetails.Authentication.ReauthStrategy` adds a new case (say
`.deviceAttestation`), the current exhaustive switch will compile-error and
force the author to think. If the switch instead used `default:`, the new case
falls through silently. The existing test `Branch 3 (tokenRefresh)` only
proves the `.tokenRefresh` arm exists — it doesn't prove `.credentialPrompt`
is enumerated.

**Suggested test:** parameterized over all `ReauthStrategy` cases.

```swift
// Iterate each ReauthStrategy case and assert the expected handler outcome.
// If a new case is added without updating this test, the test fails — and
// the production switch would have already compile-errored (defense in depth).
func testHandle_401_withCredentials_credentialPromptStrategy_returnsFalse() {
    userAccount._authDefinition = makeAuth(typeRaw: "...basic-token-or-similar-credentialPrompt-type...")
    userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
    let task = makeFakeTask(statusCode: 401)
    let handled = handler.handleAuthFailureIfApplicable(book: book, task: task, problemDoc: nil, failureError: nil)
    XCTAssertFalse(handled, ".credentialPrompt + 401 + has-creds falls through to alert")
    XCTAssertFalse(reauthenticator.authenticateIfNeededCalled)
}
```

This is **lower priority** than NEEDS-TEST-1 / -2 because the compile-time
exhaustivity check is the primary safety net; the test is belt-and-braces.

## Mutation-testing notes

Run the diff-scoped mutation gate to confirm the predicted gaps:

```bash
python3 scripts/palace_mutate.py \
  --file Palace/MyBooks/DownloadAuthRetryHandler.swift \
  --tests PalaceTests/MyBooks/DownloadAuthRetryHandlerTests \
  --diff-only --diff-base origin/develop
```

Predicted survivors (pre-fix):
- Line 229: `attemptDownload: true` → `false`
- Line 235: `newState != .downloading` → `==`
- Line 235: `&&` → `||`

Expected kill rate after applying the suggested test additions: 100% on lines
229 + 235 (the spy-recorded param + the completion-driven assertion).

## Architecture notes

- The handler is correctly stateless (`/// Holds no state of its own —
  every decision is a fresh read of the current TPPUserAccount`).
  `userAccountProvider` is invoked fresh inside each callback (`:251`, `:258`,
  `:278`, `:285`) — preserves the 3.0.2 just-in-time semantics across library
  switches. Not F-017.
- The `Task { ... await MainActor.run { ... } }` cleanup-then-mutate pattern at
  `:155-164`, `:169-178`, `:191-200`, `:203-212` mirrors 3.0.2 verbatim. No GCD
  hybrid introduced. Aligns with "Swift concurrency > GCD+closure hybrids"
  guidance.
- The handler has 6 mutually-exclusive branches; all 6 have positive coverage
  in the test file plus 1 fall-through case. The gaps are within-branch
  parameter / predicate gaps, not missing-branch gaps.

## Headline

**No bugs. Three test gaps that would let real defects slip:** the auto-borrow
`attemptDownload: true` parameter is uncovered (NEEDS-TEST-1), the post-borrow
`newState != .downloading && != .downloadSuccessful` predicate is uncovered
(NEEDS-TEST-2), and `.credentialPrompt` strategy is implicitly covered only by
the exhaustive switch (NEEDS-TEST-3). NEEDS-TEST-1 and NEEDS-TEST-2 are
F-014-shape gaps in the auto-borrow no-active-loan path — the same code shape
that produced F-014 in `BorrowOperation`. Recommend adding the spy parameter
recording + driven completion callback before tag-cut on 3.2.0.
