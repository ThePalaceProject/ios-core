# App-target Swift 6 modernization — plan, tracker & handoff

<!-- audit-verified -->
**This is the authoritative handoff doc.** Any agent/session picking up the Swift 6
effort should read this top to bottom first. It carries the finish-line checklist,
the proven execution playbook, the measured warning inventory, and the gotchas that
already bit us. PR/commit states below were verified via `gh pr view` /
`git log origin/develop` on 2026-06-30.

---

## 1. Status snapshot

**DONE — merged to `develop`:**
- All 7 first-party SPM packages → Swift 6: PalaceLogging (#1129), PalaceKeychain
  (#1130), PalaceReadingPosition (#1131), PalaceTriageBot (#1132), PalaceNetwork
  (#1133), PalaceCatalog (#1138), PalaceAuth (#1141).
- Support fixes: #1134 (triagebot iOS build unblock), #1137 (chaos-replay workflow
  un-break), #1143 (pre-push hook: skip on missing-framework build failure).
- App-target prep: #1142 (Sendable ripple cleanup — TPPNetworkExecutor /
  CoordinatorUserAccountAdapter / RemoteFeatureFlags → @unchecked Sendable),
  **#1144 (Wave-1 kickoff: `SWIFT_STRICT_CONCURRENCY = targeted` on Palace +
  Palace-noDRM)**.

**IN FLIGHT:**
- **#1145** (draft) — the non-critical app-target sweep (4 subsystem agents +
  MockImageCache ripple). Branch `feat/swift6-apptarget-sweep`. Gated on CI:
  must build green AND drop the 154-warning baseline.

**NEXT:** Phase A.2/A.3 below.

---

## 2. Finish-line checklist (what "fully done" means)

### Phase A — app-target `targeted` → 0 warnings  (baseline: 154)
- [ ] A.1 Land **#1145** (non-critical sweep): Utilities, OPDS2/Book, UI/ViewModels,
      Reader2/PDF. *(in flight)*
- [ ] A.2 **Cross-file cascade slices** (deps the sweep agents flagged, not forced
      blind): `TPPBookRegistry` `@Sendable` closures; `TPPReadiumBookmark` &
      `PDFKitThumbnailProvider` → Sendable; `TPPAgeCheck` `@objc` protocols
      (`AccountDetails`, `TPPUserAccountProvider`).
- [ ] A.3 **🔴 CRITICAL-PATH slices — the dominant remaining work (~108 of 154)**.
      Each is its own PR with **architect + qa SoD + air-tight tests + mutation
      testing** (CLAUDE.md rigor bar — these are money/access paths):
      - `Palace/MyBooks/` — BorrowOperation, BookReturnService, MyBooksDownloadCenter,
        DownloadAuthRetryHandler, TokenRefreshInterceptor, RightsManagementDispatcher,
        LCPFulfillmentHandler
      - `Palace/SignInLogic/` — TPPReauthenticator, TPPSignInBusinessLogic, SignIn*
      - `Palace/Audiobooks/` — PlaybackReadinessGate, LCPAudiobooks
      - DRM — Reader2 AdobeDRM*, TPPLCPClient, LCPPDFDiskExtract
- [ ] A.4 Verify `targeted` build → **0** concurrency warnings (CI build log).

### Phase B — `complete` → 0 warnings
- [ ] B.1 `ruby scripts/set_strict_concurrency.rb complete` (flips the level).
- [ ] B.2 Re-measure (CI build log) — `complete` surfaces MORE than `targeted`.
- [ ] B.3 Fix the new wave (same subsystem-sliced + SoD approach).
- [ ] B.4 Verify `complete` build → 0.

### Phase C — language-mode flip (finish line)
- [ ] C.1 `SWIFT_VERSION = 5.0 → 6.0` on Palace + Palace-noDRM (pbxproj).
- [ ] C.2 Fix residual errors (near-0 if A+B honest — warnings become errors).
- [ ] C.3 Verify: full Swift 6 build 0 errors, green CI + full suite + mutation on
      critical paths.

### Phase D — submodules (SCOPE DECISION REQUIRED)
- [ ] `ios-audiobooktoolkit` + `ios-audiobook-overdrive` have their own Swift (the
      `AudiobookManager.saveBookmark` witness issue lives there). Only if "fully
      Swift 6" includes them — each is its own repo-level modernization.

### Phase E — loose ends (small, tracked)
- [ ] CarPlay `deinit` main-actor `remove(self)` (the `assumeIsolated` we reverted
      in the sweep — needs a safe fix in the CarPlay slice).
- [ ] `TokenRequest.execute(completion:)` test (qa nit, needs global URLProtocol stub).
- [ ] stale `cacheQueue` comments in `CatalogRepositoryTests`.
- [ ] 6 residual hermeticity escape sites (from #1133's `87→6`) — see
      `.forgeos/intent/palacenetwork-swift6-modernization.md`.
- [ ] #3 chaos-replay **activation** (admin-gated; NOT Swift-6): set repo var
      `ENABLE_CHAOS_QA_RUNNER=true`, provision self-hosted `[macos, palace-ios]`
      runner, populate `.simdrive/replays/chaos/` (simdrive).

---

## 3. Execution playbook (HOW — proven this session)

**The shape:** for each non-critical subsystem, swarm in parallel; for critical
paths, careful SoD'd single slices. Do NOT blind-swarm money/access code.

**Per-slice recipe:**
1. **Measure** — the authoritative warning inventory is the **CI build log** of a
   PR that has `SWIFT_STRICT_CONCURRENCY=targeted` set (e.g. #1144/#1145). Pull it:
   `gh run view <unit-tests-run-id> --log | grep -E ':[0-9]+:[0-9]+: warning:' | grep -iE 'Sendable|concurrency|actor-isolated|main actor|sending|nonisolated|crosses into'`.
   DO NOT measure with a *global* `SWIFT_STRICT_CONCURRENCY=targeted` xcodebuild
   override — it overrides the packages' v6 mode and re-flags already-Sendable
   package types (TPPOPDSFeed etc.), OVER-counting. Per-target setting only.
2. **Fix by ISOLATION, never `nonisolated(unsafe)`** (the #1129 playbook):
   - value type not Sendable → add `: Sendable` (additive).
   - generic `T` crossing Task/continuation → `<T: Sendable>`.
   - class captured/crossed → `final class … : @unchecked Sendable` with a
     **documented invariant** (lock-guarded or immutable-after-init). NO bare @unchecked.
   - `@MainActor`-isolated member from nonisolated → `await MainActor.run { }` hop
     or add `@MainActor`. Avoid `MainActor.assumeIsolated` in `deinit` (fatalErrors
     if off-main).
   - delegate conformance "crosses into main actor-isolated code" → `@preconcurrency`
     on the conformance (the EmailTicketGateway #1134 pattern).
   - module types not Sendable-audited → `@preconcurrency import <Module>`.
3. **Making a PROTOCOL Sendable ripples to ALL conformers** (incl. test mocks) —
   each must become Sendable or the build breaks. (ImageCacheType: Sendable forced
   ImageCache + MockImageCache → @unchecked Sendable.) Grep conformers before landing.
4. **Verify = CI** (see §4: no local app build). Build must stay green (warnings ≠
   errors while SWIFT_VERSION=5.0) AND the count must drop.

**Swarm-then-reconcile (for non-critical subsystems):** launch parallel agents
(Agent tool, one per subsystem, isolation:"worktree"), each given its file list +
the warning inventory + the playbook + "you CANNOT build locally; fix per analysis;
report cross-file deps; flag anything critical-path instead of editing." Then the
ORCHESTRATOR integrates with judgment (see gotchas).

---

## 4. Build environment — READ THIS (biggest time-sink)

**You CANNOT fully build the `Palace` app target locally in a fresh worktree.** It
needs **private Adobe DRM headers** (`dp_all.h` from `adobe-content-filter`) that
are not in any submodule. `Palace-noDRM` also failed. **CI is the only complete
build/measurement environment.** Don't sink hours into a local app build.

- A fresh worktree also lacks Carthage binaries (`R2LCPClient`/`AudioEngine`
  xcframeworks) + needs ALL submodules initialized (`git submodule update --init`)
  + the `OverdriveProcessor.framework` from the `ios-audiobook-overdrive` subproject.
  Even with all that, the private DRM headers block the `Palace` scheme.
- **The pre-push hook now self-skips** when the build can't link due to missing
  frameworks (#1143) — so a **plain `git push`** from a fresh worktree works (no
  `SKIP_PRE_PUSH_TESTS` bypass, no manual push). A genuine `error:` still blocks.
- `scripts/set_strict_concurrency.rb <targeted|complete|"">` flips the level on the
  app targets (reversible; empty arg removes it).

---

## 5. Integration gotchas (these already bit us — don't repeat)

- **Agent `isolation:"worktree"` bases are STALE.** Every sweep agent's worktree
  checked out an old commit (3.1.0-era `2ea504885` / session-start `d2252f9e7`),
  NOT current develop, because the shared main checkout is branch-volatile. Agents
  `git reset --hard`'d to the warnings' base to work. So their commits are against
  an OLD base.
- **Cherry-pick is clean ONLY for files unchanged base→develop.** Check first:
  `git diff <agent-base>..origin/develop -- <file>`. (Most app files were unchanged
  and cherry-picked clean.)
- **NEVER resolve a cherry-pick conflict with `git checkout --theirs` on a stale
  base** — it takes the agent's WHOLESALE old file and silently REVERTS develop
  content. This happened to `CatalogViewModel` (would have reverted develop's
  `prefetchTasks` fix). Instead: restore develop's file (`git show origin/develop:<f>`)
  and re-apply ONLY the agent's intended hunks. Line-count sanity-check after.
- **Review agent output before integrating.** One agent added `MainActor.assumeIsolated`
  in a `deinit` (crash risk if deinit runs off-main) — reverted at integration.
  Auth-adjacent changes (AccountDetailViewModel @preconcurrency) were kept but
  flagged for the PR reviewers.
- **The shared main checkout is volatile** (fleet switches its branch mid-session).
  Re-check `git branch --show-current` before any commit; land fixes from dedicated
  worktrees, not the main checkout.

---

## 6. Measured inventory (Wave 1 `targeted`, CI authoritative: 154)

Per-subsystem (raw counts; critical-path 🔴):
- 🔴 MyBooks 110 (Borrow/Return/Download/DRM) · Reader2 52 · OPDS2 44 (mostly stale
  TPPOPDSFeed artifacts → resolve via package) · Utilities 40 · Book 36 · 🔴
  SignInLogic 28 · 🔴 Audiobooks 22 · Settings 16 · CatalogUI 14 · Accounts 14 ·
  PDF 10 · CarPlay 8 · Network 6 · AppInfrastructure 6 · Logging/Holds/Support ≤4.

Dominant categories: `#SendableClosureCaptures` (~250 raw), Sendable non-conformance
(58), `@MainActor` conformance-crossing (28), `@MainActor` static-from-nonisolated (~24).

**Out of scope (not Swift-6 concurrency):** ~68 pre-existing style warnings in
PalaceCatalog (redundant `public`, always-true casts).

---

## 7. Key artifacts
- Plan/tracker/handoff: **this file**.
- Setter: `scripts/set_strict_concurrency.rb`.
- Intents: `.forgeos/intent/palace{network,catalog,auth}-swift6-modernization.md`,
  `.forgeos/intent/accountdetail-leak-cycle-and-hermetic-network.md` (hermeticity).
- The #1129 PR body is the canonical isolation playbook + original sizing.
- Sweep branch (in flight): `feat/swift6-apptarget-sweep` (#1145).
