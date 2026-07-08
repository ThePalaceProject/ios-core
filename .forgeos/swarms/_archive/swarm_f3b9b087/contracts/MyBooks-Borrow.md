---
name: swarm_f3b9b087-contract-MyBooks-Borrow
type: immutable
status: active
created: 2026-05-21T03:25:00Z
last_refresh: 2026-05-21
freshness_window: never
owners: [mybooks]
description: "Contract: MyBooks-Borrow"
---

# Contract: MyBooks-Borrow

**Bucket items:** P2 #7, #8 + P3 #12 (BorrowOperation 401-no-problem-doc fallthrough + SQ-007 spinner cleanup + Downloads task-identifier recycle)
**Priority:** P2 borrow path + P3 download task map. Borrow flow is a critical path per CLAUDE.md.
**LOC estimate:** ~350–500 LOC (production + tests)

## Scope summary

Three connected defects in MyBooks borrow + download:

1. **`BorrowOperation` 401-with-no-problem-document fallthrough (line ~431–437)** — when a borrow throws `PalaceError.authentication` but `originalError` is `nil` and `problemDocument` is `nil`, `handleBorrowAuthErrorIfNeeded` invokes with `problemDocument: nil`. The inner `isAuthError` predicate (line 472–495) inspects `problemDocument.type` AND `nsError.code` only — when both signals are absent, a `PalaceError.authentication` still resolves true via the `if case .authentication = error { return true }` clause, BUT subsequent code paths (e.g. the SQ-007 spinner-cleanup at line 505–520, the re-auth attempt) may not have the context they need. Need: confirm the no-problem-doc branch reliably reaches `clearProcessingState` and surfaces an actionable error; add a regression test pinning behavior.
2. **SQ-007 spinner cleanup (line ~505–520)** — when `alreadyHasLoan && hasCredentials`, the code returns `false` from `handleBorrowAuthErrorIfNeeded` (suppressing the error UI). BUT the caller in `do { ... } catch let error as PalaceError` at line 428–438 then proceeds to `showBorrowError(error, ...)`. This means SQ-007 suppression is partial: re-auth is suppressed but the error toast still fires. Patron sees a misleading "credentials problem" alert for a benign already-borrowed condition. Need: thread an additional signal (e.g. return an enum `BorrowAuthErrorDecision { case reAuthAttempted, suppressedBenign, showError }`) so the caller can skip `showBorrowError` for the suppressed-benign case. Memory ref: `phase7_borrow_path_regressions_2026_05_14`.
3. **`DownloadStateManager.taskIdentifierToBook` recycle bug (Downloads-TaskMap merged here)** — `SafeDictionary<Int, TPPBook>` keyed by `URLSessionTask.taskIdentifier`. iOS recycles task identifiers within a session; if a cancelled task's entry isn't removed before a new task with the same identifier is registered, the new task will resolve to the wrong book. Search `MyBooksDownloadCenter.swift` (line ~1108–1170) + `BackgroundDownloadHandler.swift` (line 240, 267) for set/remove ordering. Need: audit and lock down the contract that `remove(taskId)` ALWAYS precedes `set(newTaskId, book)` even when the new task is created in a callback nested inside the old task's completion handler.

## Files in scope

- `Palace/MyBooks/BorrowOperation.swift` (lines 428–520; possibly add a new `BorrowAuthErrorDecision` enum at the top of the file or in a new file)
- `Palace/MyBooks/DownloadStateManager.swift` (audit `taskIdentifierToBook` ownership; possibly add a `swap(oldTaskId:newTaskId:book:)` helper for the recycle-safe path)
- `Palace/MyBooks/BackgroundDownloadHandler.swift` (call-site that does `remove` then `set` — use the new helper if added)
- `Palace/MyBooks/MyBooksDownloadCenter.swift` (line ~1108–1170: audit, do NOT broadly refactor)
- `PalaceTests/MyBooks/BorrowOperationTests.swift` (extend)
- `PalaceTests/Contract/BorrowOperationContractTests.swift` (extend — contract snapshot for the new decision-enum threading)
- `PalaceTests/MyBooks/DownloadStateManagerTests.swift` (extend)

## Files OFF-LIMITS

- Anything in `Palace/Reader2/`, `Palace/Audiobooks/`.
- `Palace/Notifications/NotificationService.swift`.
- `Palace/ErrorHandling/PalaceError.swift` — owned by **OPDS-Errors** bucket. If you discover you need a new `PalaceError` case for the SQ-007 decision, DO NOT add it; thread through the new internal enum instead.
- `Palace/OPDS2/OPDSFeedService.swift`.

## Public type / protocol / signature changes

- New internal enum `BorrowAuthErrorDecision` (private to BorrowOperation OR file-private in a new file under MyBooks). NOT a public API.
- `handleBorrowAuthErrorIfNeeded` signature changes from `-> Bool` to `-> BorrowAuthErrorDecision`. This is private — change all call sites in the same file.
- `DownloadStateManager` may grow a `swap(oldTaskId:newTaskId:book:)` async method. This IS public-ish (the protocol `DownloadStateManagerProtocol` at line ~19). If you add it, add to the protocol too; update `MyBooks.json` contract snapshot manually if `scripts/export-module-contracts.py` doesn't pick it up cleanly.

## DI seam updates

- `BorrowOperation` already has heavy DI (`userAccountProvider`, `bookRegistry`, `reauthenticator`, etc.). No new dependencies — thread the decision-enum through the existing closure injection.
- `DownloadStateManager` is referenced via `DownloadStateManagerProtocol`. Existing tests use a fake implementation — extend that fake.

## Test contracts (CRITICAL PATH — mutation-killing MANDATORY for borrow flow)

### `BorrowOperationTests` (extend; mutation-killing **required**)

- `testBorrow_AuthErrorWithNoProblemDocAndNoOriginalError_clearsProcessingAndShowsError` — pin the path through item #7.
- `testBorrow_AlreadyHasLoanWithCredentials_suppressesErrorAndDoesNotShowToast` — kill the SQ-007 mutant. Spy on `showBorrowError` invocations; assert count == 0.
- `testBorrow_AlreadyHasLoanWithoutCredentials_proceedsAsAuthError` — boundary opposite case.
- `testBorrow_StateUnregistered_isNotTreatedAsAlreadyHavingLoan` — pin the switch-case exhaustiveness.
- `testBorrow_StateHolding_isTreatedAsAlreadyHavingLoan` — boundary on the `holding` case.
- All tests use spy `BookRegistry`, spy `UserAccountProvider`. NEVER `.shared`. NEVER `TPPBookRegistry.shared`.

Mutation surface:
```
python3 scripts/palace_mutate.py \
  --file Palace/MyBooks/BorrowOperation.swift \
  --tests PalaceTests/MyBooks/BorrowOperationTests \
  --diff-only
```
Required kill rate: **≥75%** on diff (critical path).

### `BorrowOperationContractTests` (extend)

Update the contract snapshot to reflect the new `BorrowAuthErrorDecision` threading. Existing snapshots in `__Snapshots__/BorrowOperationContractTests/` will need to be re-recorded — set `CONTRACT_SNAPSHOT_RECORD=1` and review the diff carefully (CLAUDE.md "Contract-snapshot tests" section). The diff should show:
- New decision values in the call log
- `setProcessing(false)` ordering unchanged
- No new dependency calls
If the diff shows ANY of: dependency-call-count change, ordering change beyond the new enum value, or new error paths — STOP and consult integrator.

### `DownloadStateManagerTests` (extend; mutation-killing recommended)

- `testTaskIdentifierToBook_recycleSameId_doesNotLeakOldBook` — register taskId=42→bookA, remove, register taskId=42→bookB, assert get(42) == bookB and bookA is NOT findable by any taskId.
- `testTaskIdentifierToBook_setBeforeRemove_intentionalOverwrite` — pin the existing overwrite semantics.
- If `swap(oldTaskId:newTaskId:book:)` is added, test that it's atomic (no in-between state observable).
- Use the existing fake from `PalaceTests/Mocks/` — `BookRegistry` mock pattern.

## Acceptance criteria

- `scripts/verify-pr.sh --quick` passes.
- Mutation kill rate ≥75% diff-scoped for `BorrowOperation.swift`. ≥50% for `DownloadStateManager.swift`.
- Contract snapshot updates committed with `CONTRACT_SNAPSHOT_RECORD=1` and reviewed for correctness.
- No `.shared`, no Keychain, no real network in tests.
- No new user-facing copy.
- If you change a public protocol surface (`DownloadStateManagerProtocol`), update or regenerate the relevant entry in `.forgeos/contracts/MyBooks.json` so verify-pr.sh's contract check doesn't trip.
- New Swift files (if any) added to BOTH targets via `pbxproj_add_swift.rb`.
- Commit message has `**Scope:**` + `**Not done:**` stanzas. Item #12 specifically: if you find the bug doesn't actually manifest because the codebase already does remove-before-set everywhere, document that in the `**Not done:**` stanza as "verified safe via call-site audit, no code change needed."
- DO NOT commit. DO NOT push.
- Aware of: memory `phase7_borrow_path_regressions_2026_05_14` calls out siblings audit for `DownloadStartDispatcher` / `DownloadAuthRetryHandler` / `BookButtonMapper`. Those are OUT OF SCOPE for this bucket but flag any drift you notice in the `**Not done:**` stanza.
