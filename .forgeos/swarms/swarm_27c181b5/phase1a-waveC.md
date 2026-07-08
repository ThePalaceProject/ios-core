# Wave C — Architect Phase 1a (critical-path design gate)

Per-contract verdicts. This gate caught two issues that would have caused real damage.

## CP-D1 (LaunchHydration) — BLOCKED (cheap corrections)
Design (slim sync snapshot + lazy full list behind the EXISTING `Account.awaitReady()`
gate) is architecturally sound; the readiness gate already exists.
BLOCKING:
1. **Profiling contradiction (decisive).** Contract claims the sync preload costs
   ">5s CI / 100-500ms mid-tier", but the code comment (AccountsManager.swift:482-483)
   says it's "single-digit ms local I/O" — a ~1000× disagreement. The >5s is more
   plausibly the background `loadCatalogs` network crawl (D3/QoS territory), NOT the
   sync preload. **REQUIRE: profile `preloadAccountsFromDiskCacheSync` in isolation
   against the 1142-account cache and paste wall-time BEFORE building slim machinery.**
   If it's single-digit ms, D1 is optimizing the wrong thing → defer/cancel.
2. `accountsHaveLoaded` call-graph gap: slim set writing into `accountSets[accountSet]`
   flips it true with ~2 accounts → picker sees truncated list (self-heals, but spec
   the slim/full boundary + add a picker-full-count test).
3. Stale test citation: `testDriveCurrentAccountAuthDoc_staleAccountNotFoundMarker_redrives`
   does not exist. Real round-trip = `testLibraryReselect_reentry_resetsState_andRedrives`
   (:818); eviction marker = `testDriveCurrentAccountAuthDoc_staleEvictionMarker_redrives` (:910).

## CP-D2 (CredentialSnapshot) — APPROVED (mandatory test amendments)
Design sound + SAFE. Architect proved the coherence guarantee is preserved by
WRITE-THROUGH keychain (`TPPKeychainStoredVariable.write()` sets cachedValue + persists),
one `TPPUserAccount` instance per library UUID, and NO cross-process writer (no
app-groups/keychain-sharing/extensions in entitlements). So per-call invalidation is
NOT the primary coherence mechanism — removing it is safe; event-driven invalidation
is defense-in-depth. Wave B rebase region clean (D2 = executor :403; Wave B = :421).
AMEND: sign-out-staleness test must drive `AccountDetailViewModel` (the real build-459
surface); explicitly confirm `TPPNetworkResponder` 401-decision (OFF-LIMITS, 9 callers
of credentialSnapshot) isn't weakened by a cached read.

## CP-D3 (FirstRunDecode) — BLOCKED (real regression in the naive fix)
Diagnosis confirmed (double bundled decode, one on main). BLOCKING:
1. **Mechanical "move dedupe above bundled branch" REGRESSES first-run:** the existing
   `:920` guard would then see the caller's own registration → return true → skip
   `fetchFromNetwork` at `:922` → picker stuck on stale bundled data until next launch.
   REQUIRE: CONSOLIDATE to a single dedupe guarding the bundled branch and REMOVE the
   redundant `:920` guard. Add a test asserting the NETWORK FETCH still fires exactly
   once (the contract's "bundled decode once" test would pass while this regression ships).
2. QoS bump `:475` is the release arm only; the DEBUG arm `:471` (`Task.detached(.background)`)
   also needs bumping or tests exercise a different QoS than prod.
Dependencies real: depends_on D1 (shared AccountsManager) + Network (shared TPPAppDelegate).

## Disposition
- D2: ready to dispatch after Wave B lands (amended tests) — cleanest/safest.
- D1: **profile first** — its existence is in question. Do not build until measured.
- D3: contract needs the dedupe-consolidation correction + strengthened test; sequence after D1.

---

## CP-D1 profiling evidence (2026-07-08) — UNBLOCKS D1

Measured the `preloadAccountsFromDiskCacheSync` work against the real 1142-account
`bundled_registry.json` (2,386,937 bytes) on the iPhone-17 simulator (fast host):

| stage | ms |
|---|---|
| OPDS2CatalogsFeed.fromData (JSON decode) | 94.8 |
| map → 1142 Account(...) | 111.6 |
| _setState(.basicInfoLoaded) ×1142 | 0.6 |
| **TOTAL (main thread, pre-window)** | **207.0** |

Verdict: the code comment at AccountsManager.swift:482 ("single-digit ms local I/O")
undercounts — it measured only the file read, not the decode + 1142 Account
constructions that dominate. **~207ms on a fast sim ⇒ ~0.3-0.6s on a mid-tier
device**, all on the launch main thread. **D1 is JUSTIFIED.** The design is also
confirmed: the 95ms decode means lazy Account construction alone is insufficient — a
separate slim persisted snapshot (current + settings accounts, ~KB) is needed so the
full 1142-decode moves off-main. D1 blocking item #1 (profiling) is now satisfied;
items #2 (slim/full boundary + picker-full-count test) and #3 (test citation fix)
remain contract corrections before dispatch.
