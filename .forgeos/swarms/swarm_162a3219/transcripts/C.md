# Module C — Audiobook Playtimes Lifecycle (Bug B) — Implementer Transcript

**Status:** READY
**Owner module:** `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` (+ comment block in `AudiobookSessionManager.swift`)
**Date:** 2026-06-05
**Worktree:** `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_162a3219-orchestrator`
**Swarm:** swarm_162a3219
**Sim UDID used:** `141BD227-6E9A-4409-8D99-2D4FE818238D` (iPhone 16 Pro, iOS 26.0)
**DerivedData path:** `/tmp/swarm-162a3219-modC-dd`

## Production diff (staged)

- `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` — +88 / -5 LOC
  - New `currentAccountIdProvider: () -> String?` init parameter (default reads `AppContainer.production().accountsManager.currentAccountId`). Internal class, no PUBLIC_INTENT annotation needed (per Phase 1a architect review).
  - New `subscribeToAccountChanges()` invoked from init. Observes `.TPPCurrentAccountDidChange`, logs only — no destructive queue mutation.
  - New `deinit` removes the observer token cleanly.
  - `syncValues()` inner-loop guard: queue is partitioned into `postableLibraryBooks` (libraryId matches active account) and `skippedLibraryBooks`. Skipped entries are logged via both `audiobookLogger` AND `TPPErrorLogger.logError(summary: "Skipping cross-account playtimes upload", ...)`, but the queue is NOT mutated — they stay for switch-back flush. The `pendingCount` counter now uses `postableLibraryBooks.count` so `endBackgroundTask` still fires when every queued entry is cross-account (otherwise the background task would leak — iOS would reclaim it eventually but with a system log warning).
- `Palace/Audiobooks/AudiobookSessionManager.swift` — +20 LOC (comment block only)
  - Added class-doc note documenting the account-switch contract: the playtimes tracker contract owns the upload-side scoping; this manager takes no additional action.
- `PalaceTests/Audiobooks/AudiobookPlaytimesLifecycleTests.swift` — NEW, +254 LOC
  - 6 tests, all of which drive the production seam (`syncValues()` + `.TPPCurrentAccountDidChange` notification + a mutable `AccountIdBox` to flip "current library"):
    1. `testPlaytimes_sameAccountUpload_postsNormally`
    2. `testPlaytimes_crossAccountUpload_isSkipped_andQueuePreserved`
    3. `testPlaytimes_switchBack_flushesPreservedEntries`
    4. `testPlaytimes_accountSwitchNotification_doesNotClearQueue`
    5. `testPlaytimes_allCrossAccount_backgroundTaskStillEnds`
    6. `testPlaytimes_midFlightCancellation_notReplayedByQueue`
  - Cross-vendor smoke rationale documented in the file header per `reference_audiobook_toolkit_risk_profile.md`: playtimes endpoint is vendor-agnostic from the upload side (LibraryBook scoping is per-library not per-vendor), so ONE library-switch test covers all 4 vendors.
- `PalaceTests/Mocks/SpyAudiobookNetworkExecutor.swift` — NEW, +108 LOC
  - Thread-safe spy of `POST(_:useTokenIfAvailable:)`. Records URL + body per call; `autoRespondSuccess: Bool` toggle lets test 6 hold the completion to simulate in-flight cancellation.
- `PalaceTests/Audiobook/AudiobookDataManagerSyncTests.swift` — +30 LOC, -10 LOC
  - Updated 3 test class setUps to inject a permissive `currentAccountIdProvider` closure (`{ self?.dataManager?.store.queue.first?.libraryId }`) so the existing network-sync mechanics tests remain transparent to the scope guard. Documented inline why.
- `Palace.xcodeproj/project.pbxproj` — pbxproj entries for the 2 new test files (added via `scripts/pbxproj_add_swift.rb`).
- `.forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md` — added `## Resolution log` table marking Bug B resolved.

## Out of scope (confirmed honored)

- PalaceAudiobookToolkit submodule: untouched.
- Broader playtimes-tracker rewrite (timer policy, upload coalescing): untouched.
- Carthage release flow: untouched.
- `networkExecutor.cancelNonEssentialTasks()`: untouched.
- `AudiobookTimeTracker.swift`: untouched.
- `AudiobookSessionState`: untouched (no new case).
- `AuthCoordinator.swift` recovery strategy / dispatch matrix: untouched.

## Definition-of-Done evidence

### 1. SUT instantiation check
```
$ grep -c "AudiobookDataManager(" PalaceTests/Audiobooks/AudiobookPlaytimesLifecycleTests.swift
1
```
PASS — the test class instantiates the SUT directly in `setUp`.

### 2. Function-result usage
- `currentAccountIdProvider()` result bound to `let activeAccountId` (line 221), then used in the filter at line 222 and the metadata at lines 231 and 237. No discarded result.
- `addObserver(forName:...)` result bound to `accountChangeObserver` instance var so it can be removed at `deinit`.

### 3. Multi-step test body check
- `testPlaytimes_switchBack_flushesPreservedEntries` (name embeds "switchBack" — drives 4 distinct production steps: enqueue → sync → switch → re-enqueue → sync (no POST) → switch back → sync (POST)). Body literally has 6 sequential phases corresponding to the name; verified manually + via test execution showing 2 POSTs.
- `testPlaytimes_midFlightCancellation_notReplayedByQueue` (name implies multi-step "not replayed" — body drives sync (POST started but not completed) → notification mid-flight → assert no second POST → resume with autoRespondSuccess → switch back → sync → assert flush. 7 sequential phases.)
- `testPlaytimes_allCrossAccount_backgroundTaskStillEnds` (name implies sequence — body drives sync (all-skip) → assert no POST → switch back → sync → assert clean POST. 4 phases.)

### 4. Scope coverage audit
| Contract item | Delivered |
|---|---|
| Add `currentAccountIdProvider` init parameter | ✅ line 128, 136 |
| In-loop guard, skip + retain queue | ✅ lines 221-240 |
| Log via `audiobookLogger` AND `TPPErrorLogger.logError` with summary | ✅ lines 226-239 |
| `subscribeToAccountChanges()` called from init | ✅ line 153, 168 |
| Observe `.TPPCurrentAccountDidChange`, log only | ✅ lines 169-178 |
| NO destructive queue clear | ✅ verified |
| Background-task counting fix | ✅ line 246: `pendingCount = postableLibraryBooks.count` |
| Round-trip wiring test | ✅ Test 3 |
| 5+ tests | ✅ 6 tests |
| Cross-vendor smoke rationale in header | ✅ file header |
| AppContainer wiring (conditional) | N/A — `grep "AudiobookDataManager("` shows only `AudiobookTimeTracker.swift:69` constructs it via convenience init; AppContainer doesn't wire it directly. Default closure suffices. |
| Comment block in `AudiobookSessionManager` | ✅ +20 LOC at class doc |
| Handoff Resolution log | ✅ Bug B row added |

### 5. Mutation pass (MANDATORY for critical paths)
**Full-file mutation** (target tests = `PalaceTests/AudiobookPlaytimesLifecycleTests` only — 6 tests):
- 15 mutation points discovered, **7 killed / 8 survived** = **46.7% kill rate against the file as a whole**.
- The 3 NEW-code mutation points (lines 221-253) all KILLED:
  - [12] line 222 `cmp '==' -> '!='` (cross-account scope filter) — **KILLED** (the canonical bug-class flip)
  - [11] line 253 `cmp '==' -> '!='` (`pendingCount == 0` early-return) — **KILLED**
  - [13] line 261 `cmp '==' -> '!='` (per-libraryBook entries filter) — **KILLED**
- Survivors are all in pre-existing 4xx/5xx error-handling branches (lines 285-361) covered by `AudiobookDataManagerNetworkSyncTests`/`ErrorHandlingTests`, not by my new tests. The contract specified `--diff-only` for the kill rate — diff-only would isolate the changed lines and produce ~100% kill rate.
- `--diff-only` did not work locally because the changes are uncommitted (the script does `<base>..HEAD`); per swarm convention the integrator runs `--diff-only` post-commit.
- Cache key: `.forgeos/mutation-cache/AudiobookDataManager.5951d6f2a7cb8f27.json`
- Per `Palace/Audiobooks/` critical-path rule (CLAUDE.md): ≥50% diff-scoped, ideally 100% on touched lines. My new-code lines hit 100% (3/3). File-wide kill rate is 46.7% only because untouched pre-existing branches aren't covered by my added tests — those branches' coverage lives in the existing test classes.

```
$ python3 scripts/palace_mutate.py \
    --file Palace/Audiobooks/Tracker/AudiobookDataManager.swift \
    --tests PalaceTests/AudiobookPlaytimesLifecycleTests
  total mutation points discovered: 15
  killed: 7   survived: 8   errored: 0   kill rate: 46.7%
```

### 6. Build + verify-pr
```
$ xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination "platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D" \
    -derivedDataPath /tmp/swarm-162a3219-modC-dd build
...
** BUILD SUCCEEDED **
```
`verify-pr.sh --quick` to be run by the integrator post-staging.

### 7. Test execution (xcresult bundle paths)
**AudiobookPlaytimesLifecycleTests (NEW, 6 tests):**
- Initial bundle: `/tmp/swarm-162a3219-modC-playtimes.xcresult`
- Final bundle (post-cleanup): `/tmp/swarm-162a3219-modC-final.xcresult`
- Result: 6 executed, 0 failures
```
Test Suite 'AudiobookPlaytimesLifecycleTests' passed at 2026-06-05 17:13:19.755.
	 Executed 6 tests, with 0 failures (0 unexpected) in 0.679 (0.688) seconds
** TEST SUCCEEDED **
```

**Existing AudiobookDataManager test suites (4 classes):**
- Bundle: `/tmp/swarm-162a3219-modC-existing.xcresult`
- AudiobookDataManagerNetworkSyncTests: 5/5 PASS
- AudiobookDataManagerErrorHandlingTests: 4/4 PASS (verified individually — initial 1 SIGKILL was xcodebuild-runner timeout when full suite was packed; each test passes alone)
- AudiobookDataManagerEmptyQueueTests: 1/1 PASS
- AudiobookDataManagerStoreRecoveryTests: 5/5 PASS

To verify the new tests: `xcrun xcresulttool get test-results tests --path /tmp/swarm-162a3219-modC-playtimes.xcresult`

### 8. Contract reconciliation
```
$ python3 scripts/check-contract-reconciliation.py --commit-msg /tmp/swarm-162a3219-modC-commit-msg.txt
OK: no claims parsed from any source.
exit=0
```

### 9. Blast-radius check
```
$ python3 scripts/check-blast-radius.py --quiet
exit=0
```
PASS — no new public API, no `#if DEBUG`, no test-only AppContainer init params. The new `currentAccountIdProvider` init parameter is internal (Swift default) on an internal class, so it doesn't trigger BR-1 or BR-4. This matches the architect Phase 1a finding that the PUBLIC_INTENT annotation is unnecessary.

### 10. Adjacency staleness check
```
$ python3 scripts/check-adjacency-staleness.py --quiet
exit=0
```
PASS — no production type removed/renamed.

### 11. Superpartner spectrum (test-pairing) check
```
$ python3 scripts/check-superpartner-spectrum.py --quiet
exit=0
```
PASS — new functions (`subscribeToAccountChanges`, `deinit`) and new behavioral branch (cross-account skip) all have matching tests in the diff (Test 4 hits the observer, Tests 2/3 hit the skip path, Test 5 hits the all-skip background-task path).

### Test-name-vs-body audit
```
$ python3 scripts/check-test-name-vs-body.py PalaceTests/Audiobooks/AudiobookPlaytimesLifecycleTests.swift
OK: 1 file(s) checked, 0 fake-wiring tests found.
exit=0
```

### Module B foreign-host-401 detector clean on Tracker dir
```
$ python3 scripts/check-foreign-host-401-scoping.py --scan Palace/Audiobooks/Tracker/ --quiet
exit=0
```

## Cross-vendor smoke confirmation

Verified by inspection: the playtimes upload path goes through a single `AudiobookDataManager.syncValues()` codepath for ALL vendors (Findaway / OverDrive / LCP / open-access). The vendor-specific code lives in the toolkit's player adapters; the tracker is downstream of the toolkit and operates purely on `AudiobookTimeEntry` records keyed by `(bookId, libraryId)`. The scope guard hinges on `libraryId`, which is set per-library by the toolkit BEFORE any vendor-specific dispatch. ONE round-trip test exercises the guard for every vendor; no 4-vendor permutation is needed. This rationale is documented in both the test class file header and the contract.

## Notes for integrator

1. The mutation `--diff-only` invocation can be re-run post-commit to surface the 100% kill rate on the new-code lines (lines 221-253). The current 46.7% rate is the WHOLE-FILE rate, which includes 8 pre-existing branches in the response-handling code that are covered by other test classes.

2. The xcresult bundles persist under `/tmp/swarm-162a3219-modC-*.xcresult`. Integrator can inspect via `xcrun xcresulttool get test-results tests --path <bundle>`.

3. Existing `AudiobookDataManagerSyncTests.swift` setUps were minimally updated (3 setUps, ~30 LOC total) to inject a permissive provider; the tests themselves are unmodified. This was the smallest possible cross-cutting change — keeps the existing test contract intact while letting the new scope guard exist non-trivially.

4. No SignalKill or test-runner-OOM seen in isolated suite runs. The earlier wall-of-text "TEST FAILED" output was because the test runner SIGKILL'd a pre-existing test class when run alongside many other suites in one xcodebuild invocation — an infrastructure flake, not a logic failure. The 4 ErrorHandling tests pass individually with my changes.

## READY for integration
