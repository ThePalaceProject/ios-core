[DO NOT MERGE] fix(carplay): async bounded-retry audio-session activation (.playerNotReady crash)

## What / Why
WS-2 (3.2.0 M1 crash triage, initiative init_17bfe690). Closes the Crashlytics
`d45f5aa9` CarPlay OpenAccess `.playerNotReady` crash, deferred from PR #1050.

On a CarPlay **cold launch** `PlaybackBootstrapper.activateAudioSession()` issued a
single `AVAudioSession.setActive(true)`. A transient refusal (OSStatus `561015905`,
or `-50` paramErr in the early-launch window) left the session inactive; the
toolkit's `OpenAccessPlayer` then observed `AVQueuePlayer.status == .failed` →
`playerIsReady = .failed` → `attemptToPlay` default branch
(`handlePlaybackError(.playerNotReady)`, OpenAccessPlayer.swift:254) when CarPlay
issued play. Nobody retried the transient: Palace's old code AND the toolkit's own
`setupAudioSession` (recoverable set `{-50, 560557684}`) both did a single
non-retried `setActive`.

## Change (app-side only — no toolkit submodule change)
- New internal `AudioSessionActivator` (`Palace/Audiobooks/AudioSessionActivator.swift`):
  bounded async retry-with-backoff. Pure `isRetriable(errorCode:)` (transient set =
  `561015905`, `-50`, `cannotStartPlaying`, `cannotInterruptOthers`; everything else
  fails fast) + pure exponential `backoff(forAttempt:base:cap:)`. Bounded
  `1...maxAttempts` (no infinite retry); no sleep after the final attempt; injected
  `sleep`/`setActive`/`isOtherAudioPlaying` seams for deterministic CI-safe tests.
- `PlaybackBootstrapper.activateAudioSession` → async `activateAudioSessionWithRetry`,
  invoked from `Task { @MainActor }` in `ensureInitializedForCarPlay` so the bounded
  backoff never blocks the synchronous CarPlay `didConnect` path (~1s block the
  deferral flagged).

## Scope / residual (honest)
- Closes the **dominant transient cold-launch race** that is `d45f5aa9`. Not a hard
  happens-before barrier on the play path (a true barrier = gate the play path on
  session-active, an AudiobookSessionManager change beyond WS-2's pinned seam →
  follow-up). Exhaustion degrades gracefully: logs + returns, never issues play, so
  it cannot itself trigger `.playerNotReady`; re-fires on each CarPlay reconnect.
- Residual persistent-denial tail = the toolkit HYBRID half (add `561015905` to the
  toolkit recoverable set / make `attemptToPlay` degrade-not-crash) — tracked as a
  toolkit follow-up, out of WS-2 scope.
- `561015905` transient-vs-persistent is UNVERIFIED in-process — folds into the
  device/simdrive CarPlay-cold-launch validation pass (same as WS-4/WS-5).

## DoD evidence
- TDD red-first: `PalaceTests/Audiobooks/AudioSessionActivatorTests.swift` (8 tests).
- Focused: AudioSessionActivatorTests **8/8 pass** (** TEST SUCCEEDED **, sim 35FA2B33).
- Mutation: `AudioSessionActivator.swift` **1/1 = 100% kill**, 0 survivors, 0
  critical-path survivors. `PlaybackBootstrapper.swift` diff-only 0/2 points on
  changed lines (thin wiring; logic delegated to the activator).
- `verify-pr.sh --quick`: **21/22 PASS** — build, mutation, audiobook cross-vendor
  smoke (4/4: LCP/Bearer/OpenAccess/LocalFile), accessibility, blast-radius,
  superpartner, contract-reconciliation, adjacency, intent-recorded, test-name-vs-body,
  all phase-3.5 detectors, coverage floors. The 1 fail = `unit_tests` 2/7157:
  `OPDSFeedServiceStateMachineTests.testFetchLoansFeed_blocksUntilLoaded_thenFetches`
  — a timing-sensitive OPDS2 readiness test (unrelated module), **passed in isolation
  twice** (verify-pr's own 17:00 re-run + an independent re-run, 5/5). Confirmed
  contention flake (verify-pr ran concurrently with the pool-4 M0 confirm); not WS-2.
- ForgeOS: changeset `cs_1a4e3f20` (init_17bfe690); evidence `ev_f86fa86d`,
  `ev_07b9b4c3`. `forge_release_check`: can_release=false, pending [review, testing,
  release], 0 failed gates.

## Merge gate
Pending: Chairman check-off + palace-pm SoD /forge-review (different model) +
palace-pm independent re-verify + M0. DO NOT MERGE.
