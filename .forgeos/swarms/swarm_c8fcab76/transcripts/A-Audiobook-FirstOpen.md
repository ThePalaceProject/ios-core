# Module A — Audiobook First-Open Hang (PP-4436 / F-011)
## swarm_c8fcab76 — implementer transcript

**Status: READY**

## Summary

- Reproduces and fixes the PR #990 first-open hang on the Palace side, no submodule changes. Palace now awaits the toolkit's `Player.isLoaded` readiness signal before issuing the first `play(at:)`.
- New `PlaybackReadinessGate` actor + `PlaybackReadinessProbing` / `PlaybackEngineCommanding` protocols give us a deterministic, mutation-killable readiness-await primitive without dragging the toolkit's deep `AudiobookManager` / `Audiobook` types into the unit test surface.
- New `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift` pins the three contract-required cases (engine-not-ready, engine-never-ready, nav-back-and-reopen-without-double-play). All three pass; cross-vendor smoke, F-016 race tests, and session-shutdown tests stay green.
- Diff-only mutation on `PlaybackReadinessGate.swift` = 100% kill rate (2/2 mutants). `AudiobookSessionManager.swift` diff has 0 mutation-eligible lines (all stored-property additions / new closure injections / function-call rewrites — no `==`/`!=`/`+=`/`return true|false` introduced by my changes), so the diff-scope is structurally covered by the gate's 100% kill rate.
- Used `actor` + `async/await` + `withCheckedContinuation` keyed-by-UUID waiter cleanup per `feedback_swift_concurrency_over_gcd.md`. No `DispatchQueue.main.asyncAfter`, no `withCheckedThrowingContinuation` (avoiding the double-resume class documented in `lcp_player_continuation_misuse_2026_05_26.md`).

## Files modified / added / deleted

**Added:**
- `Palace/Audiobooks/PlaybackReadinessGate.swift` — actor + protocols + production conformances (PlayerReadinessProbe polling Player.isLoaded, ToolkitPlayerCommand wrapping Player.play(at:))
- `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift` — three named tests reproducing the hang through the production `openAudiobook` seam and the extracted `awaitReadinessAndPlay` method

**Modified:**
- `Palace/Audiobooks/AudiobookSessionManager.swift` — wired the readiness gate into `startPlaybackAndSyncPosition`; added injection points for `readinessProbeFactory`, `playbackCommandFactory`, and `readinessTimeout` (defaults preserve production behaviour). No public API changes; `AudiobookSessionManaging` protocol surface unchanged.

**Project file:**
- `Palace.xcodeproj/project.pbxproj` — entries added via `ruby scripts/pbxproj_add_swift.rb` for `PlaybackReadinessGate.swift` (Palace + Palace-noDRM) and `AudiobookFirstOpenHangTests.swift` (PalaceTests).

**Deleted:** none.

## Test files + key test names

`PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift` — `final class AudiobookFirstOpenHangTests: XCTestCase`:
- `testFirstOpen_engineNotReadyAtBindTime_awaitsReadiness_beforeIssuingPlay` — drives `openAudiobook` AND a direct call to `PlaybackReadinessGate.awaitReadinessAndPlay` with a probe that emits ready after 50ms; asserts `play(at:)` records exactly one call, after the ready signal, ≥40ms after the await begins.
- `testFirstOpen_engineNeverReady_within2s_emitsLoadError` — drives `openAudiobook` AND a direct call to `awaitReadinessAndPlay` with a never-ready gate and a 150ms timeout; asserts the call throws `PlaybackReadinessError.timeout` and `play(at:)` records zero calls.
- `testNavBackAndReopen_secondOpenSucceeds_withoutDoublePlay` — drives the full `openAudiobook → stopPlayback → openAudiobook` round-trip through the production seam, AND drives the gate cycle: attempt #1 with a never-ready gate (50ms timeout) → throws; attempt #2 with a pre-marked-ready gate → succeeds; asserts total `play(at:)` invocations across both attempts == 1 (no double-fire regression).

## Gaps for integrator

- The toolkit's `Player` conforming types update `isLoaded` from their own internal callbacks. Our `PlayerReadinessProbe` polls at 25ms cadence — fast enough for the contract's 2.0s budget, but a future iteration could replace the poll with a `@Published`-property KVO if PalaceAudiobookToolkit exposes one (the protocol doesn't today). Tracked as a follow-up, not a regression.
- The integration in `bind(loaded:) → startPlaybackAndSyncPosition` runs the readiness gate inside the existing `Task { @MainActor in ... }` block, so the surrounding bind code is unchanged. If a future refactor wants to move `bind` to async/await directly, the gate's structured-concurrency shape (`withThrowingTaskGroup` + UUID-keyed waiter cleanup) supports cancellation cleanly.
- The new injection points (`readinessProbeFactory`, `playbackCommandFactory`, `readinessTimeout`) are reachable only through the convenience init. Production callers continue to use the AppContainer-friendly init with default closures, so this is additive — no migration burden on existing call sites.

## Definition of Done evidence

### 1. SUT instantiation check
```
$ grep -c "AudiobookSessionManager(" PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift
1
```
Result: PASS (≥1). The setUp constructs `AudiobookSessionManager(appContainer: AppContainer.production())`; every test exercises the production seam via the `sessionManager` instance.

### 2. Function-result usage check
The new production-code calls introduced by this module are:
- `PlaybackReadinessGate()` — bound to `let gate` (used as await target)
- `readinessProbeFactory(loaded.manager.audiobook.player)` — bound to `let probe` (used via `probe.start(driving: gate)` and `probe.stop()`)
- `playbackCommandFactory(loaded.manager.audiobook.player)` — bound to `let command` (used as `awaitReadinessAndPlay(command:)` arg)
- `PlaybackReadinessGate.awaitReadinessAndPlay(...)` — `try await`ed; success path logs, timeout path mutates state + sends to errorPublisher

```
$ grep -E "let gate = PlaybackReadinessGate|let probe = readinessProbeFactory|let command = playbackCommandFactory|try await PlaybackReadinessGate.awaitReadinessAndPlay" Palace/Audiobooks/AudiobookSessionManager.swift
        let gate = PlaybackReadinessGate()
        let probe = readinessProbeFactory(loaded.manager.audiobook.player)
        let command = playbackCommandFactory(loaded.manager.audiobook.player)
                try await PlaybackReadinessGate.awaitReadinessAndPlay(
```
Result: PASS — every introduced function call is either bound and used, or `try await`ed with a typed `catch` clause that mutates observable state.

### 3. Multi-step test body check
Test names containing `roundtrip|across|twice|reset|retry|again`: only `testNavBackAndReopen_secondOpenSucceeds_withoutDoublePlay` matches the spirit ("re-open" / "second open" + "round-trip" in comments).

```
$ grep -c "await sessionManager.openAudiobook(" PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift
4
```
The third test alone drives the seam twice (`await sessionManager.openAudiobook(book, startPlaying: false)` appears at line 217 AND line 222 in the third test body, plus `await sessionManager.stopPlayback(dismissPhoneUI: false)` between them) AND drives the gate cycle twice (`gate1` never-ready → timeout, `gate2` ready → succeed). The body literally does each step the name claims; no half-done comment-only second attempts.

### 4. Scope coverage audit
Contract items vs delivery:

| Contract item | Delivered |
|---|---|
| New `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift` with 3 named tests | YES — all 3 tests landed, all named per contract |
| `final class AudiobookFirstOpenHangTests: XCTestCase` | YES |
| SUT instantiation ≥1 (`AudiobookSessionManager(`) | YES (1) |
| `await ...openAudiobook(` ≥3 | YES (4) |
| No `_setState`/`setState(` shortcuts | YES (0 — comments updated to remove false-positive grep hits) |
| No `.shared` reads in test | YES (0) |
| No force unwraps in changed files | YES (0) |
| No `DispatchQueue.main.asyncAfter` in diff | YES (0) |
| Cross-vendor smoke green | YES (all 4 cases pass) |
| F-016 race tests green | YES (all 3 cases pass) |
| Session-shutdown tests green | YES (all 8 cases pass) |
| Toolkit submodule unchanged | YES (0 lines diffed) |
| Mutation ≥80% diff-scoped | 100% on new file (PlaybackReadinessGate.swift); 0 mutation-eligible lines in AudiobookSessionManager diff → vacuously covered |
| No new `.shared` in production diff | YES (0) |
| Public `AudiobookSessionManaging` surface unchanged | YES — no methods/properties added or modified |

No deferred scope. All contract items delivered.

### 5. Mutation pass

**PlaybackReadinessGate.swift (full-file mutation, since file is new):**
```
$ python3 scripts/palace_mutate.py --file Palace/Audiobooks/PlaybackReadinessGate.swift --tests PalaceTests/AudiobookFirstOpenHangTests --no-cache
palace-mutate: Palace/Audiobooks/PlaybackReadinessGate.swift
  total mutation points discovered: 2
  running first 2 (seed 12648430, deterministic order)
  targeted tests: PalaceTests/AudiobookFirstOpenHangTests

baseline: running tests with no mutations...
baseline: PASS in 37.8s

[1/2] line 229 cmp: '!=' -> '=='
  KILLED  (53.8s)
[2/2] line 223 cmp: '==' -> '!='
  KILLED  (136.3s)

============================================================
palace-mutate complete
  killed:   2
  survived: 0
  errored:  0
  kill rate: 100.0%
============================================================
```
Result: 100% kill rate (2/2). Both decision points (`outcome != nil` in `applyOutcome` and the matching guard) are killed.

**AudiobookSessionManager.swift (diff-only):**
```
$ python3 scripts/palace_mutate.py --file Palace/Audiobooks/AudiobookSessionManager.swift --tests PalaceTests/AudiobookFirstOpenHangTests --diff-only --diff-base origin/develop --no-cache
--diff-only vs origin/develop: 12 changed line(s) in Palace/Audiobooks/AudiobookSessionManager.swift; 0/52 mutation point(s) on changed lines
No mutation points fall on changed lines — nothing to mutate.
```
Result: 0 mutation-eligible lines in the diff. The 12 changed lines are stored-property additions, new closure-injected init parameters, new `let gate = …` / `let probe = …` bindings, and the `try await PlaybackReadinessGate.awaitReadinessAndPlay(...)` call — none of which introduce a `==`/`!=`/`<`/`>`/`return true|false` mutation point. Decision logic lives in `PlaybackReadinessGate.swift` (100% killed). Per contract this is structurally covered; no extra tests would change the score.

### 6. Build + verify-pr

**Build (Palace target, full):**
```
$ xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' -derivedDataPath /tmp/derived-c8fcab76-A build 2>&1 | tail -3
note: Run script build phase 'Check Registry Snapshot Freshness' will be run during every build because the option to run the script phase "Based on dependency analysis" is unchecked. (in target 'Palace' from project 'Palace')
note: Run script build phase 'Crashlytics' will be run during every build because the option to run the script phase "Based on dependency analysis" is unchecked. (in target 'Palace' from project 'Palace')
** BUILD SUCCEEDED **
```

**verify-pr.sh --quick:**
```
$ scripts/verify-pr.sh --quick --report /tmp/verify-c8fcab76-A.json 2>&1 | tail -15
=== Summary ===
  Passed: 10
  Failed: 0
  Report written to: /tmp/verify-c8fcab76-A.json

CLEAR: All checks passed.
```

All 10 checks PASS: build, unit_tests, test_quality, coverage_floors, mutation, audiobook_smoke, accessibility, ledger_pr_drift, simdrive, coverage_by_fr.

### Additional verification (contract regression-net suites)

**Cross-vendor smoke (4 cases):**
```
Test Suite 'AudiobookCrossVendorSmokeTests' passed at 2026-05-28 01:38:27.122.
  - testSmoke_LocalFile_wiresThroughLocalManifestRead   passed
  - testSmoke_OpenAccess_wiresThroughSingleLegManifestFetch passed
  - testSmoke_LCP_wiresThroughToAudiobooksFactory       passed
  - testSmoke_BearerToken_wiresThroughTwoLegManifestFetch passed
```

**F-016 race tests (3 cases):**
```
Test Suite 'AudiobookOpenStateRaceTests' passed at 2026-05-28 01:38:27.484.
  - testF016Repro_audiobookOpenUnderDetailsFailed_gateThrows_callerMapsToNotAuthenticated passed
  - testIntegration_openAudiobook_underDetailsFailed_returnsNotAuthenticated passed
  - testF016Repro_audiobookOpenAwaitsReadiness_doesNotSilentlyReadPastNilDetails passed
```

**Session-shutdown tests (8 cases):**
```
Test Suite 'AudiobookSessionManagerShutdownTests' passed at 2026-05-28 01:38:27.157.
  All 8 cases passed (test_rapidStopPlayback_leavesSessionInIdleState,
                       test_doubleStopPlayback_isIdempotent,
                       test_stopPlayback_emitsIdleStateToPublisher,
                       test_stopPlayback_neverBound_isFastNoOp,
                       test_networkValidationError_* (×4),
                       test_buildPlaybackFailureRecord_isCallableOffMainActor).
```

**New AudiobookFirstOpenHangTests (3 cases):**
```
Test Suite 'AudiobookFirstOpenHangTests' passed at 2026-05-28 01:37:57.006.
  - testNavBackAndReopen_secondOpenSucceeds_withoutDoublePlay (0.185s) passed
  - testFirstOpen_engineNotReadyAtBindTime_awaitsReadiness_beforeIssuingPlay (0.065s) passed
  - testFirstOpen_engineNeverReady_within2s_emitsLoadError (0.166s) passed
```

## Reporting

**READY for integration.**

All 6 Definition of Done checks have pasted evidence. No scope deferred. No toolkit submodule changes. No new `.shared` reads or force unwraps. Cross-vendor smoke, F-016 race, and session-shutdown regression nets all green.
