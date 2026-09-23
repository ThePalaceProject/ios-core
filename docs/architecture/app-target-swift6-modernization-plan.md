# App-target Swift 6 modernization — plan, tracker & handoff

<!-- audit-verified -->
**This is the authoritative handoff doc.** Any agent/session picking up the Swift 6
effort should read this top to bottom first. It carries the finish-line checklist,
the proven execution playbook, the measured warning inventory, and the gotchas that
already bit us. PR/commit states below were verified via `gh pr view` /
`git log origin/develop` on 2026-07-01. <!-- audit-verified -->
Merge states re-confirmed 2026-07-01: #1145 (A.1 sweep) and #1148–#1152 (A.3
slices A–E) + #1154 (hotfix) all MERGED to develop.

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

- **Phase A.1 — non-critical sweep: #1145 MERGED** (154 → 112). The A.2 cascade
  items (`TPPAgeCheck` `@objc` protocols, `BookRegistrySync`, `TPPPDFDocumentMetadata`)
  were folded INTO this sweep, so A.2 has no separate PR.
- **Phase A.3 — 🔴 CRITICAL-PATH slices A–E: ALL MERGED** —
  #1148 (A: auth-error network cluster), #1149 (B: borrow/return),
  #1150 (C: download/DRM), #1151 (D: SignInLogic), #1152 (E: Audiobooks).
  Plus #1154 (hotfix: MainActor hop in `BookCellModel.didSelectReturn`).

**A.4 MEASURED — 2026-07-01 (Unit Tests run `28520895484`, develop tip `210f5713a`,
`targeted` per-target). NOT zero: 117 concurrency warnings.** <!-- audit-verified -->
Breakdown by target:
- **Palace app target: 42** — the real remaining Phase-A work (Phase A NOT done).
- **PalaceTests: 37** — test-target mocks (`@unchecked Sendable` restatements,
  `crosses into main actor` mock conformances). Scope decision required (below).
- **PalaceAudiobookToolkit: 5** — submodule → Phase D, out of app-target scope.

**Root cause of the 42:** the A.3 "download/DRM" slice (#1150) addressed only the
`Palace/MyBooks/` download-center files. The A.3 checklist ALSO named the Reader2/PDF
DRM-decryption files (`TPPLCPClient`, `AdobeDRMContentProtection`, `AdobeCertificate`,
`LCPPDFDiskExtract`) — verified **0 commits** touched them in `fb01695da..210f5713a`.
Plus partial fixes left residue in already-touched files (`BookRegistrySync` ×9,
`TPPAgeCheck` ×4) and never-touched app files (`FirebaseManager`, `TPPOPDSFeed+Networking`,
`TPPBookRegistry`, `CarPlay*`, `AppContainer`, `DLNavigator`, …).

**NEXT:** Phase A.5 (finish the 42 app-target warnings, below), then re-run A.4 to
confirm 0, then Phase B (`complete` → 0).

---

## 2. Finish-line checklist (what "fully done" means)

### Phase A — app-target `targeted` → 0 warnings  (baseline: 154)
- [x] A.1 **#1145 MERGED** (non-critical sweep): Utilities, OPDS2/Book, UI/ViewModels,
      Reader2/PDF. 154 → 112.
- [x] A.2 **Cross-file cascade slices — folded into #1145**, no separate PR:
      `TPPBookRegistry`/`BookRegistrySync` `@Sendable` closures; `TPPReadiumBookmark` &
      `PDFKitThumbnailProvider`/`TPPPDFDocumentMetadata` → Sendable; `TPPAgeCheck`
      `@objc` protocols (`AccountDetails`, `TPPUserAccountProvider`).
- [~] A.3 **🔴 CRITICAL-PATH slices — MERGED but scope INCOMPLETE**. Landed:
      - `Palace/MyBooks/` borrow/return **#1149 (B)**, download/DRM **#1150 (C)**
        (BorrowOperation, BookReturnService, MyBooksDownloadCenter,
        DownloadAuthRetryHandler, TokenRefreshInterceptor, RightsManagementDispatcher,
        LCPFulfillmentHandler)
      - auth-error network cluster **#1148 (A)** (TPPNetworkExecutor decision point)
      - `Palace/SignInLogic/` **#1151 (D)** (TPPReauthenticator, TPPSignInBusinessLogic)
      - `Palace/Audiobooks/` **#1152 (E)** (PlaybackReadinessGate, LCPAudiobooks)
      - hotfix **#1154** (MainActor hop in BookCellModel.didSelectReturn)
      - ❌ **DROPPED — the DRM-decryption files this bullet named were never touched**:
        `TPPLCPClient`, `AdobeDRMContentProtection`, `AdobeCertificate`,
        `LCPPDFDiskExtract` (0 commits). Moved to A.5.
- [x] A.4 **Measured 2026-07-01 → 117 (NOT 0).** 42 Palace app-target + 37 PalaceTests
      + 5 submodule. Phase A NOT done — see A.5. (Unit Tests run `28520895484`.)
- [ ] A.5 **Finish the 42 app-target `targeted` warnings** (the real Phase-A remainder):
      - 🔴 **DRM (critical-path, /rigorous-fix + SoD): 11** — `TPPLCPClient` ×4,
        `AdobeDRMContentProtection` ×3, `AdobeCertificate` ×2, `LCPPDFDiskExtract` ×2.
      - **Registry/age cascade residue: 13** — `BookRegistrySync` ×9, `TPPAgeCheck` ×4
        (partially fixed in #1145; finish the `@Sendable` capture closures).
      - **Remaining ~18** — `TPPOPDSFeed+Networking` ×2, `TPPReaderBookmarksBusinessLogic`
        ×2, `AudiobookBookmarkBusinessLogic` ×2, `CarPlay*` ×2, `TPPLCPClient`-adjacent,
        `FirebaseManager`, `DLNavigator`, `AppContainer`, `TPPBookRegistry`,
        `TPPBookCoverRegistry`, `CatalogViewModel`, `TPPEPUBViewController`,
        `TriageBotFactory`, `Account+State`, `PDFThumbnailStrip`. Non-critical → sweep.
      - Then **re-run A.4** (dispatch Unit Tests on develop) and confirm **0**.
- [ ] A.6 **Scope decision — PalaceTests target (37 warnings).** Does Phase A require
      the TEST target to be `targeted`-clean, or only the app targets? #1144 set the
      flag on Palace + Palace-noDRM; confirm whether PalaceTests inherits it and decide
      before Phase B (mostly `@unchecked Sendable` restatements + mock main-actor
      conformances — mechanical but ~37 sites).

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
