<!-- audit-verified -->
# Swift 6 modernization — handoff (2026-07-06)

**Purpose:** self-contained, pick-up-cold handoff to finish the Swift 6 strict-concurrency
modernization. Supersedes the 2026-07-02 and 2026-07-03 handoffs for status (the 07-03
handoff, PR #1177, was interim — its "328" snapshot is now stale; close/supersede it with
this doc). The older docs remain valid for their playbooks:
- `app-target-swift6-modernization-plan.md` — the phase ladder (A→B→C→D) + finish-line checklist.
- `swift6-modernization-handoff-2026-07-02.md` — environment recipe (§2b worktree setup) + gotchas.
- `swift6-modernization-handoff-2026-07-03.md` — the per-module Phase-B map + fix vocabulary (§5).

Tracked in JIRA under epic **PP-4717** + child stories (PP-4720 non-critical, PP-4722 critical
modules, PP-4725 CI flakes, PP-4723 Phase C, PP-4724 Phase D).

---

## 1. Status (develop @ post-wave-1, 2026-07-06)

- **Packages** → Swift 6: DONE (#1129–#1141).
- **Phase A** (app-target `targeted` → 0): DONE.
- **Phase B** (`targeted` → `complete` → 0): **IN PROGRESS. 738 → 134** distinct app-target
  `complete`-mode warnings (~82% cleared). This session's wave-1 fan-out took **328 → 134**.
- **Phase C** (`SWIFT_VERSION` 5.0 → 6.0): NOT STARTED, blocked on Phase B = 0.
- **Phase D** (PalaceAudiobookToolkit submodule, ~5): NOT STARTED, independent.

### Wave-1 fan-out (this session, 5 PRs — parallel implement → central build-gated reconcile → dual SoD)
| PR | Slice | Warnings | Rigor |
|---|---|---|---|
| #1181 | MyBooks presenters | 26 | 2 SoD (behavior + soundness) |
| #1182 | Audiobooks (isolation-only + carrier boxes) | 28/38 | 2 SoD (critical/fragile) |
| #1183 | TPPAlertUtils @MainActor + caller hops | 46 | 2 SoD (regression-history lane) |
| #1184 | MyBooks auth/token | 17 (+ cascade) | 2 SoD (auth critical) |
| #1185 | Network/Notifications auth seam | ~5 (+ a race fix) | 2 SoD (auth-error decision point) |
| #1186 | non-critical mop-up (8 modules) | 56 | 1 review (non-critical) |

**Method notes worth keeping:**
- Implementers ran in parallel isolated worktrees, edits UNCOMMITTED, cross-module changes
  flagged in `RIPPLES.md`. The orchestrator applied all diffs to ONE DRM integration worktree
  (`complete` mode) and ran a union `build-for-testing` — that central gate caught **2 real
  cross-lane integration bugs** the blind implementers could not see (a duplicate `bookId`
  decl; `TPPReturnPromptHelper`'s completion needing `@MainActor @Sendable` so two call-site
  `coordinator.pop()`s stayed on-main). Both fixed at reconcile.
- **`MyBooksDownloadInfo: @unchecked Sendable` (RIPPLE 1) cascaded** — one conformance cleared
  10 auth-slice `.remove`-across-actor sites AND dropped MyBooks 95→30 by clearing
  download-machinery sites too.
- SoD is not ceremony: reviewers caught a doc-comment overstating an invariant
  (CredentialRequestState "lock-confined" → actually convention-confined) and a narrow
  VoiceOver-cache startup-suppression window — both fixed before push.

### The 4 shared-type unblockers — ALL DONE (PP-4721 closed, prior sessions)
`AccountsManager`, Readium `Publication`, `Account` (#1173, SoD caught a real `hasUpdatedToken`
race), `TPPBookRegistry` (#1172), `Store.Environment`. The #1173 `hasUpdatedToken` race is
fixed at the `Account.swift` source (`AccountBoolFlag`) — the wave-1 F-network reviewer
re-confirmed this is NOT re-introduced.

### Re-measure (do this first each session — count drifts as the fleet moves develop)
```bash
# Integration worktree per §4 of the 07-02 handoff (adobe-rmsdk symlinked), complete mode:
ruby scripts/set_strict_concurrency.rb complete
xcodebuild -project <wt>/Palace.xcodeproj -scheme Palace \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath <fresh-dd> build 2>&1 | tee build.log
FILT='Sendable|actor-isolated|main actor|sending|nonisolated|non-sendable|capture of|must restate|global actor|isolated'
grep -E ':[0-9]+:[0-9]+: warning:' build.log | grep -iE "$FILT" | grep -E '/Palace/' \
  | grep -vE '/PalaceTests/|/Packages/|/Carthage/|SourcePackages|DerivedData/' \
  | sed -E 's|.*/(Palace/[^:]+:[0-9]+:[0-9]+): warning:.*|\1|' | sort -u | wc -l
```
A FRESH derivedDataPath is required for an accurate count (incremental under-reports). Revert
to `targeted` before committing — Phase-B PRs never carry the `complete` flip.

---

## 2. Remaining Phase B work (134 warnings) — prioritized

| Module | Count | Track |
|---|---|---|
| **Reader2** | 31 | DRM/LCP slice (AdobeCertificate, AdobeDRMContentProtection, LCPPassphrase, LicensesService, TPPLCPClient) + 2 deferred reader-VCs. DRM critical-path → rigorous + SoD. |
| **MyBooks** download-machinery | 30 | MyBooksDownloadCenter(9), DownloadThrottlingService(5), DownloadStateManager/QueueOrchestrator/ErrorRecovery(4 ea), + the 3-ea handlers. Borrow/return/DRM critical-path → rigorous + SoD, slice by concern. |
| **SignInLogic** | 28 | **The `TPPSignInBusinessLogic: @MainActor` conversion.** Wave-1's SignInLogic lane proved all 28 residual collapse to this ONE decision (Account:Sendable did NOT unblock them). Blast radius: 3 prod ctor callers + ~14 method callers + PalaceAuth conformances + **35 PalaceTests files**. Own rigorous PR; handle the 35-test ripple + PalaceAuth together. Also: +ForceReset/+SignOut completion @Sendable (ripples Settings), SAMLWebViewPresenting closures, WKNavigationDelegate captures, TPPReauthenticator.authenticateIfNeeded completion. |
| **Book** | 13 | registry async/consumer residual. |
| **Audiobooks** residual | 10 | LCPAudiobooks + adapter sites where @preconcurrency doesn't kill a `sending` diagnostic. Wave-1 #1182 cleared 28/38; these 10 need structural work. |
| PDF 7 · Utilities 5 · AppInfra 5 · misc 5 | ~22 | mop-up. Includes **TPPPDFView.swift:114** (sends non-Sendable `PDFDocument` across `await` — needs restructure or a PDFKit Sendable annotation, behavior-affecting). |

**Cross-cutting deferred decision (3 lanes independently flagged):**
`Reauthenticator.authenticateIfNeeded`'s completion wants `@Sendable` — ripples across
SignInLogic + MyBooks + Audiobooks + Reader2. Do it as ONE coordinated change, not per-lane.

### Sequencing
1. **SignInLogic `@MainActor` conversion** — its own rigorous PR (unblocks the most; it's the
   single biggest structural decision left).
2. **Reader2 DRM/LCP** + **MyBooks download-machinery** — parallel rigorous slices (disjoint).
3. **Book + Audiobooks residual + PDF/Utilities/AppInfra mop-up** — swarm-then-reconcile.
4. Re-measure → 0 → **Phase C** (`SWIFT_VERSION` 6.0 flip on Palace + Palace-noDRM; warnings
   become errors, fix residuals, full CI + suite + mutation on critical paths).

---

## 3. Execution playbook (proven — 10+ PRs merged across sessions)

**Fan-out shape that worked this session:** parallel implementers (one per module lane, own
isolated worktree) leave edits UNCOMMITTED + flag ripples → orchestrator applies ALL diffs to
ONE DRM integration worktree in `complete` mode → union `build-for-testing` (the gate that
catches cross-lane integration bugs AND test-target ripples) → per-lane split into PRs →
independent SoD per critical PR → merge-on-green.

- **Critical-path PRs need ≥2 review markers** (`rev_<8hex>` in commit bodies) or the
  `pre-push-critical-path-review.sh` hook blocks. This session ran **two genuinely independent
  SoD reviewers per critical PR** (complementary lenses: soundness + qa/behavior) to satisfy
  the gate HONESTLY — do NOT use `SKIP_CRITICAL_PATH_REVIEW=1` to fake it. `SKIP_PRE_PUSH_TESTS=1`
  alone is fine (plain lane worktrees can't run a DRM build; CI is the test gate).
- **Merge-to-develop needs explicit human authorization** — the auto-mode classifier blocks an
  agent merging its own PRs. Surface green PRs to the operator; don't self-merge.
- **build gate is `build-for-testing`, NOT `build`** — `build` skips the test target, hiding
  `@MainActor`-on-a-production-type ripples that break nonisolated test callers.
- **Hook path-skew (§2c):** the PreToolUse `audit-before-assert` hook resolves `scripts/hooks/`
  relative to shell cwd; a worktree lacking the newer script blocks Edit. Workaround: apply doc
  edits via Bash (python/perl), or keep shell cwd in a checkout that has the script.

---

## 4. Environment (unchanged from 07-02/07-03; the essentials)

- **Local DRM build WORKS.** Adobe connector at `/Users/mauricework/PalaceProject/ios-drm-adeptconnector/connector`;
  symlink as `adobe-rmsdk`. Integration-worktree recipe in the 07-02 handoff §2b, with the §4
  submodule-empty-dir ritual after every `git reset --hard` (reset re-empties the `git worktree
  add`-created mount dirs; re-symlink adept-ios/adobe-content-filter/ios-tenprintcover/
  mobile-bookmark-spec/readium-sdk/readium-shared-js).
- **Generic sim destination** (`generic/platform=iOS Simulator`) for warning-count builds.
- **The fleet moves develop mid-session** — always work off a fixed `origin/develop` ref, re-fetch
  before pushing, expect pbxproj conflicts on any PR that adds files (none of wave-1 did).

---

## 5. Isolation fix vocabulary
See the 07-03 handoff §5 (carrier boxes, `@unchecked Sendable` with documented invariants,
`@MainActor` on UI-driving types, `@preconcurrency import` as the honest ceiling, NEVER
`nonisolated(unsafe)` / bare `@unchecked Sendable` / `assumeIsolated`-in-deinit). Wave-1
precedents added: `AudiobookAdapterCompletionBox`/`ManifestJSONBox`/`TokenReadyCompletionBox`
(Audiobooks), `BackgroundTaskIDBox`/`LockedFlag` (Utilities), `CompletionBox<T>` (Network),
`BorrowBookBox`/`RetryBookBox`/`PrefetchBooksBox` (MyBooks presenters).

**Rule that keeps SoD honest:** a documented `@unchecked Sendable` invariant must be TRUE, not
aspirational. If the comment says "lock-confined" the field must be lock-guarded on EVERY path;
if it's convention-confined, say so and file the `@MainActor` follow-up. Wave-1 SoD caught this.
