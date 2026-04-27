# Architectural Triad — Plan and Decision Log

> Multi-phase architectural work to close the gap between the modernize/whole-shot refactor's claimed state and the actual state. Three axes: dependency injection adoption, the Store reducer pattern, and the singleton / god-class purge.

**Target release:** 3.0.0
**Status (2026-04-27):** Phases 1–5 shipped via PRs #866 + #867. Phases 6–7 planned.

---

## Why this epic exists

The modernize/whole-shot refactor (PR #811) shipped real wins:

- Objective-C: 82 files → 5 (−94%)
- Test count: 5,353 test functions across 370 files
- Concurrency adoption: 26 actors + 79 `async` functions
- OPDS 2 support landed

But three headline claims from that refactor turned out to be **infrastructure-built, adoption-skipped**:

1. **"DI ~80% complete" — not really.** `AppContainer` existed at `Palace/AppInfrastructure/AppContainer.swift` but was touched by 5 files / 11 references / **1** `@Environment(\.appContainer)` injection. 732 `.shared` call sites remained across 166 files; 59 `static let/var shared` declarations.
2. **"SPM Phase 4 done" — not really.** `PalaceFoundation` and `PalaceNetworking` packages had **0** `import` statements across `Palace/`. Worse: in-target files had **diverged** from the package versions (`TPPAsync.swift` and `Reachability.swift` had different content between `Palace/Utilities/` and `Packages/*/Sources/`). The packages were abandoned stale copies.
3. **"God class: complete" — not really.** `MyBooksDownloadCenter.swift` was 3,036 LOC. `BookDetailViewModel.swift` was 1,085 LOC. Six files topped 700 lines.

The triad epic closes the gap between the claimed state and the actual state, so the 3.0.0 architecture story is honest.

---

## Verified audit snapshot (epic start, 2026-04-24)

| Metric | Count |
|---|---|
| `.shared` call sites | 732 across 166 files |
| `static let/var shared` declarations | 59 across 55 files |
| `AppContainer` references | 11 across 5 files |
| `@Environment(\.appContainer)` injections | **1** |
| `import PalaceFoundation` / `PalaceNetworking` | 0 |
| Tests | 5,353 functions / 370 files |
| Tests touching `.shared` (singleton-coupled) | 70 files / 628 references |

**Top offender files (`.shared` call sites at epic start):**

- `TPPAppDelegate.swift` (50) — composition root, acceptable
- `MyBooksDownloadCenter.swift` (38 + 16 in `+Async.swift`) — 3,036 LOC god class
- `TPPDeveloperSettingsTableViewController.swift` (25) — dev-settings UI, acceptable
- `BookDetailViewModel.swift` (21) — critical-path infecting VM
- `TPPUserAccount.swift` (20 internal) — class itself
- `PlaybackBootstrapper.swift` (15)
- `BookCellModel.swift` (14)
- Six files at 12–13 each

**Test coverage on offenders (dedicated `*FileTests*.swift`):**

- `BookDetailViewModel`: 125 ✓
- `AccountsManager`: 57 ✓
- `TPPAnnotations`: 47 ✓
- `MyBooksDownloadCenter`: 23 (thin for a 3,036 LOC class)
- **`TPPSignInBusinessLogic`: 0** (758 LOC, critical path)
- **`BookActionHandler`: 0** (critical path)

The two zero-coverage critical-path files made Phase 3 (characterization tests) a hard prerequisite for Phase 5 (reducer migration of those flows).

---

## Phase roadmap

### Phase 1 — Foundations

**Goal:** land the keystone so future work is mechanical churn, not architectural decisions.

**Scope:**

- **1.1** Delete `Palace/Packages/` entirely. The packages were dead infrastructure: 0 import statements app-wide, package files NOT in the app target's Sources build phase, and `TPPAsync.swift` / `Reachability.swift` had divergent (strictly inferior) package copies that nothing consumed. Keeping them perpetuated the false "Phase 4 (SPM) done" claim.
- **1.2** Promote `AppContainer` to a real DI root. ~12 services added: `MyBooksDownloadCenter`, `PlaybackBootstrapper`, `AudiobookSessionManager`, `BookActionHandler` (later deleted), `BookRegistrySync`, `AccountsManager`, `TPPUserAccount` resolver, `TPPBookRegistry`, `TPPAnnotations`, `TPPNetworkExecutor`, `FeatureFlags`, `TPPErrorLogger`. Production graph constructs without `.shared` reads during init. Protocol-based surface so tests substitute.
- **1.3** Write `Store<State, Action, Environment>` (~70 LOC closure-based reducer + Effect type). Pure reducer + async effects. Not TCA — minimal ceremony for a solo-dev codebase.
- **1.4** Migrate `HoldsViewModel` to Store as pilot. View diff ≤20 lines. 3 reducer unit tests.

**Exit criteria:**

- `git grep "@Environment(\.appContainer)"` returns ≥5 sites
- `Palace/Packages/` no longer exists
- `StoreTests` + `HoldsReducerTests` pass
- Full test suite green

### Phase 1b — HoldsReducer extraction (pilot)

Proof-of-pattern reducer migration. `HoldsReducer` extracts the holds state machine as a pure function. 11 reducer-as-pure-function tests. Establishes the namespace shape (`enum Action`, `struct State`, `struct Environment`, `static func reduce(...)`) every subsequent reducer follows.

### Phase 2 — Purge infecting ViewModels

Migrate 7 ViewModels off `.shared`:

- `MyBooksViewModel.swift`
- `BookDetailViewModel.swift`
- `AccountDetailViewModel.swift`
- `SettingsViewModel.swift`
- `CatalogViewModel.swift`
- `CatalogLaneMoreViewModel.swift`
- `FacetViewModel.swift`

Per-file recipe:

1. Drop `= .shared` defaults from init; require explicit deps.
2. Add `convenience init(...:appContainer: AppContainer)` mirroring the field set.
3. Internal `Foo.shared.bar` → `self.foo.bar`.
4. Update test sites with sed/awk + manual fixes for capture-list errors.

**Exit:** `git grep '\.shared' Palace/**/*ViewModel.swift` returns only platform shims (`UIApplication.shared`, `FileManager.default`, `NotificationCenter.default`).

### Phase 3 — Characterization tests for the critical path

Write behavior-pinning tests for files with 0 dedicated coverage:

- `TPPSignInBusinessLogic.swift` (758 LOC, 0 tests, 16 test files touch it indirectly)
- `BookActionHandler.swift` (later deleted instead — it was dead code)

Tests cover: happy-path auth, auth-error branches, credential persistence, borrow happy path, borrow failure, hold placement, hold release.

**Exit:** ≥30 new tests per file, mutation testing kills ≥40% of mutants.

### Phase 4 — Service-layer singleton purge

Top offender services rewired via injected collaborators. Ran in parallel via 5 agents on disjoint file partitions (see [parallel-agent-rebase-walkthrough.md](./parallel-agent-rebase-walkthrough.md) for the technique):

| Agent | Files |
|---|---|
| `audiobook-services` | `AudiobookSessionManager.swift` (13), `PlaybackBootstrapper.swift` (15) |
| `annotations-bookmarks` | `TPPAnnotations.swift` (13) — uses an `executorOverride` extension pattern |
| `views-cleanup` | `AppTabHostView.swift` (11), `BookDetailView.swift` (11), `CatalogLaneMoreView.swift` (6), `MyBooksView.swift` (4), `SignInModalView.swift` (3) — all routed through `@Environment(\.appContainer)` |
| `download-center-decomposition` | `MyBooksDownloadCenter.swift` (38), `MyBooksDownloadCenter+Async.swift` (16) — 3,036 LOC, deferred decomposition to Phase 7 |
| Step 4.5 (post-rebase) | Killed `NavigationCoordinatorHub.shared` + `AppTabRouterHub.shared` — 12 consumer call sites migrated |

**Cycle-breaking pattern:** services that participate in singleton init cycles (anything `MyBooksDownloadCenter.shared` or `TPPBookRegistry.shared` reads from) wrap each other as `() -> Foo` provider closures resolved lazily. This was the keystone for breaking the historical `BookCellModelCache.shared` ↔ `production()` init-cycle deadlock.

**Exit:** total `.shared` call site count drops from 732 → 564 (−168, −23%).

### Phase 5 — Critical-path reducer migration

Reducer-extract sign-in and borrow flows:

- **`BorrowReducer`** — 12 actions covering borrow / download / return / reserve / cancel + auth-prompt callbacks. 19 reducer-as-pure-function tests. Integrated into `BookDetailViewModel.bindRegistryState` via a `snapshotBorrowState() / reduce / applyBorrowState` round trip — replaces the legacy inline switch. The snapshot/apply pattern preserves the existing 81 `BookDetailViewModelTests` (which directly mutate `@Published` properties) without rewriting them, because the reducer mirrors state through the VM rather than wrapping the VM in a Store.
- **`AuthReducer`** — 13 actions covering sign-in start, credential validation, success, failure, sign-out, OIDC/SAML browser callbacks. 21 reducer tests. **Not yet integrated** into `TPPSignInBusinessLogic` — kept as the testable contract. Integration is gated on writing characterization tests for that 758-LOC ObjC-bridged class first (it has 0 dedicated tests).

**Mutation testing on Phase 5 reducers:** 6/6 mutants killed (100% kill rate) — every conditional flip and return-value flip in both reducers is caught by the dedicated reducer tests. Per the project's "critical path tests must be air-tight" rule, this is the bar.

ReaderReducer (Phase 5b) deferred — `ReaderService` is already well-isolated, so the reducer migration buys little.

### Phase 6 — SPM module extraction (planned)

Narrow public interfaces via real SPM modules. Order by risk:

1. **`PalaceKeychain`** — 3 files, lowest risk, proves toolchain
2. **`PalaceCatalog`** — `CatalogDomain` + `CatalogUI` merged (already cohesive)
3. **`PalaceAuth`** — `SignInLogic` + `Accounts/User` + `Accounts/Library` + Keychain dep — **MUST land AFTER** the AuthReducer integration into `TPPSignInBusinessLogic`
4. **`PalaceReader`** — `Reader2` + PDF
5. **`PalaceAudiobooks`** — stretch

Key constraint: don't recreate the deleted `PalaceFoundation`/`PalaceNetworking` mistake — new modules **must be load-bearing on day 1** (≥1 import from the app target).

### Phase 7 — God class decomposition (planned, separate epic)

`MyBooksDownloadCenter.swift` is 3,036 LOC. Phase 4 only de-singletonized it; the body is intact. Decompose into:

- `DownloadQueue`
- `ProgressPublisher`
- `URLSessionBroker`
- `DRMFulfillmentDispatcher`
- `RetryPolicy`

Each piece becomes its own injectable type. The aggregator becomes a thin coordinator.

Other god-class candidates:

- `BookDetailViewModel.swift` (1,085 LOC) — partly addressed by Phase 5 BorrowReducer extraction
- `CarPlayTemplateManager.swift` (802 LOC)
- `TPPErrorLogger.swift` (816 LOC) — audit only, may be fine as-is

---

## Decision log

### Why delete `Palace/Packages/` rather than consume it

The packages were 0-imported, not in the build graph (verified via `pbxproj` absence), and the in-target copies of `TPPAsync.swift` / `Reachability.swift` had evolved beyond the package versions. Reconciling would have required moving `Log.error` and `TPPReachabilityChanged` notification names into a shared package — premature scope. Real SPM extraction is Phase 6, driven by feature cohesion not stub salvage.

### Why our own `Store<State, Action, Environment>` instead of TCA

Solo-dev codebase, want minimal ceremony. ~70 LOC closure-based reducer + `@MainActor ObservableObject` adapter. No scoped reducers, no pullback, no TestStore. If we ever outgrow it, TCA-style protocols can wrap this.

### Why `HoldsReducer` landed without the matching VM swap in Phase 1b

The existing 40+ `HoldsViewModelTests` directly assigned `@Published` properties and relied on `NotificationCenter`-driven side-effect timing. A faithful VM swap that preserves all those tests is its own focused refactor — bundling it with the reducer commit would have made the diff hard to review. The Store-wrapping VM landed in Phase 2 once the reducer's contract was settled.

### Why `AppContainer.production()` uses a private `static let _cached` instead of init defaults

Explicit is better than hidden. With defaults, calling `AppContainer()` silently read from `.shared` during construction — a subtle source of init-cycle deadlocks. The factory pattern makes the singleton dependency a single auditable line. The cache itself (`_cached`) is what breaks the historical `BookCellModelCache.shared` ↔ `production()` init cycle.

### Why `BorrowReducer` integrated into `BookDetailViewModel` via snapshot/apply, not via `Store` wrapping

`BookDetailViewModel` has 100+ tests that directly mutate `@Published` properties (`vm.bookState = .returning`, `vm.processingButtons = [...]`). Rerouting all of that through a `Store` would require rewriting those tests, which conflicts with the "preserve every test" constraint. The reducer is shaped to slot into `Store<State, Action, Environment>` once those test patterns are normalized in a future phase.

### Why `AuthReducer` isn't integrated into `TPPSignInBusinessLogic` yet

`TPPSignInBusinessLogic` is 758 LOC, ObjC-bridged, with 0 dedicated tests (only 16 test files touch it indirectly through other VMs). Wiring the reducer into it without a characterization-test safety net would be reckless on a critical path. The reducer ships as a testable spec; the integration is gated on Phase 3 characterization tests.

---

## Mechanical exit criteria for each phase

| Phase | Exit metric |
|---|---|
| 1 | `git grep "@Environment(\.appContainer)"` ≥5 sites; `Palace/Packages/` deleted; `StoreTests` + pilot reducer tests pass |
| 1b | `HoldsReducer` exists with ≥10 dedicated reducer tests |
| 2 | `git grep '\.shared' Palace/**/*ViewModel.swift` returns only platform shims |
| 3 | ≥30 new tests on each previously-untested critical-path file; mutation kill rate ≥40% |
| 4 | Total `.shared` call site count drops below 200 (excluding composition roots and platform shims); no init-cycle deadlocks in full-suite runs |
| 5 | All three flows (sign-in, borrow, reader-open) Store-driven with ≥80% reducer test coverage and 100% mutation kill on conditional / return-value mutants |
| 6 | Each SPM module exports `public protocol ModuleEnvironment`; app target composes in `AppInfrastructure/ModuleComposition.swift`; modules do NOT import `AppContainer` |
| 7 | No production file >1,000 LOC except acceptable composition roots |

---

## Reference

- [#866 — Architectural Triad: DI adoption, Store pattern, singleton purge (Phases 1-4)](https://github.com/ThePalaceProject/ios-core/pull/866) — 27 commits, `develop` base
- [#867 — Architectural Triad: Borrow + Auth reducers (Phase 5)](https://github.com/ThePalaceProject/ios-core/pull/867) — 3 commits, stacked on #866
