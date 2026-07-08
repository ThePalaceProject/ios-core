# swarm_27c181b5 — outcome (Wave A / PR1)

## Status: Wave A integrated + built + spot-tested green. Waves B, C pending.

## Wave A (Tier 1 standard + instrumentation) — 4 modules, 4 parallel implementers
- **CatalogUI**: A1 cache-respecting reload split (`reload(invalidatingCache:)`; handleAccountChange→false=SWR, refresh→true; protocol-routed invalidate, cast removed), A2 de-triple-fire in switchToAccount, A3 dropped duplicate auth-doc load, A5 shared CatalogRepository via AppContainer, `.catalogLoaded` milestone.
- **Covers**: B1 circuit-breaker honors `failureThreshold` (was hardcoded ≥1) + reachability-change reset() observer, B2 thumbnail-URL coalescing for small displays, B3 reviewed — duplicate `.set` RETAINED (instance identity unprovable; documented, not guessed).
- **Accounts-Startup**: C1 registry cache read-once (FileManager existence check), C4 O(n²)→`[uuid:Account]` dict carry-over, B1 `resetHostFailures()` call on account switch.
- **Startup-AppLifecycle**: AppLaunchTracker `.processStart`/`.didFinishLaunching`/`.firstFrame` wired, C2 GeneralCache purge off-main (sync version gate), C3 deferred audio-session config (remote-commands unchanged).

## Integrator fixes (2 cross-module compile gaps at the Covers/Accounts seam)
1. Added `nonisolated func resetHostFailures()` to `TPPBookCoverRegistry` (Accounts called `.reset()` which lived on the internal HostFailureTracker actor). Corrected the AccountsManager comment (decoded covers already dropped by `evictDecodedImages()`; the reset targets the circuit breaker).
2. `nonisolated(unsafe)` on `reachabilityObserverToken` — Swift 6 forbids touching a non-Sendable stored property from an actor's `nonisolated deinit`.

## Gates
- check-test-name-vs-body ×8 → 0 fake-wiring; check-blast-radius exit 0; check-superpartner exit 0; all contract-verification greps pass.
- **Build: TEST BUILD SUCCEEDED (0 errors)** on the integrated worktree.
- New/modified test classes (spot-check, `test-without-building`): 7 classes, all passed, 0 failures. Full-suite CI-parity gate deferred to the PR's CI run (per green-board contract — CI runs the whole scheme ×3 iterations).

## Deferred to follow-on PRs (by design, per landing sequence)
- **Wave B / PR2 (Network N1/N2)** — cache-clear split-brain routing; SoD review (touches SignInLogic + executor).
- **Wave C / PR3 (critical_path D1/D2/D3)** — slim launch snapshot, credential-snapshot caching, first-run off-main decode; each needs architect Phase 1a + SoD.
- **Tier 4** — OPDSFeedCache disk-persist + ETag (not contracted).
