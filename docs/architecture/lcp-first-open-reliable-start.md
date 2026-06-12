# ADR (DRAFT — pending Chairman ratification): LCP first-open reliable start via play-then-confirm-with-bounded-retry

- **Status:** DRAFT — proposed by w-mutex (WS-5), awaiting Chairman ratification.
- **Area:** audiobooks (LCP playback) — critical path
- **Branch:** `fleet/w-mutex-f011`
- **Tracking:** F-011 / PP-4436 (3.2.0 first-open hang)
- **Verification status:** UNIT-VERIFIED only — device/simdrive validation REQUIRED (see below).

## Decision

For LCP-DRM audiobooks, replace the single fire-and-forget first `play(at:)`
with `AudiobookSessionManager.confirmLCPFirstPlay(...)`: issue `play(at:)`, then
**re-issue** every `lcpFirstPlayRetryInterval` (0.5s) while the engine has not
confirmed playing, bounded by `lcpFirstPlayBudget` (3.0s). The re-issue is
**suppressed** the instant `probe.isCurrentlyReady()` is true; on budget
exhaustion we stay **silent** and defer to `LCPStreamingPlayer`'s own 30s
`.failed`. Palace-side only — no `ios-audiobooktoolkit` change.

## Context

The general F-011 fix (PR #1020) added a pre-play `PlaybackReadinessGate`
(await `isLoaded` → then play) for Findaway/OpenAccess/Overdrive. LCP is
**deliberately bypassed** (`PlaybackOpenPolicy.decideForLoad(decryptor:)
.bypassReadinessGate = hasDecryptor`) because `LCPStreamingPlayer.isLoaded ==
(AVPlayer.timeControlStatus == .playing)` — it only flips **after** a successful
`play()`. An await-isLoaded-then-play gate would therefore **deadlock** on LCP.

That left LCP on the ORIGINAL single fire-and-forget play, which drops silently
when the engine is still initializing on first open (UI mounts, no audio). The
nav-away-and-back workaround "works" because it re-inits and issues a **second**
play after init completed — i.e. the cure is simply *another play once the
engine is ready*.

## Why this shape

- **Inversion, not await.** Because readiness is downstream of `play()`, we
  cannot await-then-play. We play, then confirm-with-retry. Re-issuing `play()`
  until the engine reports playing is the programmatic equivalent of nav-back.
- **Glitch-safety (caveat).** `play()` can take effect between the gate wait and
  the re-issue decision. `AVPlayer.play()` is idempotent, but to be safe we
  re-check `probe.isCurrentlyReady()` **immediately** before each re-issue and
  suppress it once playing — never double-start / seek-to-zero a playing engine.
  Pinned by `testConfirmLCPFirstPlay_engineBecameReadyDuringGateWait_suppressesReissue`.
- **Silent on exhaustion.** Surfacing a Palace `.error` at 3s would mask the
  toolkit-owned 30s `.failed` genuine-non-start path and manufacture false
  errors. We stay below 30s and let the toolkit own real failure.
- **Dedicated budget, not `readinessTimeout`.** `readinessTimeout` (2.0s) is an
  *await-budget* for already-loaded non-LCP players; this is a *nudge-budget*
  for LCP first-open engine init (network + decrypt). Reusing it would conflate
  two different semantics.

## Alternatives considered

- **Keep the single fire-and-forget play** — rejected: it IS the bug.
- **Extend the readiness gate to LCP (await isLoaded then play)** — rejected:
  deadlocks (isLoaded only flips after play).
- **Toolkit-side fix in `LCPStreamingPlayer`** — rejected: cross-repo submodule +
  tagged-release churn is the fragility we avoid (see
  `reference_audiobook_toolkit_risk_profile.md`); the bug is Palace-side.
- **Surface a Palace `.error` on exhaustion** — rejected: masks the toolkit's
  own 30s `.failed`.

## Consequences / verification gate

- Non-LCP readiness-gate path (`awaitReadinessAndIssueFirstPlay`) is unchanged.
- **UNIT-VERIFIED only.** 4 tests + 100%-intent diff-scoped mutation prove the
  retry/suppression/silence LOGIC. They do NOT prove the real first-open hang is
  fixed — that needs **device/simdrive validation** with a live LCP title and
  real toolkit timing (same class as WS-4's CHECK 2). Specifically:
  1. Confirm a real LCP first-open reliably starts audio with NO
     nav-away-and-back, across cold launch + library swap.
  2. **TUNE the budget:** measure real LCP first-open engine-init time (network +
     decrypt) and set `lcpFirstPlayBudget`/`lcpFirstPlayRetryInterval` to
     init-time + margin, staying below the toolkit's 30s `.failed`. The 3.0s/0.5s
     default is PROVISIONAL and unvalidated — a too-short budget silently fails
     to fix the hang.
  3. Confirm no audible double-start / stutter from a re-issued `play()`
     mid-init (the caveat-2 glitch check on real audio).
- Folds into the same Mac/device validation pass as the WS-4 Adobe `_exit`
  ceiling. Unit-green ≠ "fixed".

## References

- Files: `Palace/Audiobooks/AudiobookSessionManager.swift`
  (`confirmLCPFirstPlay`), `Palace/Audiobooks/PlaybackReadinessGate.swift`
  (`isCurrentlyReady`), `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift`.
- `audiobook_first_open_hang_3_2_0.md` (root cause), `reference_audiobook_toolkit_risk_profile.md`.
