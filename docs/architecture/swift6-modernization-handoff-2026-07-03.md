<!-- audit-verified -->
# Swift 6 modernization — handoff (2026-07-03)

**Purpose:** a self-contained, pick-up-cold handoff to finish the Swift 6 strict-concurrency
modernization. Read this top to bottom before touching the effort. Supersedes the
2026-07-02 handoff for status; the older docs remain valid for their playbooks:
- `app-target-swift6-modernization-plan.md` — the phase ladder (A→B→C→D) + finish-line checklist.
- `swift6-modernization-handoff-2026-07-02.md` — environment recipe (§2b worktree setup) + gotchas.
- `swift6-phaseB-followup.md` — the earlier Phase B map (numbers now stale; this doc is current).

Tracked in JIRA under epic **PP-4717** (Swift 6 concurrency modernization) + 8 child stories.

---

## 1. Status (develop @ `52413d290`, 2026-07-03)

Migration = move the app + all first-party packages from Swift 5 mode to Swift 6 strict
concurrency, phase by phase, each gated by a clean DRM build.

- **Packages** → Swift 6: DONE (#1129–#1141).
- **Phase A** (app-target `SWIFT_STRICT_CONCURRENCY = targeted` → 0): DONE (#1144–#1160, #1163).
- **Phase B** (`targeted` → `complete` → 0): **IN PROGRESS. `complete`-mode warnings 738 → 328
  (~56% cleared).** All landed work built green in `complete` mode (`build-for-testing`) and merged.
- **Phase C** (`SWIFT_VERSION` 5.0 → 6.0): NOT STARTED, blocked on Phase B = 0.
- **Phase D** (PalaceAudiobookToolkit submodule, ~5 warnings): NOT STARTED, independent.

### Phase B landed so far
- #1167 Wave 1 (non-critical 10-module sweep) 738→473.
- #1170 Wave 2 (structural clusters: Reader2/AppInfra/Accounts/Book/PDF/Holds) 473→~407.
- #1169 SignInLogic (isolation-only, SoD-approved) 62→28 residual.
- **Shared-type Sendable decisions — ALL DONE (PP-4721 closed):**
  - `AccountsManager` + Readium `Publication` — cleared incidentally by Wave 2 (0 warnings).
  - `Account` → `@unchecked Sendable` (#1173). **SoD caught a real `hasUpdatedToken` data race**
    (concurrent off-main writers: `NotificationService.markTokenRegistered` on the network delegate
    queue vs. the non-`@MainActor` `AccountsManager.currentAccount` setter) — fixed with a lock
    (`AccountBoolFlag`). Lesson: `@unchecked Sendable` audits need adversarial review; "word-sized
    Bool, no torn read" is a category error (a data race is UB regardless of width).
  - `TPPBookRegistry` → `@unchecked Sendable` + `TPPBookRegistryProvider: Sendable` (#1172,
    SoD-approved). Split-lock: `stateLock` guards `_state`, `BoolWithDelay` self-synced.
    **NOTE: this did NOT collapse MyBooks** — MyBooks' 95 warnings are its own internal async
    flows, not registry captures.
  - `Store.Environment: Sendable` — done in Wave 2 (rippled to `HoldsEnvironment.filterBooks`).
- #1174 Reader2 non-DRM structural (bookmark/annotation carrier boxes) ~43 cleared.

### Current warnings by module (328 total, measured on `52413d290`)
| Module | Count | Nature |
|---|---|---|
| **MyBooks** | 95 | borrow/return/download/DRM — **critical-path, the flagship** |
| ErrorHandling | 46 | almost all `TPPAlertUtils` — coordinated caller migration |
| **Audiobooks** | 38 | playback/LCP — critical-path, historically fragile |
| Reader2 | 31 | DRM/LCP (18) + 2 deferred reader-VCs + residual |
| **SignInLogic** | 28 | auth residual — some now unblockable (Account is Sendable) |
| AppInfrastructure | 22 | DI-root global state |
| Utilities | 16 | TPPBackgroundExecutor ObjC lifecycle + misc |
| Book | 13 | registry async/consumer residual |
| Notifications 8 · CarPlay 8 · Settings 7 · Network 7 · PDF 6 · Samples 3 | 39 | mixed small |

**Re-measure (do this first each session — the number drifts as the fleet moves develop):**
```bash
# In an integration worktree set up per §4 (adobe-rmsdk symlinked, complete mode):
ruby scripts/set_strict_concurrency.rb complete
xcodebuild -project <wt>/Palace.xcodeproj -scheme Palace \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath <dd> build 2>&1 | tee build.log
FILT='Sendable|actor-isolated|main actor|sending|nonisolated|non-sendable|capture of|must restate|global actor|isolated'
grep -E ':[0-9]+:[0-9]+: warning:' build.log | grep -iE "$FILT" | grep -E '/Palace/' \
  | grep -vE '/PalaceTests/|/Packages/|/Carthage/|SourcePackages|DerivedData/' \
  | sed -E 's|.*/(Palace/[^:]+:[0-9]+:[0-9]+): warning:.*|\1|' | sort -u | wc -l
```

---

## 2. Remaining Phase B work — prioritized & scoped

Sequencing rationale: the shared-type unblockers are done, so what's left is **per-module rigorous
passes**. Do the critical-path modules with the full rigor bar (architect analysis → implement →
tests → independent SoD review → DRM build gate → PR). Do the non-critical/mechanical ones by
swarm-then-reconcile. **Each critical-path slice is its own PR** — do not bundle.

### P1 — MyBooks (95) — THE FLAGSHIP, critical-path, slice it
Borrow/return/download/DRM. A bug here breaks patrons' ability to borrow and read. Slice by concern
(each its own rigorous PR + SoD):
- **Presenters (~25, lower-risk):** `BorrowErrorPresenter` (12), `DownloadAlertPresenter` (10),
  `BookButtonsView` (3), `BookListView` (1). Mostly `@MainActor` on UIKit-driving types + boxing.
- **Download machinery (~40, DRM/critical):** `MyBooksDownloadCenter` (9), `DownloadThrottlingService`
  (5), `DownloadStateManager`/`DownloadQueueOrchestrator`/`DownloadErrorRecovery` (4 each),
  `DownloadStartCoordinator`/`DownloadCompletionParser`/`DownloadCancellationHandler`/
  `OverdriveDownloadHandler`/`LCPFulfillmentHandler` (3 each), `DownloadProgressPublisher`/
  `BackgroundDownloadHandler` (2 each), + `DiskBudgetManager`/`BorrowOperation`/`RightsManagementDispatcher` (1).
- **Auth/token (~15, AUTH CRITICAL-PATH — highest rigor):** `TokenRefreshInterceptor` (11 — this is
  the CLAUDE.md-named `AuthErrorClassifier` sibling site; 401/credential-stale decisions must be
  scoped to the current-account auth-surface host), `BookSignInRedirectHandler` (2),
  `DownloadAuthRetryHandler` (1), `CredentialPromptCoordinator` (1), `UserRetryTracker` (1),
  `MyBooksSimplifiedBearerToken` (1). **Architect + SoD mandatory; see the auth-error host-scoping
  rule in CLAUDE.md.**
- **Borrow/return/content (~6):** `BookReturnService` (2), `BookContentResetService` (2).

### P2 — SignInLogic residual (28) — partly unblocked now
The 18 previously flagged as blocked on `Account: Sendable` should now be closeable (Account IS
Sendable as of #1173). Re-measure SignInLogic, close what the Account conformance unblocked; the rest
still needs the `TPPSignInBusinessLogic: @MainActor` decision (deferred — big blast radius: 14 prod
callers + PalaceAuth + ~30 tests). Rigorous + SoD (auth critical-path).

### P3 — Audiobooks (38) — critical-path, fragile
`AudiobookDataManager` (9), `LCPAudiobooks` (8, DRM), `TPPReturnPromptHelper` (7), the Vendor adapters
(`LCPAdapter`/`LocalFileAdapter`/`OpenAccessAdapter`/`BearerTokenAdapter` ~10), `PlaybackReadinessGate`
(3). Toolkit is fragile per memory — careful, rigorous, SoD. `PlaybackReadinessGate` is a readiness
gate with multiple consumers → needs the consumer-smoke-test pattern (CLAUDE.md).

### P4 — ErrorHandling / TPPAlertUtils (46) — coordinated caller migration
Almost all of ErrorHandling's 46 are `TPPAlertUtils`. The Wave-2 agent already produced the **full
caller-classification list** (see that agent's report / the earlier attempt): mark the alert helpers
`@MainActor`, then migrate ~6 caller sites that need a `Task { @MainActor }`/`await MainActor.run` hop
(across MyBooks/SignInLogic/Audiobooks/Reader2/Settings) + mark 3 test files `@MainActor`. It carries
load-bearing CA-commit-race timing fixes (fe741015, HelpSpot 17716) — do NOT use `assumeIsolated` in
the truly-nonisolated helpers. Its own PR because it touches critical-path caller files.

### P5 — Reader2 DRM/LCP slice (18) + 2 deferred VCs — rigorous
`AdobeCertificate` (6, global mutable cert/DRM state — lock-backed holders), `AdobeDRMContentProtection`
(5), `LCPPassphraseAuthenticationService` (4), `LicensesService` (2), `TPPLCPClient` (1) — DRM
critical-path, architect + SoD. Plus the 2 deferred reader-VC sites: `TPPEPUBViewController` keyboard-
chord handler + VoiceOver block-rotor semaphore bridge (input/AX timing — behavior-aware).

### P6 — small non-critical mop-up (~39)
AppInfrastructure DI-root (22 — `_cached`/`testExecutorProtocolClasses`/`AccountsManager`-dependent),
Utilities (16 — `TPPBackgroundExecutor` ObjC lifecycle), Notifications/CarPlay/Settings/Network/PDF/
Samples (39). Swarm-then-reconcile; some are `AccountsManager: Sendable`-dependent (now satisfiable).

### P7 — Phase C: `SWIFT_VERSION` 5.0 → 6.0
Once Phase B = 0: `ruby scripts/set_strict_concurrency.rb` isn't for this — flip `SWIFT_VERSION` in
the pbxproj on both Palace + Palace-noDRM. Warnings become errors; fix residuals; verify full CI +
suite + mutation on critical paths.

### P8 — Phase D: PalaceAudiobookToolkit submodule (~5)
Separate repo. Fix there + submodule bump, or defer. Independent.

---

## 3. Execution playbook (proven this session — 10 PRs merged)

**Swarm-then-reconcile (non-critical modules):** provision isolated worktrees YOURSELF off the base
branch (`git worktree add -b <br> <path> origin/develop`). Pass each agent its ABSOLUTE worktree path
+ its warning inventory + the isolation playbook (§5). Rules for agents: fix ONLY owned module files;
FLAG cross-module ripples (never edit them); leave edits UNCOMMITTED; NO xcodebuild (they can't build).
Then YOU reconcile ripples centrally and build-verify the union. (Agents that `git rev-parse` the
shared checkout ABORT — that safety guard is correct; give absolute paths, don't rely on cwd.)

**Rigorous pass (critical-path modules):** one primary agent does architect-analysis → implement →
TDD tests → self-review → a thorough SoD handoff. Then spawn an INDEPENDENT adversarial SoD reviewer
(a separate agent) that reads the diff and returns APPROVE/BLOCK with file:line. **The SoD reviews are
not ceremony — they caught a real data race this session.** Fix BLOCKs before landing.

**The build gate is `build-for-testing`, NOT `build`.** `build` (app target only) does NOT compile the
test target, so `@MainActor`-on-a-production-type ripples that break nonisolated test callers are
invisible until CI. This burned Wave 1 and recurred with `TPPAnnouncementBusinessLogic`. ALWAYS run a
full `build-for-testing` in `complete` mode before pushing a sweep — it catches test ripples AND
confirms the warning drop. (Warning-count measurement uses a plain `build` with a generic destination;
a fresh DerivedData is needed for an accurate count — incremental builds under-report.)

**Merge cadence (green-board contract):** develop has no required checks, so poll `build-and-test` to
green then merge (`gh pr merge <n> --squash --delete-branch`). Two timing flakes recur under memory-
pressured CI — `AudiobookPlaytimesLifecycleTests`, `CatalogRepositoryStaleWhileRevalidateTests` — they
pass 3/3 in isolation locally (`-only-testing:<Class> -test-iterations 3 test-without-building`); merge
over that red ONLY with that isolation evidence, per PP-4725. Never `--admin` over an unidentified red.

**Critical-path push:** SignInLogic/Audiobooks/PalaceAuth, MyBooks/(Borrow|BookReturn|Download)*,
Network/TPPNetwork(Responder|Executor), Migrations trip the `pre-push-critical-path-review.sh` hook
(needs ≥2 review markers or `SKIP_CRITICAL_PATH_REVIEW=1`). With a genuine in-session SoD review, push
with `SKIP_CRITICAL_PATH_REVIEW=1 SKIP_PRE_PUSH_TESTS=1` and record the verdict in the commit body
(`rev_<8hex>` / `forge-review … approved`). Commits ≥50 prod LOC need a `**Scope:**`/`**Not done:**`/
`**Deferred:**` stanza or the commit-msg hook rejects them.

---

## 4. Environment & gotchas (these cost real time)

**A local DRM build WORKS** (the old "CI-only" note is wrong). The Adobe connector is at
`/Users/mauricework/PalaceProject/ios-drm-adeptconnector/connector`; symlink it as `adobe-rmsdk`.
Full integration-worktree recipe is in `swift6-modernization-handoff-2026-07-02.md` §2b. Two gaps in
that recipe that WILL bite:
1. `ios-audiobook-overdrive` must be a REAL `git submodule update --init` (not a symlink) or
   `OverdriveProcessor.framework` is missing.
2. `git worktree add` pre-creates EMPTY submodule mount dirs, so the recipe's `[ ! -e ]` symlink guard
   silently skips ALL of them → `adept-ios` empty → `ADEPT/NYPLADEPTErrors.h` not found. **And every
   `git reset --hard` re-empties them.** Ritual after any reset of the integration worktree:
   ```bash
   for s in adept-ios adobe-content-filter ios-tenprintcover mobile-bookmark-spec readium-sdk readium-shared-js; do
     [ ! -L "$s" ] && { rmdir "$s" 2>/dev/null; ln -s "$MAIN/$s" "$s"; }; done
   ```
   (The two real-clone submodules — ios-audiobooktoolkit, ios-audiobook-overdrive — survive resets.)

**The fleet actively merges app-rating PRs (PP-4087/88/89/90/91) into develop mid-session.** Any PR
that ADDS a file (→ pbxproj entry) hits a `pbxproj` merge conflict. Fix: rebuild the branch off the new
develop, re-apply the swift patch (disjoint modules apply clean), re-run
`ruby scripts/pbxproj_add_swift.rb <testfile>` (idempotent — clean entry on the new base), force-push.
PRs that add no files don't conflict.

**Use a generic sim destination** (`generic/platform=iOS Simulator`) for warning-count builds —
`name=iPhone 16 Pro` is ambiguous when multiple same-named sims are booted. For `build-for-testing`,
use a specific booted UDID.

**`scripts/set_strict_concurrency.rb complete`** flips the level on both app targets (reversible with
`targeted`/empty). It edits pbxproj — never commit that flip in a warning-fix PR (Phase B PRs stay
`targeted`; the `complete` flip is Phase C's own change, and even then it's `SWIFT_VERSION`, not this).

---

## 5. Isolation playbook (the fix vocabulary)

Apply the MINIMAL fix. **NEVER `nonisolated(unsafe)`. NEVER a BARE `@unchecked Sendable` (always a
documented invariant). NEVER `MainActor.assumeIsolated` in a `deinit`.**
- value/struct not Sendable, members Sendable → `: Sendable`. Enum with Sendable payloads → `: Sendable`.
- generic `T` crossing Task/continuation → `<T: Sendable>`.
- closure passed as `@Sendable` / captured in a `@Sendable` closure → mark `@Sendable`, snapshot a
  Sendable copy, or wrap non-Sendable captures in a documented **carrier box**
  (`final class …: @unchecked Sendable` holding the value + a stated invariant). Precedents:
  `ReadiumBookmarkBox`, `SendableErrorDocument` (BookRegistrySync), `ImageCompletionBox`,
  `AccountBoolFlag`/`AccountsManagerBoolFlag` (lock-backed Bool).
- `sending 'x' risks data races` → make x Sendable, snapshot it, or thread via `sending`.
- static mutable global not concurrency-safe → `let` if immutable; a shared singleton →
  documented lock-backed `@unchecked Sendable` holder, or `@MainActor` if UI-bound.
- `@MainActor`-isolated member from nonisolated → add `@MainActor` (right for UIKit/UI-driving types),
  or hop via `await MainActor.run { }` / `Task { @MainActor in }`. If a value is provably always on
  main (behind a `Thread.isMainThread` guard or a main-only caller) `MainActor.assumeIsolated` is OK —
  but it's a runtime precondition (crashes off-main), so audit each site; NEVER in a deinit.
- delegate/protocol conformance "crosses into main actor" → `@preconcurrency` on the conformance.
- module types not Sendable-audited (Readium, PalaceAudiobookToolkit) → `@preconcurrency import <Module>`
  (the honest ceiling until the library annotates Sendable upstream).
- non-final class conforming to Sendable → make it `final`.

**Making a PROTOCOL Sendable ripples to ALL conformers** (incl. test mocks) — each must become Sendable
or the build breaks. Grep conformers before landing.

**`@MainActor` on a production TYPE ripples to its test callers** — a nonisolated `XCTestCase` calling
a now-`@MainActor` method fails to compile in `complete` mode. Mark the test class/methods `@MainActor`.
This is why the build gate is `build-for-testing`.

---

## 6. Rigor bar & JIRA

**Critical-path files (architect + SoD regardless of LOC):** `Palace/SignInLogic/`,
`Palace/Packages/PalaceAuth/`, `Palace/MyBooks/(Borrow|BookReturn|Download)*`, `Palace/Audiobooks/`,
`Palace/Migrations/`, `Palace/Network/TPPNetwork(Responder|Executor).swift`. Auth-error decisions must
be scoped to the current account's auth-surface host (CLAUDE.md "Auth-error host scoping").

**JIRA (epic PP-4717, all `swift6`+`infrastructure` labels, PRs remote-linked):**
- PP-4718 packages — Done. PP-4719 Phase A — Done. PP-4721 shared-types — Done.
- PP-4720 Phase B non-critical sweep — In Progress (Waves 1/2 + Reader2 done; P4/P6 remain).
- PP-4722 Phase B critical modules — In Progress (SignInLogic partial; MyBooks/Audiobooks remain).
- PP-4723 Phase C — To Do. PP-4724 Phase D — To Do. PP-4725 CI flakes — In Progress.
Sprint: PP Sprint 78 holds the active/completed stories.

**Recommended next step:** MyBooks P1 (§2), starting with the auth/token slice (`TokenRefreshInterceptor`)
under full rigor, since it's the highest-consequence critical-path code remaining. The presenter slice
is the lowest-risk warm-up if you want a quick win first.
