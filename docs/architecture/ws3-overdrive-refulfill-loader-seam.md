# ADR: Injectable loader factory on AudiobookSessionManager (WS-3 OverDrive re-fulfill)

**Status:** Accepted (coordinator-approved, pending architect SoD)
**Date:** 2026-06-11
**Context:** WS-3 / 3.2.0 crash-triage follow-up — OverDrive expired-signed-URL
playback dead-end (`fleet/w-lane-overdrive`).

## Context

The WS-3 fix adds a bounded re-fulfill recovery to
`AudiobookSessionManager.handleManagerState`'s `.playbackFailed` case: when an
OverDrive audiobook's time-limited signed URL expires (HTTP 410), re-open the
book with `forceRefulfill` so it re-fetches FRESH signed URLs (bypassing
`LocalFileAdapter`'s stale on-disk manifest) instead of dead-ending.

The load-bearing proof is "the re-fulfill produces an audiobook bound to the
FRESH URL, not a cached replay." Proving that requires observing the URL the
loader actually builds into the audiobook. Before this change the loader was
constructed inline (`let loader = AudiobookLoader(forceRefulfill:)`), with no
seam to inject a spy.

## Decision

Add a minimal, default-preserving injection seam to `AudiobookSessionManager`:

```swift
var makeLoader: (Bool) -> AudiobookLoader = { AudiobookLoader(forceRefulfill: $0) }
```

and widen `handleManagerState` from `private` to `internal` (visibility only —
no new API surface). `openAudiobook` now calls `makeLoader(forceRefulfill)`
instead of the inline constructor.

## Production-behavior-unchanged invariant (the hard constraint)

The default `makeLoader` closure is **byte-equivalent** to the inline
`AudiobookLoader(forceRefulfill:)` it replaces. Production never overrides
`makeLoader`, so runtime behavior on the real path is identical to before. The
seam is exercised only by tests, which assign a spy closure returning
`AudiobookLoader(adapters: [spyAdapter])` (`AudiobookLoader` is `final`, so the
spy is at the adapter level). `handleManagerState`'s widening is visibility-only.

## What this seam does and does NOT prove

- **Proven without the seam, at the loader boundary** (no session auth gate):
  `AudiobookLoader(adapters:[spy]).load()` with a spy resolving a manifest whose
  track href is FRESH builds a `LoadedAudiobook` whose first track URL == FRESH
  (and a STALE control == STALE) — the resolved URL is *consumed* into the built
  audiobook (`OverdriveFulfillmentTests.testRefulfill_freshManifestURL_isConsumedIntoBuiltAudiobook`).
- **Proven by predicate units:** the recovery DECISION (OverDrive + HTTP 410 +
  not-already-attempted → re-fulfill; 403/401/no-status/non-OverDrive/already →
  fall through) and the per-session BOUND.
- **NOT unit-covered (intentionally):** the thin auth-gated wiring inside
  `handleManagerState`'s recovery branch (predicate fires → `Task { openAudiobook(forceRefulfill:true) }`
  → `validateRequirements` → `makeLoader(true)`). Driving it end-to-end requires
  a ready authenticated `currentAccount` (deep `AccountsManager` state-machine
  setup not exposed by any existing test helper). That few-line glue is covered
  by architect SoD review of this diff + device/simdrive validation of live
  OverDrive playback — the same device-validation ceiling as the other 3.2.0
  audiobook crash fixes (CarPlay `playerNotReady`, LCP `isLoaded`).

## Consequences

- Additive and reversible. One injectable property + one visibility widening on a
  critical-path file — flagged for architect SoD specifically to confirm the
  default-preserving invariant and the absence of any behavior change.
- The integration test seam pattern (inject the loader factory) is reusable for
  future `AudiobookSessionManager` recovery-path tests.
