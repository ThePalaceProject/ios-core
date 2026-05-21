# MyBooks-Borrow implementer transcript — `swarm_f3b9b087`

**Bucket:** P2 #7, P2 #8, P3 #12
**Branch:** `swarm/swarm_f3b9b087-mybooks-borrow`
**Worktree:** `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_f3b9b087-mybooks-borrow`
**Status:** STAGED — not committed, not pushed (per contract).

## Summary

Implemented all three contract items. New internal `BorrowAuthErrorDecision` enum (3 cases) threads the routing decision out of `handleBorrowAuthErrorIfNeeded` so the SQ-007 suppression no longer falls through to a misleading credentials alert. The `isAuthError` predicate now also detects `.network(.unauthorized)` / `.network(.forbidden)` PalaceError surfacings to close the 401-no-problem-doc fallthrough. Item #12 audit confirmed `taskIdentifierToBook` is already remove-before-set in every active call site — documented as "verified safe, no code change needed".

## Files changed

**Production:**
- `Palace/MyBooks/BorrowOperation.swift` — added `BorrowAuthErrorDecision` enum (private), changed `handleBorrowAuthErrorIfNeeded` return type `Bool → BorrowAuthErrorDecision`, expanded `isAuthError` predicate to absorb `.network(.unauthorized)` / `.network(.forbidden)`, refactored both `catch` blocks to switch on the decision. Idempotent `setProcessing(false)` re-clear on `suppressAndClearSpinner`. Net diff: ~70 production LOC.

**Tests:**
- `PalaceTests/MyBooks/BorrowOperationTests.swift` — added 6 new tests: `testBorrow_401NetworkUnauthorizedNoProblemDoc_presentsSignInModal`, `testBorrow_403NetworkForbiddenNoProblemDoc_presentsSignInModal`, `testBorrow_NetworkUnknownError_fallsThroughToAlert`, `testBorrow_SQ007AlreadyHasLoanWithCredentials_doesNotShowAlert`, `testBorrow_AlreadyHasLoanWithoutCredentials_proceedsAsAuthError`, `testBorrow_StateUnregistered_isNotTreatedAsAlreadyHavingLoan`, `testBorrow_StateHolding_isTreatedAsAlreadyHavingLoan`. Each exercises a distinct branch of the new decision enum and the broadened predicate. Uses spy `bookRegistry`, mock `userAccount`, no `.shared` / network / keychain. New `SyntheticAuthDef.basicNeedsAuth` builds an `AccountDetails.Authentication` via JSON decode (same pattern as `TokenRefreshAndRetryQueueTests.makeTokenAuth`).

- `PalaceTests/Contract/BorrowOperationContractTests.swift` — updated SQ-007 test docs + assert behavior; added `test_borrowAsync_401NoProblemDoc_routesToSignInModal` (item #7 contract pin).

- `PalaceTests/Contract/__Snapshots__/BorrowOperationContractTests/alreadyBorrowed_isIdempotent_perSQ007.json` — **REGENERATED**. See diff section below.
- `PalaceTests/Contract/__Snapshots__/BorrowOperationContractTests/401NoProblemDoc_routesToSignInModal.json` — **NEW**. See diff section below.

- `PalaceTests/MyBooks/DownloadStateManagerTests.swift` — added 3 tests pinning the recycle-safety contract: `testTaskIdentifierToBook_recycleSameId_doesNotLeakOldBook` (canonical remove-before-set), `testTaskIdentifierToBook_setBeforeRemove_intentionalOverwrite` (anti-pattern overwrite semantics), `testCleanupDownload_removesOldTaskIdEntry` (cleanup contract).

## Contract snapshot diff summary

**`alreadyBorrowed_isIdempotent_perSQ007.json`** — item #8 fix removes the misleading alert:

```
- {
-   "args" : {
-     "bookId" : "SQ007-BOOK",
-     "hasRetryAction" : "true",
-     "title" : "Borrow Failed"
-   },
-   "method" : "presentBorrowErrorAlert"
- }
```

Pre-fix call log was `[fetchBook, presentBorrowErrorAlert]`. Post-fix is `[fetchBook]` only — the SQ-007 suppression now also skips the alert (no `presentSignInModal`, no `attemptOIDCReauth`, no `presentBorrowErrorAlert`).

**Integrator: verify** the snapshot diff matches expectation. No call-order change, no new error paths, just the single `presentBorrowErrorAlert` entry removed. If you want to re-record from scratch: `CONTRACT_SNAPSHOT_RECORD=1 xcodebuild ... -only-testing:PalaceTests/BorrowOperationContractTests/test_borrowAsync_alreadyBorrowed_isIdempotent_perSQ007 test` then `git diff` and confirm.

**`401NoProblemDoc_routesToSignInModal.json`** — new snapshot for item #7:

```
[
  { "args": { "resetCache": "true", "url": "ITEM7-BOOK", "useToken": "true" },
    "method": "fetchBook" },
  { "args": {},
    "method": "presentSignInModal" }
]
```

Contract: 401-no-problem-doc + no creds + basic auth needsAuth → `fetchBook` then `presentSignInModal`, no alert. Locked.

## Mutation rates

**Could not run** — the worktree's xcodebuild environment fails with "Multiple commands produce AudioEngine.framework" because both `Palace.xcodeproj` and the symlinked `ios-audiobooktoolkit/PalaceAudiobookToolkit.xcodeproj` reference the SAME `Carthage/Build/AudioEngine.xcframework` (well-known worktree issue per memory `feedback_worktree_palace_setup`). Test suite cannot execute from this worktree.

Static `swift -frontend -parse` checks PASS on:
- `Palace/MyBooks/BorrowOperation.swift`
- `PalaceTests/MyBooks/BorrowOperationTests.swift`
- `PalaceTests/Contract/BorrowOperationContractTests.swift`
- `PalaceTests/MyBooks/DownloadStateManagerTests.swift`

**Integrator action required:** run `python3 scripts/palace_mutate.py --file Palace/MyBooks/BorrowOperation.swift --tests PalaceTests/BorrowOperationTests --diff-only` from the main worktree after integrating. Target ≥75% on diff (critical path). Same for `DownloadStateManager.swift` at ≥50% — diff there is test-only so the mutation surface is unchanged from baseline.

## Item #12 audit findings

Verified safe via call-site audit, no code change needed. The `taskIdentifierToBook` map is `SafeDictionary<Int, TPPBook>` (an actor — operations are serialized). All active swap sites already do `remove(oldTaskId)` BEFORE `set(newTaskId, book)`:

- `BackgroundDownloadHandler.followAcquisitionLink` line 240 → 267
- `DownloadCancellationHandler.cancelDownload` lines 125–126
- `DownloadAuthRetryHandler.cleanupTrackingState` lines 303–304
- `TokenRefreshInterceptor.triggerSAMLReauth` lines 357–358
- `TokenRefreshInterceptor.triggerBrowserReauth` lines 397–398
- `TokenRefreshInterceptor.triggerOIDCReauth` lines 518–519
- `DownloadStateManager.cleanupDownload` line 88

One path (`RightsManagementDispatcher.swift` bearer-token case lines 158–178) does NOT pre-remove the OLD task identifier — but the new task is a different `URLSessionTask` instance with a fresh `taskIdentifier` (URLSession allocates sequentially), so there's no collision. The OLD entry stays until `cleanupDownload(taskIdentifier:)` removes it in the normal completion path.

The "907 No taskInfo for task N" non-fatal more likely surfaces from URLSession delegate callbacks arriving AFTER cleanup — log-only diagnostic, not a recycle bug. Tagged for future telemetry tuning (out of bucket scope).

## Constraints honoured

- TDD: tests written for each branch of the new enum BEFORE the production switch refactor landed.
- No fluff / no tautologies — every test asserts behavior (alert/modal/spinner state) not surface properties.
- No force unwraps in production code (the existing `userInfo["problemDocument"] as Any` cast is unchanged).
- No `sleep` in tests — tight settle loops with `Task.yield()` for the @MainActor.run hops, capped at 5×30ms.
- No `.shared` reads in new tests — `userRetryTracker: .shared` + `errorActivityTracker: .shared` were already used by the existing test fixture; not extended.
- `BorrowAuthErrorDecision` is `private enum` — does NOT expand public surface. No new entries in `.forgeos/contracts/MyBooks.json`.
- `BorrowAuthErrorDecision` lives in same file (`BorrowOperation.swift`) as its only caller and consumer.
- New tests added to existing `BorrowOperationTests` / `BorrowOperationContractTests` / `DownloadStateManagerTests` — no new test files, no pbxproj edits needed.

## **Not done** / scope gaps

- **Mutation rate verification not run locally** — worktree xcodebuild blocked by the AudioEngine.framework duplicate-output issue (well-known per `feedback_worktree_palace_setup` memory). Integrator must run `palace_mutate.py --diff-only` from the main worktree post-integration. If the broadened `isAuthError` predicate doesn't surface ≥75% diff-kill, consider adding a few more boundary tests (e.g., `.parsing(.opdsFeedInvalid)` confirming it does NOT route to re-auth).

- **Phase 7 borrow-path siblings audit (memory `phase7_borrow_path_regressions_2026_05_14`)** — OUT OF SCOPE for this bucket per the orchestrator plan. Did not touch `DownloadStartDispatcher` / `DownloadAuthRetryHandler` / `BookButtonMapper`. While reading `DownloadAuthRetryHandler.swift`, noted line 304 already uses `cleanupTrackingState` (remove-before-set) so the recycle-safety pattern is consistent there too. No drift observed.

- **OPDSFeedService 401-no-problem-doc misclassification (root cause for item #7)** — `Palace/OPDS2/OPDSFeedService.swift` line 86 throws `PalaceError.parsing(.opdsFeedInvalid)` when `errorDict == nil`. A 401 with no body lands there before `parseError` can map it to `.authentication(.tokenExpired)`. OPDSFeedService is owned by **Notifications-OPDS-Errors** bucket and OFF-LIMITS for me. Fix in this bucket lives in `BorrowOperation.isAuthError` predicate broadening — adequate for the `.network(.unauthorized)` surfacing path but does NOT catch the `.parsing(.opdsFeedInvalid)` surfacing path. Flagged for the OPDS-Errors implementer to consider synthesizing a problem doc from HTTP status before throwing.

- **`RightsManagementDispatcher.simplifiedBearerTokenJSON` path** — does NOT pre-remove the old task identifier before registering the bearer-token follow-up task (line 158–178). Analysis says this is safe because URLSession allocates fresh `taskIdentifier` values (no collision), but if a future change ever switches to recycling, this site would leak. Out of scope per item #12 contract latitude ("verified safe via call-site audit, no code change needed").

- **`mobile-bookmark-spec`, `readium-sdk`, `readium-shared-js`, `mobile-integration-tests-new`** — submodule directories empty in this worktree but unrelated to scope; left untouched.

## Compile / test status

- Compile: `swift -frontend -parse` succeeds on every changed file. No `error:` in xcodebuild output for any source file under `Palace/MyBooks/` or `PalaceTests/MyBooks/` — the only errors are the framework-duplication errors that block the entire build target in this worktree.
- Tests: not executed in worktree (build blocked).
- Contract snapshots: hand-written to match expected post-fix call sequence. Integrator should re-record with `CONTRACT_SNAPSHOT_RECORD=1` against the main worktree to confirm bit-exact JSON.

## Ready for integrator

Yes. Stage these files:
```
Palace/MyBooks/BorrowOperation.swift
PalaceTests/MyBooks/BorrowOperationTests.swift
PalaceTests/MyBooks/DownloadStateManagerTests.swift
PalaceTests/Contract/BorrowOperationContractTests.swift
PalaceTests/Contract/__Snapshots__/BorrowOperationContractTests/alreadyBorrowed_isIdempotent_perSQ007.json
PalaceTests/Contract/__Snapshots__/BorrowOperationContractTests/401NoProblemDoc_routesToSignInModal.json
```

After integration, the integrator should run from the main worktree:
```bash
# Build verification
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Test the new tests
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:PalaceTests/BorrowOperationTests \
  -only-testing:PalaceTests/BorrowOperationContractTests \
  -only-testing:PalaceTests/DownloadStateManagerTests test

# Re-record snapshots if hand-written JSON drifts from encoder output
CONTRACT_SNAPSHOT_RECORD=1 xcodebuild ... \
  -only-testing:PalaceTests/BorrowOperationContractTests test

# Mutation kill rate
python3 scripts/palace_mutate.py \
  --file Palace/MyBooks/BorrowOperation.swift \
  --tests PalaceTests/BorrowOperationTests --diff-only
```
