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

---

## Wave C (PR3) — D1 + D2 complete, dual-SoD approved

- **D1 (launch snapshot):** slim sync hydration + off-main full decode; fixed a real ordering bug (eviction-marker clobbered by cancelled-fetch completion → awaitReady consumers stuck) via fetchCompletionMayWriteTerminal guard; F4 (reuse slim instance) + F5 (refresh slim on switch + full-hydrate fallback). Architect BLOCKED on F4/F5, both fixed + re-APPROVED (rev_89a182f5); QA APPROVED (rev_ad57b8d3).
- **D2 (credential snapshot):** removed per-request keychain re-read (coherence via write-through + single-instance, verified); event-driven invalidation on sign-out + switch. Architect (rev_50928319) + QA (rev_45b56ca3) APPROVED; fixed a shared-singleton test-pollution bleed + a zero-tests -only-testing selector.
- **Combined tests:** 44 pass, 0 failures (independently verified on sim 141BD227).
- **D1 mutation (diff-only vs pre-Wave-C, AccountsManagerLaunchSnapshotTests):** 6 killed / 3 survived = **66.7%** (>50% critical-path threshold). Ordering-guard + F4/F5 + .detailsLoading-entry mutants all KILLED. Survivors: line 808 (`!=`→`==` account-switch guard) is D2's line — killed by D2's testAccountSwitch, out of this run's selector; lines 711/558 are minor carveSlimFeed boundary guards (malformed-no-id / empty-accounts edge cases, low-risk). D2 TPPUserAccount mutation: reviewer-verified mutant-kill (restore-per-read + no-op) per QA review; exact palace_mutate number deferrable to verify-pr --enforce-mutations.
- **Sim safety:** all Wave-C builds on 141BD227; avoided 1C4E6D56 (pp4531) + 743E6F1D (live simdrive).

## Wave C follow-ups (tracked, non-blocking)
- F6: rapid A→B→A dedup-vs-cancel (pre-existing; slim drive widens window slightly).
- D1 QA #2/#3: a consumer test that actually awaits awaitReady(); a direct slimSnapshotUUIDs() unit test.
- Architect minor: clearCache() sweeps the slim file but not in-memory slimAccountsByUUID (self-healing).
- D2 advisory: a future launch-migration that rewrites credential VALUES out-of-band must fire invalidateCredentialCaches().
