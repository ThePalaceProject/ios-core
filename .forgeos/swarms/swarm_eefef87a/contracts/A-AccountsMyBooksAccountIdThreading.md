---
name: swarm_eefef87a-contract-A-AccountsMyBooksAccountIdThreading
type: immutable
status: active
created: 2026-05-26T15:00:00Z
last_refresh: 2026-05-27
freshness_window: never
owners: [mybooks]
description: Module A — TPPUserAccount.sharedAccount() fallback removal (Option 1)
---

# Module A — TPPUserAccount.sharedAccount() fallback removal (Option 1)

**Improvement #1 from the A+ posture push.** Auth-critical. Round-trip wiring test mandatory per `feedback_round_trip_wiring_tests.md`. Memory pin `reference_tpp_user_account_migration_retro.md` is load-bearing — read it before writing code.

## Problem (recap from the retro)

`AccountsManager.currentUserAccount` already has a `lastKnownCurrentUserAccount` mitigation (PR-merged form of Option 2). Despite that, the call chain MyBooksDownloadCenter → TPPNetworkExecutor.bearerAuthorized → `AppContainer.production().accountsManager.currentUserAccount` still re-resolves the "current" account on EVERY request build, including across a library swap that happens during a multi-chunk download. That re-resolution is the spurious-login-modal surface. Option 1 closes the window deterministically by capturing accountId at download START and passing it explicitly through.

The piece that's already partially in place: `TPPNetworkExecutor.request(for:useTokenIfAvailable:accountId:)` at `Palace/Network/TPPNetworkExecutor.swift:264` already takes an `accountId: String?`. The Objective-C compatibility overload at line 260 passes `nil`. `bearerAuthorized` at line 303 does NOT take accountId.

## In-scope files (exclusive write)

### Production
- MOD `Palace/Network/TPPNetworkExecutor.swift` — overload `bearerAuthorized(request:accountId:)`; keep the no-arg overload for legacy Objective-C call sites but route it through the same internal implementation with `accountId: nil` (resolved-fallback path).
- MOD `Palace/MyBooks/MyBooksDownloadCenter.swift` — at the `startDownloadAsync` boundary (line 967), capture `let accountIdAtDownloadStart = accountsManager.currentAccountId` and thread it. ALL 8 `userAccount ?? accountsManager.currentUserAccount` sites become `userAccount ?? accountsManager.userAccount(for: accountIdAtDownloadStart ?? AccountsManager.noAccountSentinelUUID)` OR cleaner: extend the internal helper that those 8 sites use to take an explicit `accountId`. (Lines: 39, 310, 355, 440, 461, 550, 576, 633.)
- MOD `Palace/MyBooks/DownloadStartCoordinator.swift` — propagate accountId from the boundary call.
- MOD `Palace/MyBooks/DownloadStartDispatcher.swift` — line 182 `TPPNetworkExecutor.bearerAuthorized(request:)` becomes `bearerAuthorized(request:accountId:)` once accountId is plumbed through.

### Tests
- MOD `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` — ADD ONE TEST (Test 8). See "Tests owned" below.
- NEW `PalaceTests/MyBooks/MyBooksDownloadCenterAccountIdThreadingTests.swift` — unit tests for the thread-through. ≥6 cases.
- MOD any existing MBDC test that constructs MBDC with the injection pattern — confirm the captured-accountId behavior on test boundaries is still satisfied.

## OFF-LIMITS for this module

- `Palace/Audiobooks/` (Module B)
- `scripts/verify-pr.sh` (Module C)
- `docs/architecture/` (Module C owns the new ADR; do not edit any other ADR)
- `PalaceTests/Contract/` (Module D)
- `Palace/Reader2/` (Module D)
- Anywhere in `Palace/Accounts/Library/AccountsManager.swift` that touches `currentUserAccount` resolution — that mitigation is in place; do NOT regress it or layer a second mitigation. Option 1 layers AT THE CALL SITES, not at the resolver.

## Public surface changes (LOCKED)

```swift
// NEW signature on TPPNetworkExecutor (the existing 1-arg @objc class func stays for legacy Obj-C callers)
extension TPPNetworkExecutor {
    /// Apply the bearer token for an explicit accountId, eliminating the transient
    /// `currentUserAccount` re-resolution window observed during library swaps mid-download.
    /// Pass nil to fall back to the resolver — same behavior as the legacy `bearerAuthorized(request:)`.
    @objc class func bearerAuthorized(request: URLRequest, accountId: String?) -> URLRequest
}
```

The existing `@objc class func bearerAuthorized(request:)` is RETAINED and delegates to `bearerAuthorized(request:accountId: nil)`. No call-site break for the legacy network paths.

## Behavior contract (LOCKED)

1. **Capture-at-start invariant** — when `MyBooksDownloadCenter.startDownloadAsync(for:withRequest:)` is invoked, the FIRST line in the path (after the reachability guard) captures `currentAccountId` once into a let-binding. ALL subsequent token/credential lookups on this download path use that captured id.
2. **Nil fallback is a sentinel, not silent** — if `currentAccountId` is nil at capture time, capture the placeholder UUID (`AccountsManager.noAccountSentinelUUID`). DO NOT capture a different account's id. DO NOT raise.
3. **No new singleton reads** — `bearerAuthorized(request:accountId:)` MUST NOT call `AppContainer.production()`. It receives its dependencies through the existing `TPPNetworkExecutor` instance state. The legacy no-arg overload's resolver lookup stays the only place `AppContainer.production()` appears.
4. **Library swap mid-download is non-fatal** — if the user switches libraries while a download is in flight, the in-flight download continues against the originally-captured accountId. The new library's user does not authenticate the in-flight bytes.

## Tests owned

### Test 8 in `AccountsManagerStateMachineWiringTests.swift` (round-trip)

```
testStartDownload_currentAccountIdFlipsToNilDuringDownload_useCapturedAccountId
```

Scenario (A → B → A round-trip):
1. Sign in to account A.
2. Construct MBDC with injected `accountsManager`.
3. Invoke `startDownloadAsync(for: book)` for a book belonging to account A.
4. Mid-flight (between request build and request execute), flip `accountsManager.currentAccountId = nil` to simulate the swap window.
5. Assert: the URLRequest that goes out carries account A's bearer token. NOT the placeholder, NOT empty.
6. Restore `currentAccountId = "A"`. Issue a second startDownload for a different book. Assert it ALSO carries account A's token (the first flow's captured id did NOT poison the second flow's resolution).
7. Flip to account B. Issue startDownload. Assert it carries B's token.

This is the round-trip — full A→nil→A→B lifecycle through the production seam, not via `_setCapturedAccountId` shortcuts.

### Unit tests in `MyBooksDownloadCenterAccountIdThreadingTests.swift` (≥6 cases)

- `testStartDownload_capturesCurrentAccountIdOnce_doesNotReResolve`
- `testStartDownload_currentAccountIdNilAtCapture_capturesSentinelUUID`
- `testStartDownload_currentAccountIdChangesAfterCapture_originalIdUsedForRequests`
- `testBearerAuthorized_explicitAccountId_appliesTokenForThatAccount`
- `testBearerAuthorized_nilAccountId_delegatesToResolver` (legacy compat)
- `testBearerAuthorized_explicitAccountId_doesNotTouchAppContainerProduction` (constructor-injection sanity)

## Acceptance criteria

- All 8 `userAccount ?? accountsManager.currentUserAccount` sites in `MyBooksDownloadCenter.swift` either (a) take a now-explicit `accountId` from the capture, or (b) document why they explicitly need the resolver (none should).
- `bearerAuthorized(request:accountId:)` exists and the `DownloadStartDispatcher.swift:182` callsite uses it.
- `AccountsManagerStateMachineWiringTests.swift` Test 8 exists and passes.
- `MyBooksDownloadCenterAccountIdThreadingTests.swift` exists with ≥6 cases, all green.
- `git grep "AppContainer.production()" Palace/Network/TPPNetworkExecutor.swift` shows the call in only ONE place (the no-arg legacy overload's fallback path).
- `git grep "TPPUserAccount.sharedAccount" Palace/MyBooks Palace/Network` returns 0.
- `scripts/verify-pr.sh --quick` passes; on this PR scope, mutation testing on `MyBooksDownloadCenter.swift` and `TPPNetworkExecutor.swift` shows ≥50% kill rate (these are critical-path files per the verify-pr regex).
- No edits in off-limits list.

## Implementer prompt

You are Module A implementer for `swarm_eefef87a`. Read `reference_tpp_user_account_migration_retro.md` and `feedback_round_trip_wiring_tests.md` before writing any code — those are load-bearing for this auth-critical work.

**Step order:**
1. Write `transcripts/A-AccountsMyBooksAccountIdThreading.md` skeleton FIRST (5 section headings, save). Swarm lesson: implementer streams time out at transcript-write step if it's left for last.
2. Read `Palace/Network/TPPNetworkExecutor.swift` lines 260-316 to understand the existing accountId pathway in `request(for:)`. The pattern you replicate in `bearerAuthorized` is the same: `let resolvedId = accountId ?? accountsManager.currentAccountId ?? ""` then `accountsManager.userAccount(for: resolvedId).credentialSnapshot()`.
3. Add the `bearerAuthorized(request:accountId:)` overload. The no-arg legacy overload delegates to it with `accountId: nil`.
4. Capture accountId at `MyBooksDownloadCenter.startDownloadAsync` entry. Thread to `DownloadStartCoordinator.startDownloadAsync` — that's the orchestrator. Thread to `DownloadStartDispatcher` which holds the bearerAuthorized call.
5. Update the 8 MBDC `userAccount ?? accountsManager.currentUserAccount` sites. The cleanest move is to extract a tiny private helper `private func userAccount(forCapturedId accountId: String) -> TPPUserAccount` that does `injectedUserAccount ?? accountsManager.userAccount(for: accountId)`. Then all 8 sites collapse to one call.
6. Write Test 8 in `AccountsManagerStateMachineWiringTests.swift`. The pattern is identical to Test 7 — same setup (`AccountsManager.deferInitialLoadCatalogsForTesting = true`), same fixtures. Drive the full A→nil→A→B round-trip through `startDownloadAsync`, NOT through `_setCapturedAccountId`.
7. Write `PalaceTests/MyBooks/MyBooksDownloadCenterAccountIdThreadingTests.swift` with 6 cases.
8. Run `harness test` from the worktree. If any pre-existing MBDC test fails, the constructor-injection seam may need a `capturedAccountId` parameter exposed for tests.
9. Run mutation: `python3 scripts/palace_mutate.py --file Palace/MyBooks/MyBooksDownloadCenter.swift --diff-only`.
10. Fill out the transcript.

**No force unwraps anywhere on the new code.** No new `.shared` reads — only existing `AppContainer.production()` may stay (in the legacy overload's resolver path, documented as the migration tail). Do NOT touch `AccountsManager.currentUserAccount` — that mitigation stays.

**Mandatory: round-trip wiring test** (Test 8). If your test can't exercise A→nil→A→B through `startDownloadAsync`, the seam isn't wired correctly — fix the seam, not the test.

Do NOT commit. Do NOT push. Stage for the integrator.
