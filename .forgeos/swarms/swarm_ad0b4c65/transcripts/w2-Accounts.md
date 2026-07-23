# Transcript — Wave-2 wall-clock-wait conversion, module Accounts (swarm_ad0b4c65)

Worked in worktree `.claude/worktrees/swarm_ad0b4c65-w2-accounts`, already on the
wave-1 seam commit (`b4e6ba841`), no new branch created. Scope:
`PalaceTests/Accounts/` only (includes the `AgeCheck/` subdirectory). Not
committed, not pushed.

## Files in scope (grep of the whole dir)

22 files under `PalaceTests/Accounts/` (including `AgeCheck/`); 14 contain any
`wait(for:|waitForExpectations|fulfillment(of:` occurrence.

## Files changed (2)

1. `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` — the 3
   flagged occurrences (asyncAfter+wait pair ~1258, while/Date+Thread.sleep+wait
   ~1305-1332).
2. `PalaceTests/Accounts/AccountsManagerTests.swift` — 4 `queue: .main`
   NotificationCenter-observer tests converted from
   expectation+`waitForExpectations`/`wait(for:)` to `drainMainQueue()`.

All other 12 files with wait occurrences were read in full and left byte-for-byte
unchanged (KEEP or UNMAPPED — see tallies below).

---

## 1. `AccountsManagerStateMachineWiringTests.swift`

### CONVERT/DELETE #1 — `testDriveCurrentAccountAuthDoc_staleEvictionMarker_redrives` (~line 1258)

Before:
```swift
let manager = makeFreshAccountsManager(defaults: defaults)
let backgroundSettled = expectation(description: "background loadCatalogs settled")
DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { backgroundSettled.fulfill() } // FLAKE-002-OK: background loadCatalogs settle window
wait(for: [backgroundSettled], timeout: 2.0)
```
After:
```swift
let manager = makeFreshAccountsManager(defaults: defaults)
// Deterministic barrier: `deferInitialLoadCatalogsForTesting` (pinned true by
// PalaceWiringTestCase) means `init` never spawns a background `loadCatalogs`
// Task, so there is nothing real to "settle" here — this was a fixed-delay
// pad. drainMainQueue() mirrors the identical manager-construction pattern a
// few tests up in this same file (`testLoadCatalogs_warmPath_...`).
drainMainQueue()
```

Verified against `Palace/Accounts/Library/AccountsManager.swift:577-586`: under
`deferInitialLoadCatalogsForTesting == true` (pinned by every
`makeFreshAccountsManager()` call, per `PalaceWiringTestCase`), `init` returns
**before** spawning the background `loadCatalogs` `Task.detached`. So the
0.4s wait was not actually waiting on any real background work from this
manager — a pure wall-clock pad. DELETEd; replaced with the already-established
`drainMainQueue()` primitive used by the sibling test's identical setup shape.

### CONVERT #2 — same test, ~line 1305-1332

Before: a hand-rolled `DispatchQueue.global().async { while Date() < deadline
{ ... Thread.sleep(0.05) ... } }` polling `AccountStateStore.shared.state(for:)`,
gated by an `XCTestExpectation` + `wait(for:timeout:4.0)`.

After:
```swift
awaitCondition(timeout: 4.0) {
    switch AccountStateStore.shared.state(for: currentUUID) {
    case .detailsLoading, .detailsLoaded, .detailsFailed:
        return true
    default:
        return false
    }
}
let observedFinalState = AccountStateStore.shared.state(for: currentUUID)
```
`awaitCondition` (from `PalaceTests/XCTestCase+drainMainQueue.swift`, NOT
edited) is exactly this file's own pre-existing bounded-poll primitive —
already used at line 384 (`testLoadCatalogs_warmPath_...`) and line 571
(`testLoadCatalogs_authDocFetchFails_...`) for the identical
"poll `AccountStateStore` until terminal" pattern. This mirrors an established
idiom rather than inventing anything; loud `XCTFail` on timeout instead of a
silently-stale read.

### Everything else in this file: read in full, left untouched

`AccountsManager._awaitAllCrawlTasksForTesting()` only wraps the `Task.detached`
spawned in `loadCatalogs`'s **cold, no-disk-cache** branch
(`Palace/Accounts/Library/AccountsManager.swift:1269-1297`,
`_trackFirstRunTask(firstRunTask)`). Every other wait in this file drives
`loadAccountSetsAndAuthDoc(fromCatalogData:key:)` or
`fetchAuthDocumentWithStateMachine(for:)` **directly** (bypassing that Task
entirely) or gates on a `Task`-based `AsyncStream` subscription to
`account.stateStream` — neither is tracked by the crawl-task seam, so awaiting
it there would return instantly without actually waiting for the real work.
Confirmed by reading `AccountsManager.swift:1858-1970` (loadAccountSetsAndAuthDoc)
and `:1700-1789` (fetchAuthDocumentWithStateMachine) — no seam covers either
call path directly.

| Line (orig) | Test | Bucket | Why |
|---|---|---|---|
| 262 | `testLoadCatalogs_currentAccountWithoutDetails_...` | UNMAPPED | direct `loadAccountSetsAndAuthDoc` call, not the tracked Task |
| 373 | `testLoadCatalogs_warmPath_drivesCurrentAccountPastBasicInfoLoaded` (`completionFired`) | KEEP | warm-path `completion?(true)` fires synchronously inside `loadCatalogs` before it returns (verified at `AccountsManager.swift:1219-1220`) |
| 471 | `testDriveCurrentAccountAuthDoc_terminalState_isNoOp` (`firstEmission`) | UNMAPPED | Task/AsyncStream subscription-attached gate on `account.stateStream`, no seam |
| 555 | `testLoadCatalogs_authDocFetchFails_drivesDetailsFailed` (`subscribed`) | UNMAPPED | same subscription-gate pattern |
| 562 | same test (`exp`) | UNMAPPED | direct `fetchAuthDocumentWithStateMachine` call, no seam |
| 960 | `testSingleFlight_twoConcurrentAwaiters_oneNetworkRequest` (`subscribed`) | UNMAPPED | subscription gate |
| 984 | same test (`exp1, exp2, observed`) | UNMAPPED | two direct `fetchAuthDocumentWithStateMachine` calls + stream, no seam |
| 1205 | `testLibraryReselect_reentry_resetsState_andRedrives` | UNMAPPED | stream-emission gate after direct `_setState` |
| 1429 (orig 1436) | `testDriveCurrentAccountAuthDoc_realAccountNotFound_doesNotRedrive` | UNMAPPED | subscription gate |

(Full per-file bucket table for the OTHER 12 files is below.)

---

## 2. `AccountsManagerTests.swift`

4 `NotificationCenter.addObserver(..., queue: .main, ...)` tests converted.
`queue: .main` delivers the observer block **asynchronously** on the main
queue regardless of the posting thread (Apple-documented — non-nil `queue`
always dispatches, never runs synchronously inline), so these are genuine
async hops, not synchronous callbacks. `drainMainQueue()` (from
`XCTestCase+drainMainQueue.swift`, not edited) is documented in that very file
as designed for exactly this case: *"Use after async work whose downstream
main-queue dispatch (Combine `.receive(on: .main)`, **NotificationCenter post
on a main observer**, subject.send() chains) needs to land before the next
assertion."*

Converted:
- `testCurrentAccount_WhenChanged_PostsNotification` (was line 190)
- `testUseBetaDidChange_PostsNotificationWhenSettingChanges` (was line 402)
- `testNotificationObserver_ForAccountChange_CanBeAdded` (was line 580)
- `testMultipleNotificationObservers_AllReceiveAccountChange` (was line 618,
  `wait(for: [expectation1, expectation2])` → single `drainMainQueue()`, since
  both `.main`-queue observers are FIFO-enqueued ahead of the drain's own
  no-op)

Pattern: `expectation.fulfill()` removed from inside the observer closure;
`NotificationCenter.default.post(...)` unchanged; `waitForExpectations`/
`wait(for:)` replaced with `drainMainQueue()`; assertions unchanged.

### Left untouched — verified NOT the same shape

- `testUpdateAccountSet_WithCompletion_CallsCompletion` (line ~461,
  `waitForExpectations(timeout: 5.0)`): guarded by
  `XCTSkipUnless(accountsHaveLoaded)`. Read
  `AccountsManager.updateAccountSet(completion:)` (swift:2019-2031) — when
  `accountSets[hash]` is already non-empty (the only way this test runs),
  it takes the `else` branch and calls `completion?(true)` **synchronously**,
  never reaching `loadCatalogs`. KEEP (bucket 1: direct synchronous callback).
- `testAccountLookup_FromMultipleThreads_DoesNotCrash` / `testAccounts_FromMultipleThreads_DoesNotCrash`
  (100-iteration `DispatchQueue.global` stress tests, direct `expectation.fulfill()`
  per iteration): KEEP — concurrency stress tests with no catalog seam,
  `expectedFulfillmentCount` pattern is the correct primitive for this shape.
- `testNotification_CanBeObservedWithCombine` / `testCatalogDidLoadNotification_CanBeObservedWithCombine`:
  these use `NotificationCenter.default.publisher(for:)` (Combine), **not**
  `addObserver(queue:)`. Combine's `NotificationCenter.Publisher` delivers
  synchronously on the posting thread (no scheduler applied, unlike the
  `queue: .main` `addObserver` API) — `.sink` fires inline during `post()`.
  KEEP (bucket 1: direct synchronous callback), deliberately NOT converted
  even though superficially similar to the 4 above.

---

## Per-file bucket tallies — remaining 12 files (all read in full, zero edits)

| File | Occurrences | Bucket | Notes |
|---|---|---|---|
| `TPPPerAccountIsolationTests.swift` | 164, 213 | KEEP ×2 | `expectedFulfillmentCount` over 100 concurrent `DispatchQueue.global` keychain writes, direct `fulfill()`; no seam (TPPUserAccount/Keychain aren't cataloged) |
| `TPPCredentialIsolationE2ETests.swift` | 164 | KEEP ×1 | same shape, 500-iteration concurrency stress test |
| `AccountsManagerCacheReadTests.swift` | 259 | KEEP ×1 | direct `loadAccountSetsAndAuthDoc` call (real decode of local fixture, no network); already annotated `FLAKE-003-OK`; no seam covers this call path |
| `AccountModelTests.swift` | 286 | KEEP ×1 | `account.loadAuthenticationDocument` with nil `authenticationDocumentUrl` — guard fires `completion(false)` synchronously (`Account.swift:777-786`) |
| `AccountsManagerCancellationTests.swift` | 437, 454, 459 | KEEP ×3 | controlled-Task/`withCheckedContinuation` cancellation-race rig (its own mock-clock contract per KEEP bucket 3); 459 is an inverted "must NOT fire" 0.5s window (KEEP bucket 2 exactly) |
| `UserAccountPublisherTests.swift` | 199, 219, 242, 266 | KEEP ×4 | Combine `.sink` with no `.receive(on:)` — fires synchronously inside `markLoggedIn()`/`signOut()`/etc. |
| `AccountStateMachineTests.swift` | 151, 176, 233, 280, 394 | UNMAPPED ×5 | `Account.awaitReady()` / `account.stateStream` — Account itself has no catalog seam; state flips are driven directly via `_setState()` in the test body, so the wait is on the awaiter Task noticing it, not on a seam-trackable production async op |
| `AccountStateMachineTests.swift` | 276 | KEEP ×1 | subscription-attached gate (mirrors the established idiom, not a wall-clock guess) |
| `AccountsManagerLaunchSnapshotTests.swift` | 245, 521 | KEEP ×2 | direct `loadAccountSetsAndAuthDoc` calls, already `FLAKE-003-OK` annotated |
| `AccountsManagerLaunchSnapshotTests.swift` | 320 | KEEP ×1 | `isInverted = true` negative "must not clobber" 1.0s window — bucket-3 KEEP verbatim; comment already notes it replaced a prior fixed-sleep (FLAKE-002) |
| `AccountProfileDocumentTests.swift` | 52, 102, 138 | KEEP ×3 | `getProfileDocument` gate short-circuits synchronously (nil details / no credentials / nil profileUrl) — test even asserts elapsed `< 1.0s` to prove no network fired |
| `AccountSwitchCleanupTests.swift` | 45, 74, 103 | KEEP ×3 | real `TPPNetworkExecutor.GET` over `HTTPStubURLProtocol`. **Checked and rejected** converting to the `TPPNetworkExecutor._awaitInFlightForTesting()` catalog seam: that seam only joins the executor's retained token-refresh/retry-drain `Task`s (`TPPNetworkExecutor.swift:304-352`); a plain `GET` with no refresh needed never populates `pendingTestTasks`, so awaiting the seam would return immediately without actually waiting for the stubbed completion — would have silently broken these tests. |
| `AccountsManagerCacheTests.swift` | 267 | KEEP ×1 | `NotificationCenter.addObserver(..., queue: nil, ...)` — nil queue delivers synchronously on the posting thread, unlike the `queue: .main` cases converted above |
| `AgeCheck/TPPAgeCheckStateMachineTests.swift` | 103 | KEEP ×1 | `isInverted = true`, 0.2s window — bucket-3 KEEP verbatim |
| `AgeCheck/TPPAgeCheckStateMachineTests.swift` | 108, 133, 161, 185 | UNMAPPED ×4 | `TPPAgeCheck.verifyCurrentAccountAgeRequirement` (awaits `account.awaitReady()` on its own serial queue) — TPPAgeCheck has no catalog seam |

Total across these 12 files: **KEEP 22, UNMAPPED 9** (31 occurrences, matches
the per-file grep counts below).

---

## Verification (per playbook)

### `wait(for:|waitForExpectations|fulfillment(of:` — before → after, changed files only

```
$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift
before: 11   after: 9
```
Remainder (9) = 1 KEEP (line 373) + 8 UNMAPPED (262, 471, 555, 562, 960, 984,
1205, 1429). No silent drop — the 2 removed lines are exactly the 2
CONVERTed occurrences (asyncAfter+wait pair, while-loop+wait pair).

```
$ grep -c 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Accounts/AccountsManagerTests.swift
before: 9   after: 5
```
Remainder (5) = 5 KEEP (460/updateAccountSet, 501/524 concurrency stress,
651/675 Combine-sync). 4 converted (190, 402, 580, 618).

### Directory-wide, all 14 files with hits

```
$ grep -rc 'wait(for:\|waitForExpectations\|fulfillment(of:' PalaceTests/Accounts/*.swift PalaceTests/Accounts/AgeCheck/*.swift | awk -F: '$2>0{s+=$2} END {print s}'
before: 53   after: 47
```

Reconciliation, per-file occurrence count → bucket split (every occurrence is
named by line number in the tables above; this is the count, not a re-derivation):

| File | Occurrences (post-edit) | KEEP | UNMAPPED |
|---|---|---|---|
| AccountsManagerStateMachineWiringTests.swift | 9 | 1 | 8 |
| AccountsManagerTests.swift | 5 | 5 | 0 |
| TPPPerAccountIsolationTests.swift | 2 | 2 | 0 |
| TPPCredentialIsolationE2ETests.swift | 1 | 1 | 0 |
| AccountsManagerCacheReadTests.swift | 1 | 1 | 0 |
| AccountModelTests.swift | 1 | 1 | 0 |
| AccountsManagerCancellationTests.swift | 3 | 3 | 0 |
| UserAccountPublisherTests.swift | 4 | 4 | 0 |
| AccountStateMachineTests.swift | 6 | 1 | 5 |
| AccountsManagerLaunchSnapshotTests.swift | 3 | 3 | 0 |
| AccountProfileDocumentTests.swift | 3 | 3 | 0 |
| AccountSwitchCleanupTests.swift | 3 | 3 | 0 |
| AccountsManagerCacheTests.swift | 1 | 1 | 0 |
| AgeCheck/TPPAgeCheckStateMachineTests.swift | 5 | 1 | 4 |
| **Total** | **47** | **30** | **17** |

47 = 30 KEEP + 17 UNMAPPED, no silent drop. Before (53) − after (47) = 6
CONVERTed (2 in the Wiring file, 4 in AccountsManagerTests) — matches the
"Files changed" section exactly.

### Sleep/deadline-poll family — must be empty after

```
$ grep -rnE 'Thread\.sleep|usleep|asyncAfter.*fulfill|while.*Date\(\).*<' PalaceTests/Accounts/
PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift:1313: (comment text only, documents the removed pattern)
PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift:1314: (comment text only)
```
No live code matches — both hits are inside the explanatory comment left at
the conversion site. Confirmed empty of actual `Thread.sleep`/`usleep`/
`asyncAfter{fulfill}`/`while Date()<deadline` code.

### Bounded-await proof

Every `await` added targets an already-approved bounded primitive from
`PalaceTests/XCTestCase+drainMainQueue.swift` (not edited, off-limits file):
- `drainMainQueue()` ×5 call sites (1 in WiringTests, 4 in AccountsManagerTests)
  — synchronous barrier, bounded by its own internal `wait(for:timeout: 5.0)`.
- `awaitCondition(timeout: 4.0) { ... }` ×1 call site (WiringTests) — bounded
  poll with `Task.isCancelled`-first ordering and `XCTFail` on timeout, per
  the helper's own doc comment.

No bare `await someTask.value` on a raw unbounded handle was introduced
anywhere. No catalog seam (`_awaitAllCrawlTasksForTesting`,
`_awaitPendingWritesForTesting`, `_awaitInFlightForTesting`,
`_awaitDownloadDispatchForTesting`) was invoked from this module's tests —
none of the Accounts-directory waits actually map onto a tracked seam call
path (see the `loadCatalogs` vs. direct-call analysis above), so none were
added.

### Off-limits confirmation

- No edits to `Palace/**` (read-only: `AccountsManager.swift`, `Account.swift`,
  `TPPNetworkExecutor.swift` — to confirm seam applicability before deciding
  NOT to use them in 2 places).
- No edits to `PalaceTests/XCTestCase+drainMainQueue.swift`.
- No other module's test dir touched.
- `git status --short` shows exactly the 2 files listed under "Files changed".
- Not committed, not pushed.

```
$ git status --short
 M PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift
 M PalaceTests/Accounts/AccountsManagerTests.swift
```
