# Account State Machine — Systemic Fix for the Load-Readiness Race Class

**Status:** Proposed (2026-05-18) — PoC on `feature/account-state-machine-3.2.0`. Ships 3.2.0.
**ForgeOS initiative:** `init_dde7f99a`
**Companion docs:** [architectural-triad.md](./architectural-triad.md), [swarm-workflow.md](./swarm-workflow.md)

## TL;DR

`Account` has no enforced load-readiness contract. Code reads `currentAccount?.details?.loansURL` and gets *populated, nil, or stale* — there is no invariant that says "if I'm reading this, details have loaded." That race class has produced **two confirmed in-field bugs in the last 30 days** (plus three related bugs in adjacent classes), each fixed with a workaround for its specific window rather than the underlying class.

This ADR proposes:

1. **`Account.LoadState`** enum (`notLoaded → basicInfoLoaded → detailsLoading → detailsLoaded(AccountDetails) | detailsFailed(AccountLoadError)`) as the authoritative readiness signal.
2. **`Account.awaitReady() async throws -> AccountDetails`** as the only correct way new code reads `details`.
3. **`AccountStateStore`** — process-wide external storage keyed by UUID, so the state machine survives Account instance swaps during `loadCatalogs`.
4. **`Account.stateStream: AsyncStream<LoadState>`** for display-only consumers to observe transitions without polling.
5. **Mutation-testing strict gate** on `Account.swift`, `AccountsManager.swift`, `AccountStateStore.swift`, and every migrated call site.

Migration is **additive, opportunistic, and swarm-coordinated** across ~15-25 `account.details` reader sites in the 3.2.0 cycle. Legacy `Account.details?` reads keep working alongside `awaitReady()` until each call site is migrated; the API stays dual-track through 3.2.x for tolerant call sites we don't touch.

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

### What this state machine actually fixes (honest accounting)

| Bug | Race surface | Race-class? | State-machine prevents? |
|---|---|---|---|
| **F-016** Settings/Libraries blank on cold launch | `accountSets` empty during async load | ✅ Yes | ✅ Yes — `basicInfoLoaded` blocks display-only reads from running on `.notLoaded` |
| **Marketplace audiobook open fails (3.0.3 hotfix #957/#959)** | `Account.details.loansURL` nil → wrong feed source → wrong acquisition shape → wrong file extension | ✅ Yes | ✅ Yes — `awaitReady()` blocks the audiobook borrow path until `.detailsLoaded` |
| F-017 Inverted-filter cleanup hid libraries | `accountsToRemove` filter `==` should be `!=`; only fired once accountSets non-empty | ❌ Logic bug (race masked it) | ❌ Not prevented; state machine is orthogonal |
| PP-4329 Library-selector stacking on first launch | 8 `TPPCatalogDidLoad` NotificationCenter observers leaked on re-entrant call | ❌ NotificationCenter observer leak | ❌ Different surface; state-stream observers are AsyncStream so they self-clean, but the leaked observers in PP-4329 weren't state-stream observers |
| First-open audiobook spinner | State transition fires before AudiobookPlaybackPresenter subscribes | ❌ UI subscription timing | ❌ Out of scope for Account state machine |

**Real count: 2 race-class bugs.** Worth fixing systemically because (a) the next one in this class is statistically near-certain given the existing API shape, and (b) the F-016 → audiobook regression chain demonstrated that fixing one race in this class can *open* another.

The shape of every previous fix has been the same: detect that we read past nil, then either (a) wait/retry, (b) fall through to a default, or (c) recover at the symptom site. None of them fix the underlying assumption ("details is loaded by the time I read it").

## Decision

Introduce a state machine on `Account` that makes load-readiness **observable, awaitable, and type-enforced**.

### API surface (as shipped in the PoC)

```swift
extension Account {
    /// Authoritative load state.
    enum LoadState: Sendable {
        case notLoaded
        case basicInfoLoaded
        case detailsLoading
        case detailsLoaded(AccountDetails)
        case detailsFailed(AccountLoadError)
    }

    /// Current load state. Returns `.notLoaded` until AccountsManager
    /// drives a transition. Backed by `AccountStateStore.shared`.
    var loadState: LoadState { get }

    /// AsyncStream of state transitions for this account. Emits the
    /// current state immediately on subscribe, then each transition.
    var stateStream: AsyncStream<LoadState> { get }

    /// Async readiness gate. Blocks until terminal state.
    /// - Returns: `AccountDetails` on success.
    /// - Throws: `AccountLoadError` on `.detailsFailed`; `CancellationError`
    ///   on Task cancellation.
    /// - Single-flight per UUID (AccountsManager is responsible for
    ///   single-flighting the underlying network fetch).
    /// - Cancelling one awaiter does NOT abort the load.
    func awaitReady() async throws -> AccountDetails
}

public final class AccountStateStore {
    /// Process-wide singleton — state is single-instance per UUID.
    public static let shared: AccountStateStore

    func state(for uuid: String) -> Account.LoadState
    func stateStream(for uuid: String) -> AsyncStream<Account.LoadState>

    // Internal-access transition seam (AccountsManager + tests):
    func setState(_ state: Account.LoadState, for uuid: String)
    func reset(for uuid: String)
}

public enum AccountLoadError: Error, Equatable, Sendable {
    case authDocumentFetchFailed(underlyingDescription: String)
    case malformedAuthDocument(reason: String)
    case accountNotFound(uuid: String)
}
```

### Why state lives in `AccountStateStore`, not on `Account`

**Account instance identity is not stable.** `AccountsManager.account(_ uuid:)` looks up from `accountSets[hash]`, and `loadCatalogs()` **replaces** that array with newly-constructed Account objects from the network response (see `AccountsManager.swift:241` and the F-016 fix `eadfc500c`).

If state lived on the Account instance, the transition from `.detailsLoading → .detailsLoaded` would land on the new instance constructed by `loadCatalogs`, but every consumer holding the old instance from the disk preload would never observe the transition. `awaitReady()` would hang forever.

`AccountStateStore` keys storage by UUID instead. UUID stays stable across Account instance swaps; the state machine survives `loadCatalogs` replacing the instance.

### State transitions

```
notLoaded ─────preloadAccountsFromDiskCacheSync────→ basicInfoLoaded
basicInfoLoaded ─loadCatalogs.fetchAuthDoc(uuid)──→ detailsLoading
detailsLoading ──auth doc parse success──────────→ detailsLoaded(Details)
detailsLoading ──auth doc fetch fails────────────→ detailsFailed(Error)
detailsFailed ──user-initiated retry─────────────→ detailsLoading
detailsLoaded ──library reselect / sign-out──────→ notLoaded
```

**Invariant:** monotonic forward under the cold-launch path; cycles only on user-initiated retry or library reselect/sign-out.

**Single-flight ownership:** `AccountsManager` is responsible for ensuring only one in-flight `fetchAuthDoc(uuid)` per UUID. `Account.awaitReady()` does not enforce single-flight at the gate — it just observes the store's stream. Multiple concurrent `awaitReady()` calls per UUID share the same in-flight fetch via the store's broadcast semantics.

### Call-site migration policy

The full migration sprint (3.2.0 swarm) covers ~15-25 `account.details`-reader sites. The "60 files" figure in the initial scoping was based on `AccountsManager.shared|currentUserAccount` references, which is a broader surface. Re-measure during architect triage in Phase 1.

Each call site falls into one of four buckets:

| Bucket | Call site pattern | Migration |
|---|---|---|
| **A** Critical-path readers of `details` | Audiobook open path (`AudiobookLoader.resolveManifestAndDecryptor`), MyBooks borrow/sync trigger, `/loans/` URL builder in `BookRegistrySync`, `TPPNetworkResponder` SAML reauth coordinator | Migrate to `await account.awaitReady()` — must succeed or surface error to user (see UX contract below) |
| **B** Display-only reads | Settings → Libraries list, account-detail header strings, library logo | Migrate to `stateStream` observation — show skeleton/loading on `.detailsLoading`, error affordance on `.detailsFailed` |
| **C** Tolerant of nil | Analytics, breadcrumbs, error-log userInfo, debug screens | Leave on legacy `details?` API; document the tolerance |
| **D** Tests | All `PalaceTests` references to `account.details` | Migrate to inject pre-loaded mock state via `AccountStateStore.shared.setState(.detailsLoaded(mockDetails), for: uuid)` |

The architect agent triages every call site into a bucket before the swarm dispatches.

### UX contract for Bucket A awaits

`awaitReady()` blocks for up to the duration of the auth-doc fetch (500ms–10s typical, longer on cold network). Each Bucket A consumer must declare its UX policy for the await window:

| Call site | UX during await | Timeout |
|---|---|---|
| Audiobook open (`AudiobookLoader.resolveManifestAndDecryptor`) | Existing audiobook open spinner stays up — already covers the blocking window | Inherit existing 20s session-manager timeout (do not add a second timeout) |
| MyBooks borrow trigger | Borrow button enters processing state; row spinner; cancel reverts state | 30s — surface `.borrowFailed` on timeout |
| `/loans/` URL builder in `BookRegistrySync` | Silent (sync runs in background); registry stays in `.unloaded` until ready | No additional timeout — `BookRegistrySync` already has its own retry policy |
| `TPPNetworkResponder` SAML reauth | Already has its own reauth modal; await happens before modal presents | 15s — fall through to existing reauth-coordinator path on timeout |

**Single timeout policy:** never wrap `awaitReady()` in an additional `withTimeout` if the caller already has its own pipeline timeout. The existing audiobook open path has 20s; do not stack a 30s gate on top.

### Test strategy

1. **Contract-snapshot tests** for the load order (Phase 1 deliverable, NOT in this PoC). Pin:
   - `AccountsManager.init` → `preloadAccountsFromDiskCacheSync` → state[uuid] == `.basicInfoLoaded`
   - `loadCatalogs` → `fetchAuthDoc(uuid)` → state[uuid] == `.detailsLoading`
   - Auth doc success → state[uuid] == `.detailsLoaded(Details)`
   - Auth doc failure → state[uuid] == `.detailsFailed(Error)`
   - Library reselect → state[uuid] == `.notLoaded`
2. **API-level tests** (this PoC, `PalaceTests/Accounts/AccountStateMachineTests.swift`):
   - Initial state is `.notLoaded`
   - `awaitReady()` fast paths on terminal states
   - `awaitReady()` blocks during `.detailsLoading`, unblocks on transition (F-016 → audiobook regression repro converted to positive test)
   - Multiple concurrent awaiters all resolve on single transition (single-flight observability)
   - Cancellation isolation (one cancelled awaiter doesn't abort others)
   - `stateStream` emits current-then-transitions in order
3. **Mutation-testing strict gate** on `Account.swift`, `AccountStateStore.swift`, `AccountsManager.swift` (loadCatalogs changes), and every migrated call site. **Threshold: 50% kill rate** — matches Palace's existing standard, no special elevation needed for this surface.
4. **Regression repro**: a test constructing the F-016/audiobook scenario (sync preload completes, async details still pending, audiobook borrow path triggered) and asserting `awaitReady()` blocks until details load. This test passing means the audiobook race is unrepresentable in the new API.

### Migration sequence (3.2.0 swarm)

```
Phase 0 (this PoC, complete)
  ├── Architecture doc (this file)
  ├── Account.LoadState enum + AccountStateStore (additive, no behavior change)
  ├── Account.awaitReady() readiness gate
  └── 7 API-level contract tests

Phase 1 — Wiring + Bucket A (5 days, 3 swarm agents in parallel)
  ├── Wire: AccountsManager.preloadAccountsFromDiskCacheSync calls
  │   AccountStateStore.shared.setState(.basicInfoLoaded, for: uuid)
  ├── Wire: loadCatalogs.fetchAuthDoc transitions through .detailsLoading
  │   to .detailsLoaded / .detailsFailed
  ├── Wire: AccountsManager single-flights per-UUID auth doc fetches
  ├── Agent: Audiobooks + MyBooks (estimated 5-8 call sites)
  ├── Agent: SignInLogic + Settings (estimated 4-6 call sites)
  └── Agent: Network + OPDS (estimated 3-5 call sites)
  After: every critical-path read goes through awaitReady()

Phase 2 — Bucket B (3 days, 2 swarm agents in parallel)
  ├── Agent: Settings/Libraries + Account detail UI (estimated 3-5 call sites)
  └── Agent: Reader2 + Holds (estimated 2-3 call sites)
  After: display sites observe state transitions, show skeletons during load

Phase 3 — Bucket D + Mutation gate (2 days, 1 agent)
  └── Migrate tests; enable strict mutation gate on changed files
```

(AccountsManager actor isolation is a separate initiative for 3.2.x — out of scope here.)

## Consequences

### What this fixes

- **The F-016 → audiobook regression chain.** `awaitReady()` blocks the audiobook borrow path until details load; the book record is built from the correct feed; file saves with the correct extension; open succeeds.
- **The F-016 launch race.** Settings/Libraries display code observes `stateStream` and renders skeletons during `.detailsLoading` rather than blank lists.
- **The next race in this class.** Code that needs details must declare it via `awaitReady()`; reading raw `details?` becomes a documented opt-in for Bucket C tolerance.

### What this does NOT fix

- **F-017 inverted-filter logic bug.** State machine is orthogonal to logic-bug class.
- **PP-4329 NotificationCenter observer leak.** Different surface; idempotency-and-cleanup pattern is a separate fix shape.
- **First-open audiobook spinner.** UI subscription timing on `AudiobookPlaybackPresenter`, not load readiness.
- **`BookRegistry` race class.** Same disease shape, different organ. Should adopt the same state-machine pattern in 3.3.0 as a separate initiative.
- **`TPPNetworkResponder` auth-state race.** Tangentially related — auth state is owned by `TPPUserAccount`, not `Account`. Could adopt the same pattern but out of scope here.

### Risks and mitigations

| Risk | Mitigation |
|---|---|
| Migration leaves the codebase in a mixed state where some readers use new API, some old | Bucket policy (A migrate, B migrate, C stays) documented; **aspirational lint rule** to warn on new code using `account.details?` outside Bucket C files — needs to be built; if not built before Phase 1, accept silent-drift risk |
| `awaitReady()` introduces unbounded wait if auth doc fetch hangs | Per-call-site timeout policy documented above; never stack timeouts |
| State stream backpressure on a hot library-switch loop | AsyncStream defaults to unbounded buffering; if a hot loop emerges, configure `bufferingOldest(1)` so subscribers always get the latest state, not a history |
| Test surface grows substantially | Phase 0 PoC adds 7 tests (~180 LOC); Phase 1 adds ~10 integration contract tests; Phase 2-3 add per-migrated-site tests. Estimated total: +30-40 new test cases, +10-15% PalaceTests run-time |
| Account instance swaps during `loadCatalogs` would break per-instance storage | Fixed: state lives in `AccountStateStore` keyed by UUID, decoupled from Account instance identity |

## Non-goals

- **3.1.0 changes.** Release branch is cut and stable; will not touch.
- **Removing legacy `account.details?` API.** Stays available; Bucket C call sites keep using it. Removal is a 3.3.0+ consideration.
- **Actor-isolating `AccountsManager.accountSets`.** Bigger refactor; deferred to a separate initiative once the state machine is proven.
- **`BookRegistry` or `AudiobookSession` state machines.** Same shape, separate initiatives.
- **Feature flag for the rollout.** Per direction, ship enabled. Trust the tests + mutation gate.
- **Building the `account.details?` lint rule.** Aspirational — flagged as a risk if not built before Phase 1; not a Phase 0 deliverable.

## Open questions (Phase 1 must resolve)

1. **Single-flight enforcement** lives in `AccountsManager.fetchAuthDoc`, not in `Account.awaitReady`. Phase 1 must verify a single-flight policy when wiring the transition seam. Concretely: if two callers ask for the same UUID's details concurrently while `.detailsLoading`, only one HTTP request fires.
2. **Library reselect** resets state to `.notLoaded`. Phase 1 must wire this in `AccountsManager.currentAccount = newValue` so awaiters of the previous account get a definitive terminal state (probably `.detailsFailed(.accountNotFound)`) instead of hanging forever on a stream that no longer transitions.
3. **`Account.details` legacy backing** stays available unchanged — Phase 1 wiring writes to BOTH `Account.details` (legacy backing) AND `AccountStateStore` so Bucket C consumers see no behavior change.
