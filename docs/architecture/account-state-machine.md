# Account State Machine — Systemic Fix for the Load-Readiness Race Class

**Status:** Proposed (2026-05-18) — PoC on `feature/account-state-machine-3.2.0`. Ships 3.2.0.
**ForgeOS initiative:** `init_dde7f99a`
**Companion docs:** [architectural-triad.md](./architectural-triad.md), [swarm-workflow.md](./swarm-workflow.md)

## TL;DR

`Account` has no enforced load-readiness contract. Code reads `currentAccount?.details?.loansURL` and gets *populated, nil, or stale* — there is no invariant that says "if I'm reading this, details have loaded." That race class has produced **five distinct in-field bugs in the last 30 days**, each fixed with a workaround for its specific window rather than the underlying class.

This ADR proposes:

1. **`Account.State`** enum (`notLoaded → basicInfoLoaded → detailsLoading → detailsLoaded(Details) | detailsFailed(Error)`) as the authoritative readiness signal.
2. **`Account.awaitReady() async throws -> Account.Details`** as the only correct way new code reads `details`.
3. **`AsyncStream<Account.State>` on `AccountsManager`** so consumers can observe transitions without polling.
4. **Mutation-testing strict gate** on `Account.swift`, `AccountsManager.swift`, and every migrated call site.

Migration is **additive, opportunistic, and swarm-coordinated** across 60 files in the 3.2.0 cycle. Legacy `Account.details?` reads keep working alongside `awaitReady()` until each call site is migrated; the API stays dual-track through 3.2.x for low-traffic call sites we don't touch.

## Context: the race class

`AccountsManager` loads accounts in two pieces, on two different schedules:

| Source | What it populates | Latency |
|---|---|---|
| `preloadAccountsFromDiskCacheSync()` (added in F-016 fix `eadfc500c`, 3.0.2) | `accountSets[hash]` — basic Account objects from on-disk OPDS2CatalogsFeed (library registry cache) | <10ms |
| `loadCatalogs()` (background, on every cold launch + library switch) | Per-library `authentication_document` fetch → `Account.details` (auth methods, `loansURL`, `annotationsURL`, etc.) | 500ms–10s (network) |

UI code reads `currentAccount?.details?.loansURL` (and friends) at unpredictable times in this window. Three outcomes:

1. **Lucky** — details already loaded; everything works.
2. **Unlucky** — details still nil; code silently takes the "no loans URL" path (different feed, different acquisitions parse, different file extension on disk).
3. **Stale** — details from a prior account that hasn't been updated yet on library switch.

Five recent bugs in this class (all fixed individually, all hotfix material):

| Bug | Race surface | Fix shipped |
|---|---|---|
| **F-016** Settings/Libraries blank on cold launch | `accountSets` empty during async load | Synchronous disk preload (`eadfc500c`) — itself opens the **next** race |
| **F-017** Inverted-filter cleanup hid libraries | `accountsToRemove` filter inverted; only fires when `accountSets` non-empty | One-line filter fix (`eadfc500c` follow-up) |
| **Marketplace audiobook open fails (3.0.3 hotfix #957/#959)** | `Account.details.loansURL` nil → wrong feed source → wrong acquisition shape → wrong file extension | Recursive `hasLCPAcquisition` + symlink recovery — defends against the race, doesn't eliminate it |
| **PP-4329** 2-4 library selectors stacking on first launch | 8 `TPPCatalogDidLoad` notification observers leaked on re-entrant call | Idempotency guard + observer cleanup |
| **First-open audiobook spinner** (3.1.0 open) | State transition fires before player view subscribes | Open |

The shape of every fix has been the same: detect that we read past nil, then either (a) wait/retry, (b) fall through to a default, or (c) recover at the symptom site. None of them fix the underlying assumption ("details is loaded by the time I read it").

## Decision

Introduce a state machine on `Account` that makes load-readiness **observable, awaitable, and type-enforced**.

### API surface

```swift
extension Account {
    /// Authoritative load state. Driven by AccountsManager during
    /// loadCatalogs() and per-library authentication_document fetches.
    enum State: Equatable, Sendable {
        case notLoaded
        case basicInfoLoaded         // From OPDS2CatalogsFeed disk cache
        case detailsLoading          // Auth doc fetch in flight
        case detailsLoaded(Details)
        case detailsFailed(Error)
    }

    /// Current load state. KVO-compliant; backed by AccountsManager.
    var state: State { get }

    /// Async readiness gate. Blocks until state transitions to
    /// .detailsLoaded(Details) or .detailsFailed(Error). New code that
    /// needs Details MUST use this gate; do not read `details?` directly.
    ///
    /// - Returns: Resolved `Details` on success.
    /// - Throws: The underlying load error, wrapped as `AccountLoadError`.
    /// - Cancellation: Honors `Task.checkCancellation()`. Cancelling the
    ///   awaiting task does NOT abort the load; other awaiters keep going.
    func awaitReady() async throws -> Details
}

extension AccountsManager {
    /// AsyncStream of state transitions for a specific account. Emits the
    /// current state immediately on subscribe, then each transition.
    /// Multiple subscribers safe (state is broadcast).
    func stateStream(for uuid: String) -> AsyncStream<Account.State>
}

enum AccountLoadError: Error {
    case authDocumentFetchFailed(underlying: Error)
    case malformedAuthDocument(reason: String)
    case accountNotFound(uuid: String)
}
```

### State transitions

```
notLoaded ──preloadAccountsFromDiskCacheSync──> basicInfoLoaded
basicInfoLoaded ──loadCatalogs.fetchAuthDoc──> detailsLoading
detailsLoading ──auth doc parse success──> detailsLoaded(Details)
detailsLoading ──auth doc fetch fails──> detailsFailed(Error)
detailsFailed ──manual retry (e.g. user re-opens screen)──> detailsLoading
detailsLoaded ──library reselect/sign-out──> notLoaded
```

Invariant: **monotonic forward** under the cold-launch path; cycles only on user-initiated retry or sign-out.

### Call-site migration policy

The full migration sprint (3.2.0 swarm) covers ~60 files. Each is in one of four buckets:

| Bucket | Call site pattern | Migration |
|---|---|---|
| **A** Critical-path readers of `details` | Audiobook open path (`AudiobookLoader.resolveManifestAndDecryptor`), MyBooks borrow/sync trigger, `/loans/` URL builder in `BookRegistrySync`, `TPPNetworkResponder` SAML reauth coordinator | Migrate to `await account.awaitReady()` — must succeed or surface error to user |
| **B** Display-only reads | Settings → Libraries list, account-detail header strings, library logo | Migrate to `state` observation (Combine `@Published` or AsyncSequence) — show skeleton/loading on `.detailsLoading` |
| **C** Tolerant of nil | Analytics, breadcrumbs, error-log userInfo, debug screens | Leave on legacy `details?` API; document the tolerance |
| **D** Tests | All `PalaceTests` references to `account.details` | Migrate to inject pre-loaded mock state via `Account.State.detailsLoaded(mockDetails)` |

The architect agent triages every call site into a bucket before the swarm dispatches. Bucket A and B migrations are the bulk of the work and are the highest-leverage. Bucket C stays as-is to keep the migration scope bounded.

### Test strategy

1. **Contract-snapshot tests** for the load order. Pin:
   - `AccountsManager.init` → `preloadAccountsFromDiskCacheSync` → state[uuid] == `.basicInfoLoaded`
   - `loadCatalogs` → `fetchAuthDoc(uuid)` → state[uuid] == `.detailsLoading`
   - Auth doc success → state[uuid] == `.detailsLoaded(Details)`
   - Auth doc failure → state[uuid] == `.detailsFailed(Error)`
   - Multiple concurrent `awaitReady()` callers all unblock on transition
2. **Mutation-testing strict gate** on `Account.swift`, `AccountsManager.swift`, and every migrated call site. ≥60% kill rate required for merge.
3. **Regression repro**: a test that constructs the F-016/audiobook regression scenario (sync preload completes, async details still pending, audiobook borrow path triggered) and asserts that `awaitReady()` blocks until details load instead of returning nil. If this test passes, the audiobook race is unrepresentable in the new API.

### Migration sequence (3.2.0 swarm)

```
Phase 0 (this PoC)
  ├── Architecture doc (this file) — review + approve
  ├── Account.State enum (additive, no behavior change)
  ├── Account.awaitReady() stub backed by existing storage
  ├── AccountsManager.stateStream(for:) plumbing
  └── Contract test pinning preload → loadCatalogs order

Phase 1 — Bucket A (5 days, 3 swarm agents in parallel)
  ├── Agent: Audiobooks + MyBooks (15 call sites)
  ├── Agent: SignInLogic + Settings (20 call sites)
  └── Agent: Network + OPDS (10 call sites)
  After: every critical-path read goes through awaitReady()

Phase 2 — Bucket B (3 days, 2 swarm agents in parallel)
  ├── Agent: Settings/Libraries + Account detail UI (8 call sites)
  └── Agent: Reader2 + Holds (5 call sites)
  After: display sites observe state transitions, show skeletons during load

Phase 3 — Bucket D + Mutation gate (2 days, 1 agent)
  └── Migrate tests; enable strict mutation gate

Phase 4 — AccountsManager actor isolation (separate initiative, 3.2.x)
  └── Replace performRead/performWrite with actor semantics
```

## Consequences

### What this fixes

- **The F-016 → audiobook regression chain.** `awaitReady()` blocks the audiobook borrow path until details load; the bookrecord is built from the correct feed; file saves with the correct extension; open succeeds.
- **PP-4329-class observer leaks.** State-stream subscribers are cleanup-on-cancel by AsyncStream semantics; no manual `removeObserver` plumbing required for state observation.
- **The next race in this class.** Code that needs details must declare it via `awaitReady()`; reading raw `details?` becomes a documented opt-in for tolerance.

### What this does NOT fix

- **`BookRegistry` race class.** Same disease, different organ — book records loaded from disk vs. /loans/ sync. Tracked separately; should adopt the same state-machine pattern in 3.3.0.
- **`AudiobookSessionManager` state propagation race.** The "first-open audiobook spinner" bug is about UI subscription timing, not load readiness. Different fix needed.
- **`TPPNetworkResponder` auth-state race.** Tangentially related — auth state is owned by `TPPUserAccount`, not `Account`. Could adopt the same pattern but out of scope here.

### Risks and mitigations

| Risk | Mitigation |
|---|---|
| Migration leaves the codebase in a mixed state where some readers use new API, some old | Bucket policy (A migrate, B migrate, C stays) is documented; lint rule warns on new code using `account.details?` outside Bucket C files |
| `awaitReady()` introduces unbounded wait if auth doc fetch hangs | Wrap with `withTimeout(30s)` in critical-path callers; `detailsFailed` is a terminal state that all callers must handle |
| State stream backpressure on a hot library-switch loop | AsyncStream is buffer-policy-aware; configure `bufferingOldest(1)` so subscribers always get the latest state, not a history |
| Test surface grows substantially | Mutation testing on changed files compensates — the cost is paid once during migration, not on every PR |

## Non-goals

- **3.1.0 changes.** Release branch is cut and stable; will not touch.
- **Removing legacy `account.details?` API.** Stays available; Bucket C call sites keep using it. Removal is a 3.3.0+ consideration.
- **Actor-isolating `AccountsManager.accountSets`.** Bigger refactor; deferred to a separate initiative once the state machine is proven.
- **`BookRegistry` or `AudiobookSession` state machines.** Same shape, separate initiatives.
- **Feature flag for the rollout.** Per direction, ship enabled. Trust the tests + mutation gate.

## Open questions

1. Should `awaitReady()` be re-entrant for the same library? I.e. if the user calls it twice for the same UUID, do they share the same in-flight fetch? **Default: yes** — `AccountsManager` should single-flight the auth doc fetch per UUID.
2. Should `state` itself be `AsyncSequence` instead of polling? `stateStream(for:)` covers this — `state` is a one-shot read for legacy compat.
3. How does this interact with cross-library sign-in (Reset Account, library switch)? **State resets to `.notLoaded`** on library reselect, then progresses normally. The state machine handles this cleanly.
