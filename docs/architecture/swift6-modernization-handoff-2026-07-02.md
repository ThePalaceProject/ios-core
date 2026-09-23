<!-- audit-verified -->
# Swift 6 modernization — pending-work handoff (2026-07-02)

**Purpose:** a fan-out-ready inventory of ALL remaining Swift 6 modernization work + the
established patterns, environment facts, and gotchas needed to dispatch each item to an
independent session/agent. Read this top-to-bottom before picking up any item.

Companion authoritative docs:
- `docs/architecture/app-target-swift6-modernization-plan.md` — the phase ladder (A→B→C→D), finish-line checklist, execution playbook.
- `docs/architecture/swift6-a5-remainder-plan.md` — the A.5 slice plan (now done) + deferred items.

---

## 1. Status snapshot (as of develop `d92f175c7`, 2026-07-02)

**Done & merged:**
- All 7 first-party SPM packages (#1129–#1141).
- Phase A.3 critical-path slices A–E (#1148–#1152).
- **#1155** — A.5 DRM slice (11 warnings) + `TPPUserAccount` `@unchecked Sendable`.
- **#1158** — A.5 remainder: Chunk 1 registry residue (11) + Chunk 2 non-critical sweep (21), via swarm `swarm_afec67f0`.
- **#1159** — two CI flakes root-fixed: Audiobook `AccountIdBox` race + FLAKE-003 migration-test `AccountsManager` preload (added `AccountsManager.deferDiskCachePreloadForTesting`).
- **#1160** — A.6 test-target sweep: 38 `PalaceTests` `targeted` warnings → 0.

**Current warning state (CI-measured on develop):**
- **App target (Palace/): 3 residual** `targeted` warnings — see items **P1** (2× AdobeDRM) and **P2** (1× CarPlay). Everything else is 0.
- **Test target (PalaceTests/): 0** ✅ (A.6 done).
- **PalaceAudiobookToolkit submodule: ~5** (Phase D, item P8).

**How to re-measure:** `gh workflow run "Unit Tests" --ref develop`, wait ~30 min, then grep the build log:
`gh run view <id> --log | grep -E ':[0-9]+:[0-9]+: warning:' | grep -iE 'capture of|must restate|Sendable|actor-isolated|nonisolated|non-sendable|sending|crosses into main actor'`
Split Palace/ vs PalaceTests/ vs Packages/.

---

## 2. Environment & gotchas (READ — these cost hours if unknown)

### 2a. A LOCAL DRM BUILD IS POSSIBLE (updates the old "no local DRM build" assumption)
The Adobe DRM connector IS present at `/Users/mauricework/PalaceProject/ios-drm-adeptconnector/connector`. With it symlinked as `adobe-rmsdk`, the `Palace` (DRM) scheme **builds and runs tests locally**. This session verified de-flakes by running classes ×10 locally. The prior "CI is the only build gate" note applies only to worktrees that DON'T set up adobe-rmsdk.

### 2b. Isolated-worktree setup recipe (Phase 0 — do this for every item)
The **main checkout is contended** — another live session holds a staged git index of tooling changes (skills, CLAUDE.md, verify-pr.sh, wall-failures). NEVER commit from main; never touch its staged files. Work in a dedicated worktree:
```bash
WT=".claude/worktrees/<id>"
git worktree add -b <branch> "$WT" origin/develop
MAIN=/Users/mauricework/PalaceProject/ios-core
cd "$WT"
mkdir -p Carthage/Build && cp -RL "$MAIN/Carthage/Build/." Carthage/Build/       # copy, NOT symlink
git submodule update --init -- ios-audiobooktoolkit                              # REAL clone (pbxproj refs ../Carthage/Build)
for s in adept-ios adobe-content-filter ios-audiobook-overdrive ios-tenprintcover mobile-bookmark-spec readium-sdk readium-shared-js; do
  [ ! -e "$s" ] && [ -e "$MAIN/$s/.git" ] && ln -s "$MAIN/$s" "$s"; done                # symlinks OK
[ ! -e adobe-rmsdk ] && ln -s /Users/mauricework/PalaceProject/ios-drm-adeptconnector/connector adobe-rmsdk   # DRM build
for f in Palace/AppInfrastructure/APIKeys.swift Palace/TPPSecrets.swift PalaceConfig/GoogleService-Info.plist PalaceConfig/ReaderClientCert.sig; do
  [ -e "$MAIN/$f" ] && [ ! -e "$f" ] && cp "$MAIN/$f" "$f"; done
```
Then build/test with `-project "$WT/Palace.xcodeproj" -scheme Palace -derivedDataPath <scratch>`.
Sim UDID used this session: `141BD227-6E9A-4409-8D99-2D4FE818238D` (iPhone 16 Pro).

### 2c. Hook path-skew (worktrees off develop predate some hook scripts)
PreToolUse hooks resolve `scripts/hooks/*.py` relative to the shell cwd. If cwd is a worktree lacking a newer hook script (e.g. `audit-before-assert.py`), Writes get blocked. **Fix: keep the shell cwd in the MAIN checkout; target worktree files via absolute paths and `git -C "$WT"`.** (This is how every commit this session was made.) The `audit-before-assert` hook requires an `<!-- audit-verified -->` attestation token in docs that make factual claims — add it once you've checked the claims.

### 2d. ForgeOS is OFF; don't invoke it
`FORGEOS_ENABLED` unset → the commit/push governance hooks `exit 0` early; nothing is required. Do NOT call `mcp__forgeos__*` (those send changeset/evidence/review metadata to `forgeos-api.synctek.io`) unless the operator explicitly turns ForgeOS on. Keep SoD reviews LOCAL (in-session reviewer agents; record verdicts in a committed `.forgeos/reviews/*.md` or the PR body). CLAUDE.md/CLAUDE.local.md were corrected this session to document this opt-in reality.

### 2e. Push hooks
- `pre-push-critical-path-review.sh` HARD-BLOCKS pushes touching critical-path files (`Palace/SignInLogic|Audiobooks|Packages/PalaceAuth`, `Palace/MyBooks/(Borrow|BookReturn|Download)*`, `Palace/Network/TPPNetwork(Responder|Executor)`, `Palace/Migrations`) unless the commit bodies carry ≥2 review refs (`rev_<8hex>` / `forge-review … approved`) — OR `SKIP_CRITICAL_PATH_REVIEW=1` (env var; NOTE it does NOT reach PreToolUse hooks, only the git-native ones). Book/Models is NOT in this regex.
- `pre-push-test-gate` tries a local build+test; bypass with `SKIP_PRE_PUSH_TESTS=1` when the worktree can't/shouldn't build (or let it run if adobe-rmsdk is set up).

### 2f. Merge pattern (proven this session, 4×)
Feature→develop uses **squash** (`gh pr merge <n> --squash --delete-branch`). develop has **no required checks**, so `--auto` would merge red — instead **poll `build-and-test` to green, then merge** (a background poll script that holds on red). Do NOT auto-merge over red.

### 2g. The flaky board — known families
- **FLAKE-003** = `AccountsManager.init` synchronously loads ~1138 cached accounts (>5s on memory-pressured CI). Fix: set `AccountsManager.deferDiskCachePreloadForTesting = true` in the test's `setUp` (reset in `tearDown`) for any test that constructs an AccountsManager it doesn't read accounts from. Fixed for migration tests in #1159; **still bites `TPPBookRegistryPersistenceTests` and likely other `makeFreshAccountsManager()` callers** (item P3).
- Timing/concurrency stress tests (e.g. `testConcurrentLocationUpdates_DoNotCrash`, audiobook `backgroundTaskStillEnds`) time out under a memory-pressured run. Re-run confirms environmental; root-fix where a real race exists (thread-safe the mock / use `syncQueue.sync {}` barriers — see #1159's `AudiobookPlaytimesLifecycleTests` fix).
- Green-board contract (CLAUDE.md): only re-run+merge over red when each failure is individually identified as a named, develop-passing flake WITH a de-flake item filed. Otherwise STOP.

### 2h. Established fix patterns (reuse — don't reinvent)
- **Carrier box** for capturing non-Sendable closures/values in `@Sendable` (`Task`/`MainActor.run`) closures: a documented `struct/final class … : @unchecked Sendable` wrapping them. Canon: `SyncCallbacks`/`SendableErrorDocument` (BookRegistrySync.swift bottom), `ImageCompletionBox` (ImageLoaderImpl.swift).
- **ObserverTokenBox** for `'token' mutated after capture` in self-removing NotificationCenter observers (TPPBookRegistry.swift).
- **`@unchecked Sendable` on a type** with a documented mutable-state audit (never bare; never `nonisolated(unsafe)` except REMOVING an unnecessary one).
- **isolate-at-site** (read main-actor state inside a `MainActor.run`, return a Sendable snapshot) instead of making a big singleton Sendable (e.g. AccountsManager → the TriageBotFactory site).
- **Test-double conformances:** `must restate inherited '@unchecked Sendable'` → add `, @unchecked Sendable` to the subclass. `conformance … crosses into main actor` on an `@MainActor` mock conforming to a *nonisolated* protocol → `@preconcurrency` on the conformance (or `nonisolated` witnesses / lock-backed `@unchecked Sendable` if a witness mutates state). `.shared`-from-nonisolated test methods → `@MainActor` on the method, or the production `assumeIsolated` hoist.

---

## 3. Pending work items (each independently dispatchable)

### P1 — AdobeDRM finish-slice  [CRITICAL-PATH · rigorous · SMALL · unblocks Phase-A-at-0]
- **Warnings (2):** `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMContentProtection.swift:247` (+1 nearby) — `non-Sendable parameter type '(Data) -> Void' cannot be sent from caller of protocol requirement 'stream(range:consume:)' into actor-isolated implementation; this is an error in the Swift 6 language mode`.
- **Why it's here:** #1155's DRM slice used `@preconcurrency import ReadiumShared` but didn't resolve the `stream(range:consume:)` closure-Sendability at :247.
- **Fix direction:** the `consume: (Data) -> Void` closure crosses into an actor-isolated `stream` impl. Options: mark the closure `@Sendable` at the protocol requirement (if ReadiumShared's protocol allows / via a wrapper), OR box it, OR make the consuming type nonisolated for that path. Needs reading ReadiumShared's `stream(range:consume:)` requirement + the Adobe impl.
- **Rigor:** DRM = critical-path → `/rigorous-fix` (architect + SoD, local reviewer agents). Verify with a local `Palace`-scheme DRM build (adobe-rmsdk present).
- **Done =** app-target `targeted` warning count drops from 3 → 1 (only CarPlay left).

### P2 — CarPlayTemplateManager:96 deinit slice  [behavior-aware · SMALL]
- **Warning (1):** `Palace/CarPlay/CarPlayTemplateManager.swift:96` — `call to main actor-isolated 'remove' in a synchronous nonisolated context` (deinit).
- **Why deferred:** the observer is `self`; the `remove` is load-bearing (prevents disconnect/reconnect crashes), so it can't be dropped; `assumeIsolated`-in-deinit and self-capturing `Task`-from-deinit are both banned.
- **Fix direction:** move the removal to a `@MainActor` teardown wired from `CarPlaySceneDelegate.didDisconnect` (already `@MainActor`, already nils `templateManager`), BEFORE dealloc. **Behavior question to prove:** does `didDisconnect`/teardown fire before EVERY dealloc (incl. app termination)? If not, the deinit removal must stay and the warning gets a scoped suppression instead.
- **Rigor:** touches CarPlay lifecycle → architect review of the teardown-before-dealloc invariant.
- **Done =** app-target `targeted` = 0 → Phase A app-target COMPLETE.

### P3 — FLAKE-003 de-flake extension  [test-only · SMALL · do EARLY, keeps board green]
- `TPPBookRegistryPersistenceTests` (uses `makeFreshAccountsManager()` at ~3 sites) hits the same >5s AccountsManager preload timeout that blocked #1160's first CI run. **Audit ALL `makeFreshAccountsManager()` callers** (`grep -rn makeFreshAccountsManager PalaceTests/`) and, for each that never reads account sets, add `AccountsManager.deferDiskCachePreloadForTesting = true` in `setUp` / reset in `tearDown` (the flag landed in #1159; it's on develop now).
- **Verify:** run each touched class ×10 locally (`-test-iterations 10`), confirm no timeout.
- **Done =** registry/persistence tests no longer flake on memory-pressured CI.

### P4 — Reader2 TPPReadiumBookmark cross-thread race (N2)  [pre-existing · medium]
- From the #1158 Chunk-2 architect review: in `TPPReaderBookmarksBusinessLogic.postBookmark`, the boxed `TPPReadiumBookmark` is ALSO aliased in the `bookmarks` array while its `annotationId` is mutated on the network-completion thread (`TPPReaderBookmarksBusinessLogic.swift:~114 / ~165`). Pre-existing latent data race; the Chunk-2 boxing did NOT introduce or worsen it, but a real Swift-6 concurrency pass must close it. Needs isolating `annotationId` mutation to a single actor/queue or making `TPPReadiumBookmark` properly Sendable.

### P5 — BookRegistrySync testability seam  [test-infra · small]
- From the #1158 Chunk-1 qa review: `BookRegistrySync.opdsFeedServiceProvider` is typed `() -> OPDSFeedService` (concrete actor) with no DI seam, so the feed-fetch-failure / `.synced` / awaitReady-catch carrier branches are untestable. Widen it to `() -> OPDSFeedFetching` + add the `fetchFeed(from:resetCache:)` overload to the protocol, then inject the existing `feedFetcher` mock to cover those branches. Also: **confirm the keychain-gated carrier test** (`test_sync_whenNotSyncing_withCredentialsAndNoLoansUrl_resolvesToLoaded`) actually RUNS (not skips) in the CI lane — it's currently the sole exerciser of the SyncCallbacks path.

### P6 — Phase B: `complete` strict concurrency  [BIG · the main remaining push]
- `ruby scripts/set_strict_concurrency.rb complete` flips `SWIFT_STRICT_CONCURRENCY` targeted→complete on Palace + Palace-noDRM. Re-measure (CI build log) — `complete` surfaces MANY MORE than `targeted` (region-based isolation, `sending`, global-actor gaps). Then sweep to 0, likely across many modules → candidate for `/swarm` per module. This is the largest chunk; expect it to dwarf Phase A. Fan out by module once measured.

### P7 — Phase C: `SWIFT_VERSION 5.0 → 6.0`  [finish line · after P6=0]
- Flip `SWIFT_VERSION` on Palace + Palace-noDRM (pbxproj). If Phase B cleared `complete` to 0, C is largely a flip (warnings become errors). Verify a clean DRM build + full CI.

### P8 — Phase D: PalaceAudiobookToolkit submodule  [scope decision + ~5 warnings]
- The submodule emits ~5 `targeted` warnings. Decide: fix in the submodule repo (separate PR there + bump), or defer. Not on the app-target critical path.

### P9 — Housekeeping  [trivial]
- Remove the 3 done worktrees (`swarm_afec67f0-orchestrator`, `flakefix_7834a4`, `a6_393399`) + their local branches — BLOCKED by the pre-destructive hook reading the MAIN checkout's stale untracked `.forgeos/swarms/swarm_afec67f0/manifest.yaml` (status `triaged`). Fix: set that file's `status: complete` (it IS complete — #1158 merged), OR `HARNESS_SWARM_BYPASS=1 git worktree remove …`. Don't touch the OTHER session's staged files.
- **Rotate the ForgeOS API key** `fos_…` in `~/.claude.json` — it was surfaced in a transcript this session.
- CLAUDE.local.md doc-drift fix is local-only (gitignored) and already applied.

---

## 4. Fan-out plan (what can run concurrently)

**Independent, no shared files — safe to run in parallel NOW (each in its own worktree):**
- **P1** (AdobeDRM) — Reader2/AdobeDRM, DRM build.
- **P2** (CarPlay) — CarPlay + CarPlaySceneDelegate.
- **P3** (FLAKE-003) — PalaceTests only.
- **P4** (Reader2 bookmark race) — Reader2/BusinessLogic.
- **P5** (BookRegistrySync seam) — Book/Models + OPDS2 + tests.

Recommend: **P3 first (or concurrent)** — it keeps CI green so the others' PRs don't get blocked by the persistence flake. P1+P2 together **complete Phase A app-target = 0** (a clean milestone). P4/P5 are quality follow-ups that can trail.

**Sequential (gated):**
- **P6 (Phase B)** should start AFTER P1+P2 (Phase A truly 0) so the `complete` measurement isn't polluted by leftover `targeted` warnings. P6 is itself a fan-out (per-module swarm).
- **P7 (Phase C)** strictly after P6 = 0.
- **P8 (Phase D)** any time (submodule, independent).

**Per-item dispatch checklist:** isolated worktree (§2b) → fix using §2h patterns → local DRM build+test verify (§2a) → local SoD review agents for critical-path (P1, P2) → commit in worktree, push (§2e), open PR, merge-on-green (§2f) → file de-flake items for any new flake per §2g.
