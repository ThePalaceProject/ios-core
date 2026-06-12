---
name: fix-lcp-first-open-reliable-start
created: 2026-06-11
author: claude-opus-4-8
tracking: WS-5 (fleet) — F-011 LCP-load toolkit gate / first-open hang; PP-4436; 3.2.0 crash triage init_17bfe690
related_prs: []
---

# Intent: WS-5 — LCP audiobook first-open reliable start (F-011)

## Problem
On FIRST open of an LCP-DRM audiobook the playback engine doesn't reliably
start: NowPlaying UI mounts, Play is unresponsive, no audio. Workaround today is
nav-away-and-back (re-init + a second play after init finished).

Root cause (pinned `AudiobookSessionManager.swift:1006-1019`): the general F-011
fix (PR #1020) added a pre-play `PlaybackReadinessGate` (await `isLoaded` → then
play) for Findaway/OpenAccess/Overdrive. LCP is DELIBERATELY bypassed
(`PlaybackOpenPolicy.decideForLoad(decryptor:).bypassReadinessGate = hasDecryptor`)
because `LCPStreamingPlayer.isLoaded == (timeControlStatus == .playing)` only
flips AFTER `play()` — await-then-play would deadlock. So LCP kept the ORIGINAL
single fire-and-forget `play()`, which drops silently when the engine is still
initializing on first open. The gate couldn't cover the one path that still had
the race.

## Approach (Palace-side only; NO toolkit change)
Invert the gate for LCP: PLAY-THEN-CONFIRM-WITH-BOUNDED-RETRY (`confirmLCPFirstPlay`).
Issue `play(at:)`, then re-issue every `lcpFirstPlayRetryInterval` while the
engine has NOT confirmed playing, bounded by `lcpFirstPlayBudget`. The re-issue
is SUPPRESSED the instant `probe.isCurrentlyReady()` is true (caveat: `play()`
can take effect between the gate wait and the re-issue decision — never
double-start a playing engine). On budget exhaustion stay SILENT and defer to
`LCPStreamingPlayer`'s own 30s `.failed` (don't synthesize a false Palace error).
This is the programmatic equivalent of the nav-back workaround.

## Claims
- Adds `isCurrentlyReady()` to `PlaybackReadinessProbing` (+ `PlayerReadinessProbe`).
- Adds `AudiobookSessionManager.confirmLCPFirstPlay(...)` + private `issueLCPPlay(...)`.
- Adds dedicated `lcpFirstPlayBudget` (3.0s) + `lcpFirstPlayRetryInterval` (0.5s).
- Wires the LCP branch (`isLCPAudiobook`) to `confirmLCPFirstPlay` (replaces single play).
- Adds 4 red-first tests + `LCPFirstOpenSpy` in `AudiobookFirstOpenHangTests`.

## Anti-claims
- Does NOT change the non-LCP readiness-gate path (`awaitReadinessAndIssueFirstPlay`).
- Does NOT touch `ios-audiobooktoolkit` (submodule unchanged).
- Does NOT surface a Palace `.error` on LCP budget exhaustion (toolkit owns genuine non-start).
- Does NOT reuse `readinessTimeout` (different semantics — await-budget vs nudge-budget).

## Files in scope
- Palace/Audiobooks/AudiobookSessionManager.swift
- Palace/Audiobooks/PlaybackReadinessGate.swift
- PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift

## Validation
- Unit: 4 tests pin reissue-until-loaded / suppress-once-playing (caveat 2) /
  exhaust-silently-no-error / ready-after-first-play. Mutation ≥50% diff-scoped
  (critical-path Audiobooks/LCP).
- The 3.0s/0.5s budget is PROVISIONAL — unvalidated against real LCP first-open
  engine init (network + decrypt). Like WS-4, the REAL fix needs device/simdrive
  validation with a live LCP title + toolkit timing; folds into the same Mac/device
  pass as WS-4's `_exit` ceiling. Unit-green ≠ "fixed".
