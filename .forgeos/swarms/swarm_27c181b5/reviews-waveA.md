# Wave A — SoD review verdicts

Two independent reviewers (did not write the code) reviewed the Wave-A diff
(21 files, +1165) against plan.md and the 4 contracts.

## Architect review — `rev_795ebaec` — APPROVED
Verified all 6 lens points against the actual code:
- CatalogUI A1 SWR split SOUND — uncached library still reloads (SWR short-circuits
  only on a cache hit); switch funnel verified end-to-end (setter posts → onReceive
  → handleAccountChange); protocol-routed invalidate valid; ABA cache-serve real
  (account-UUID-scoped repo held as StateObject).
- Covers B1 SOUND — immutable `failureThreshold`, observer captures only Sendable
  tracker (no retain cycle/leak), `nonisolated(unsafe)` token defensible,
  `resetHostFailures()` name matches call site.
- Covers B2/B3 SOUND — pixel-based decoded-cache key means no cross-contamination;
  duplicate `.set` correctly retained (independent injection points).
- Accounts C1/C4 SOUND — `fileExists` preserves gate semantics; `Dictionary(uniquingKeysWith:{first,_ in first})` matches `first(where:)`.
- Startup C2/C3 SAFE (highest-risk, scrutinized) — `ensureAudioSessionActiveForPlayback()`
  still calls `configureAudioSession()` synchronously before every `play()`; deferral
  is launch-only; `setupRemoteCommands()` unchanged; GeneralCache version gate stays sync.
- Concurrency/state-machine CLEAN.

Non-blocking: `.processStart` recorded inside a Task (approximation); cache flag
written before purge completes (self-healing caches); thumbnail upscale on small
cells (chosen tradeoff); pre-existing identical-URL refresh guard.

## QA / test review — `rev_3caea866` — APPROVED
No test is fluff/tautology/mutation-blind on the core changes:
- Threshold test kills the `>=1` mutant; ABA test fails if a switch invalidates;
  refresh/handleAccountChange invalidate-count tests exercise the protocol seam;
  C4 per-uuid carry-over at scale; GeneralCache version-gate branches; audio-session
  defer test defeats fake-wiring (asserts category==.playback after running the
  captured closure). Accounts tests properly isolated (PalaceWiringTestCase).

Non-blocking: AppLaunchTracker test pins timing math but doesn't drive the
production call sites (fire-and-forget instrumentation — acceptable); reachability
observer wiring untested (name overclaims; thin hop); C1 read-once structurally
verified only (no injectable reader seam — disclosed).

## Disposition
Both APPROVED. Non-blocking findings tracked for Wave B test-hardening; none block PR1.
