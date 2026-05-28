# Module A — Audiobook First-Open Hang (PP-4436 / F-011)

**Critical-path module.** Memory pins (load-bearing):
- `audiobook_first_open_hang_3_2_0.md` (5 days old — verify against current code)
- `reference_audiobook_toolkit_risk_profile.md` (25+ toolkit revs, regression history)
- `reference_biblioboard_cross_host_token_scoping.md` (two-layer-bug pattern: root + propagation)
- `feedback_audiobook_sim_audio_limitation.md` (sim cannot decode — drive via position seam)
- `feedback_swift_concurrency_over_gcd.md` (actor + async/await over GCD+barrier+closure)

## Goal

Eliminate the first-open hang regression introduced by PR #990's toolkit overhaul: on a fresh install, the first downloaded-audiobook open mounts NowPlaying UI but the engine never starts; navigating away and re-opening fixes it. Land a wiring/lifecycle test that reproduces the hang through the production `AudiobookSessionManager.openAudiobook(_:startPlaying:)` seam (NOT via direct setter shortcuts) so a regression of the same shape would re-fail the test.

## What public types/protocols change

Default: **no public API changes**. The expected shape is a one-shot internal readiness await inside the existing bind/play handoff in `AudiobookSessionManager`. If the fix requires a new readiness signal:

- MAY add a **new internal-only** publisher/await on `AudiobookManager`/`Player`-shaped collaborator (toolkit surface — read-only; we wrap it on the Palace side via a new internal protocol).
- MAY add an internal `PlaybackReadinessGate` actor (or equivalent) co-located in `Palace/Audiobooks/`.
- Public surface of `AudiobookSessionManager` (`openAudiobook`, `play`, `pause`, `togglePlayPause`, `skipToChapter`, `cyclePlaybackRate`, `stopPlayback`, `updateCoverImage`, `hasActiveManager`) MUST NOT change signature.
- `AudiobookSessionManaging` protocol — no signature changes; new readiness members allowed ONLY if internal-protocol (`internal protocol`) and not added to the consumer-facing `AudiobookSessionManaging`.

## What internal seams (DI protocols) need updating

- New optional internal protocol — e.g. `AudiobookEngineReadinessProbing` — wraps the toolkit's "engine ready" / "coordinator ready" signal. Production conformance lives in `Palace/Audiobooks/Vendors/Adapters+Production.swift` or a new `Palace/Audiobooks/PlaybackReadinessGate.swift`. Test conformance lives in `PalaceTests/Audiobooks/Mocks/`.
- `AudiobookLoader` MAY emit a readiness future as part of `LoadedAudiobook` (additive field), so `bind(loaded:for:startPlaying:)` can await readiness before `startPlaybackAndSyncPosition` issues the first `play(at:)`.
- `PlaybackBootstrapper.audiobookSessionProvider` — no change. The hang is post-session-resolution, not at bootstrap.

**Concurrency model:** use `actor` + `async/await` per `feedback_swift_concurrency_over_gcd.md`. Do NOT add `DispatchQueue.main.asyncAfter`-style delay-loop workarounds — they're an immediate red flag in review.

## Test contracts the module must satisfy

1. **Production-seam reproduction test (mandatory).** New `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift`. At least three cases:
   - `testFirstOpen_engineNotReadyAtBindTime_awaitsReadiness_beforeIssuingPlay` — drive `AudiobookSessionManager.openAudiobook(_:startPlaying: true)` with a `ReadinessProbeStub` that emits `notReady` then `ready` after 50ms. Assert: the player's `play(at:)` call records exactly ONE invocation, AFTER the `ready` event. Pre-PR-990 behavior would record the call BEFORE `ready` (race window).
   - `testFirstOpen_engineNeverReady_within2s_emitsLoadError` — same stub but never emits `ready`. Assert: `openAudiobook` returns `.failure(.unknown(...))` or a typed timeout error; `errorPublisher` emits the same; `state == .error(bookId:)`.
   - `testNavBackAndReopen_secondOpenSucceeds_withoutDoublePlay` — drive open #1 → simulate engine-ready-after-cancel → drive `stopPlayback` → drive open #2 with engine-ready-immediate. Assert: total `play(at:)` invocations across both opens == 1 (the second), not 2. Pins the workaround path so a "fix-by-double-play" regression fails.

2. **Round-trip wiring (mandatory per CLAUDE.md "State-machine wiring tests").** The session manager's state transitions `unloaded → loading → playing → paused → unloaded` must be exercised through `openAudiobook` and `stopPlayback`, NOT through `_setState`-style shortcuts. If a private setter is used as the test's Act step, the test does not satisfy this contract.

3. **Cross-vendor smoke survival.** `PalaceTests/Audiobooks/CrossVendorSmokeTests.swift::AudiobookCrossVendorSmokeTests` (4 cases: LCP, BearerToken, OpenAccess, LocalFile) must still pass aggregate <10s after Module A's changes. This is the regression net for cross-vendor breakage per `reference_audiobook_toolkit_risk_profile.md`.

4. **F-016 race tests still green.** `PalaceTests/Audiobooks/AudiobookOpenStateRaceTests.swift` must still pass. Module A's readiness gate must not regress the existing details-failed/await-readiness handling.

5. **Mutation kill-rate (critical path).** ≥80% diff-scoped on touched lines in `Palace/Audiobooks/AudiobookSessionManager.swift`, `Palace/Audiobooks/AudiobookLoader.swift`, and any new `PlaybackReadinessGate.swift`. 100% ideal per CLAUDE.md critical-path rule. Run:
   ```bash
   python3 scripts/palace_mutate.py --file Palace/Audiobooks/AudiobookSessionManager.swift \
     --tests PalaceTests/AudiobookFirstOpenHangTests --diff-only --diff-base origin/develop
   ```

## Files scoped to THIS implementer

Production (Palace target — pbxproj entries in both Palace + Palace-noDRM):
- `Palace/Audiobooks/AudiobookSessionManager.swift` (modified — wire readiness gate into bind/startPlayback handoff)
- `Palace/Audiobooks/AudiobookLoader.swift` (modified — emit readiness future as additive `LoadedAudiobook` field, IF needed)
- `Palace/Audiobooks/AudiobookSessionManaging.swift` (modified — internal protocol only if needed; no consumer surface changes)
- `Palace/Audiobooks/PlaybackReadinessGate.swift` (NEW — only if extracting; otherwise embed in AudiobookSessionManager.swift)
- `Palace/Audiobooks/NowPlayingCoordinator.swift` (modified — ONLY if hang root cause is in nowplaying timer/state push; otherwise read-only)
- `Palace/Audiobooks/PlaybackBootstrapper.swift` (read-only — do NOT modify unless the hang root cause is provably here)

Test:
- `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift` (NEW — primary deliverable)
- `PalaceTests/Audiobooks/Mocks/` (MAY extend — document each new mock; AudiobookEngineMock.swift already exists)

Tooling:
- `ruby scripts/pbxproj_add_swift.rb` for the new Swift file(s) — Palace + Palace-noDRM targets for production files, PalaceTests target for test file.

## Files explicitly OFF-LIMITS

**Anti-scope (deferred to wave 2 after PR #1018 merges):**
- `Palace/SignInLogic/` — entire directory
- `Palace/Packages/PalaceAuth/` — entire package
- `Palace/Accounts/Library/AccountsManager.swift`
- `Palace/Accounts/Account+State.swift`
- `Palace/Accounts/AccountStateStore.swift`

**Off-limits per swarm overlap resolution:**
- `Palace/Book/UI/BookDetail/BookButtonMapper.swift` (Module B)
- `Palace/MyBooks/Download*.swift` (Module B)
- `PalaceTests/MyBooks/Download*Tests.swift` (Module B)
- `PalaceTests/Book/BookButtonMapper*Tests.swift` (Module B)
- `PalaceTests/BookStateManagement/BookButtonMapperTests.swift` (Module B)
- `docs/architecture/areas/*` (Module C)
- `PalaceTests/Audiobooks/*` files that PRE-EXIST as of branch base — Module D may rewrite shallow tests in those existing files. **Module A owns only the NEW `AudiobookFirstOpenHangTests.swift` and additions to `Mocks/`. Module D does NOT touch `AudiobookFirstOpenHangTests.swift`, `AudiobookOpenStateRaceTests.swift`, `AudiobookSessionManagerShutdownTests.swift`, `AudiobookEventsTests.swift`, `AudiobookLoadFailureSAMLReauthTests.swift`, `SAMLPlusBiblioBoardExpirationTests.swift`, `AudiobookSessionStateTests.swift`, `AudiobookLoaderFinalizeBuildTests.swift`, `AudiobookTimeTrackerEdgeTests.swift`, `AudioEngineWrapperTests.swift`, `CrossVendorSmokeTests.swift`** — these are critical-path or session-manager-adjacent and Module A may need to update them. Module D's scope is narrower (see Module D contract).

**Audiobook toolkit submodule (`ios-audiobooktoolkit/`):** read-only. Per `reference_audiobook_toolkit_risk_profile.md`, the toolkit is the highest-risk dependency in the project (25+ revs, frequent reverts). Touch only if absolutely required — if so, the implementer must escalate to the orchestrator BEFORE the toolkit change is made. Default assumption: the fix is Palace-side wrapping of an existing toolkit signal.

## Verification criteria (MANDATORY — grep-able assertions)

For each acceptance bullet, paste the exact grep + expected output.

1. **New test file exists and has the three named tests:**
   ```bash
   test -f PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift && \
     grep -c "func testFirstOpen_engineNotReadyAtBindTime_awaitsReadiness_beforeIssuingPlay" PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift && \
     grep -c "func testFirstOpen_engineNeverReady_within2s_emitsLoadError" PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift && \
     grep -c "func testNavBackAndReopen_secondOpenSucceeds_withoutDoublePlay" PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift
   ```
   Each grep `-c` MUST return ≥1.

2. **Test class name is correct (Module C/B cross-references rely on it):**
   ```bash
   grep -c "final class AudiobookFirstOpenHangTests: XCTestCase" PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift
   ```
   MUST return 1.

3. **SUT instantiation present in test body:**
   ```bash
   grep -c "AudiobookSessionManager(" PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift
   ```
   MUST return ≥1 (the test exercises the production seam, not a setter shortcut).

4. **NO direct private-state writes — verify Act step is `openAudiobook`/`stopPlayback`:**
   ```bash
   grep -c "await .*\.openAudiobook(" PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift
   ```
   MUST return ≥3 (three tests, each calling the production seam at least once).
   ```bash
   grep -c "_setState\|setState(" PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift
   ```
   MUST return 0 (no shortcut writes — wiring is proved through the production seam).

5. **No `.shared` singleton reads in test:**
   ```bash
   grep -c "\.shared" PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift
   ```
   Should be 0. If non-zero, each occurrence must be `MPRemoteCommandCenter.shared()` (system framework) and documented in the test header.

6. **No force unwraps in production or test:**
   ```bash
   grep -nE '![ ;)\.]' Palace/Audiobooks/AudiobookSessionManager.swift Palace/Audiobooks/AudiobookLoader.swift PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift | grep -v '!=' | grep -v '!(' | grep -v '// '
   ```
   Should return only matches inside string literals or comments. Per `feedback_no_force_unwraps.md`.

7. **No `DispatchQueue.main.asyncAfter` workarounds in changed lines:**
   ```bash
   git diff origin/develop -- Palace/Audiobooks/ | grep -E '^\+.*asyncAfter'
   ```
   MUST be empty. The fix is `await readiness`, not `delay 200ms and hope`.

8. **Cross-vendor smoke still green (regression net):**
   ```bash
   xcodebuild -project Palace.xcodeproj -scheme Palace \
     -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
     -only-testing:PalaceTests/AudiobookCrossVendorSmokeTests test 2>&1 | grep -E "Test Suite '.*' passed"
   ```
   MUST return ≥1 line confirming the suite passed.

9. **F-016 race tests still green:**
   ```bash
   xcodebuild ... -only-testing:PalaceTests/AudiobookOpenStateRaceTests test 2>&1 | grep -E "Test Suite '.*' passed"
   ```
   MUST return ≥1 line confirming the suite passed.

10. **Audiobook toolkit submodule unchanged (escalation contract):**
    ```bash
    git diff origin/develop -- ios-audiobooktoolkit
    ```
    MUST be empty unless the implementer has escalated and the orchestrator has approved a submodule bump.

11. **Mutation kill-rate (critical path) on touched production files:**
    ```bash
    python3 scripts/palace_mutate.py --file Palace/Audiobooks/AudiobookSessionManager.swift \
      --tests PalaceTests/AudiobookFirstOpenHangTests --diff-only --diff-base origin/develop
    ```
    Kill rate MUST be ≥80% diff-scoped (100% ideal per CLAUDE.md). Paste the output line `Killed: X / Y (Z%)`.

## Definition of Done evidence the implementer must paste

(Per CLAUDE.md TDD & Test Quality + Pre-PR self-check + critical-path rules. Six checks:)

1. **TDD evidence — failing test commit first.** `git log` showing the test commit landed BEFORE the production fix, AND that test failed when run against pre-fix HEAD:
   ```bash
   git log --oneline -- PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift
   git log --oneline -- Palace/Audiobooks/AudiobookSessionManager.swift Palace/Audiobooks/AudiobookLoader.swift
   ```

2. **Test-quality lint clean on new file:**
   ```bash
   python3 scripts/lint-test-quality.py --file PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift
   ```
   Output: `Total: 0 violations` (or only SHALLOW-001 in setup/teardown helpers, not in test methods).

3. **All tests pass — full suite:**
   ```bash
   scripts/verify-pr.sh --quick --report /tmp/verify.json
   ```
   `--quick` battery (build, tests, lint, coverage, accessibility) passes.

4. **Mutation kill-rate on critical-path files:** see Verification #11 above.

5. **No new `.shared` reads in production:**
   ```bash
   git diff origin/develop -- 'Palace/Audiobooks/*.swift' | grep -E '^\+.*\.shared'
   ```
   MUST be empty (or only `MPRemoteCommandCenter.shared()` system framework).

6. **Cross-vendor smoke + F-016 + session-shutdown all green** (regression net for the three highest-risk neighbour test classes):
   ```bash
   xcodebuild ... -only-testing:PalaceTests/AudiobookCrossVendorSmokeTests test
   xcodebuild ... -only-testing:PalaceTests/AudiobookOpenStateRaceTests test
   xcodebuild ... -only-testing:PalaceTests/AudiobookSessionManagerShutdownTests test
   ```

## Implementer prompt (one paragraph)

You are Module A implementer for `swarm_c8fcab76`. Run `~/harness/bin/harness subagent-prelude --domain audiobook` first — `audiobook_first_open_hang_3_2_0.md` is load-bearing context (note: 5-day-old memory, verify against current code). PR #990 bumped the audiobook toolkit submodule and rewrote 3 Palace call sites; the symptom is a race where Palace's first `play(at:)` issues before the toolkit's player coordinator has finished initializing. Your job: (1) reproduce the hang through the production `AudiobookSessionManager.openAudiobook` seam in a new `AudiobookFirstOpenHangTests.swift` with the three named cases; (2) add a Palace-side readiness gate that `await`s the toolkit's coordinator-ready signal before issuing the first play; (3) keep the existing F-016 / CrossVendorSmoke / SessionShutdown suites green. The audiobook toolkit submodule is OFF-LIMITS — if you discover the fix REQUIRES a submodule change, STOP and escalate before changing it (toolkit revs have a 25+ regression history per `reference_audiobook_toolkit_risk_profile.md`). NO direct setter shortcuts (`_setState`) in the test — wire through the production seam. NO `DispatchQueue.main.asyncAfter` workarounds. Critical-path mutation kill-rate ≥80% diff-scoped. Do NOT touch `Palace/SignInLogic/`, `Palace/Accounts/`, or anything in Module B/C/D scope.
