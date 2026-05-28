# Swarm `swarm_c8fcab76` — 3.2.0 close-out wave 1

Four orthogonal, file-disjoint modules running in parallel to close 3.2.0 candidates that do NOT collide with the open PR #1018 auth-architecture swarm.

## Goal

Land four close-out items in parallel:

1. **(A)** Fix PP-4436 / F-011 — audiobook first-open hang regression from PR #990 toolkit overhaul. Wiring/lifecycle test reproduces the hang via the production `AudiobookSessionManager.openAudiobook` seam; fix gates the first `play(at:)` on a Palace-side readiness `await` of the toolkit's coordinator-ready signal.
2. **(B)** Close remaining Phase 7 audit follow-ups — META-regression test pinning `BookButtonMapper.map(...)`'s exhaustive switch (so a future PR cannot silently re-introduce the F-011-shape `default:` fall-through), plus mutation kill-rate gap close-out in `DownloadStartDispatcher` / `DownloadAuthRetryHandler` / `BookButtonMapper` test files.
3. **(C)** Three per-area verification checklists — `docs/architecture/areas/{mybooks,audiobook,accounts}/verification-checklist.md` — derived from the auth checklist template that landed in PR #1019. Docs-only.
4. **(D)** Critical-path test fluff cleanup — rewrite 30–50 shallow violations (per `scripts/lint-test-quality.py`) in `PalaceTests/(Audiobooks|SignInLogic|MyBooks/Download|Accounts|Network)`. Tests-only; production OFF-LIMITS.

## Modules

| Module | Rigor | Domain | Owns (write) | Risks |
|---|---|---|---|---|
| **A** — Audiobook First-Open Hang | critical-path | audiobook | `Palace/Audiobooks/AudiobookSessionManager.swift`, `Palace/Audiobooks/AudiobookLoader.swift`, `Palace/Audiobooks/AudiobookSessionManaging.swift`, (NEW) `Palace/Audiobooks/PlaybackReadinessGate.swift` IF extracted, (NEW) `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift`, MAY extend `PalaceTests/Audiobooks/Mocks/` | Audiobook toolkit submodule = highest-risk surface (25+ revs, frequent reverts). Cross-vendor smoke (LCP/BearerToken/OpenAccess/LocalFile) must stay green post-fix. |
| **B** — Phase 7 Follow-ups | critical-path | mybooks | `PalaceTests/BookStateManagement/BookButtonMapperTests.swift`, `PalaceTests/MyBooks/DownloadStartDispatcherTests.swift`, `PalaceTests/MyBooks/DownloadAuthRetryHandlerTests.swift`. Comment-only on `Palace/Book/UI/BookDetail/BookButtonMapper.swift`. | None of substance — test/comment work only. Production behavior changes are escalations. |
| **C** — Area Checklists | standard | docs | (NEW) `docs/architecture/areas/{mybooks,audiobook,accounts}/verification-checklist.md` | Docs-only. Template fidelity risk (auth checklist may not exist at branch base — fallback documented). `audit-before-assert.py` may not exist at branch base — fallback documented. |
| **D** — Test Fluff | standard | general | `PalaceTests/(Audiobooks-non-A-files|SignInLogic|Accounts|Network|MyBooks-non-Download)/*Tests.swift` rewrites | Risk of rewriting intentionally-shallow ObjC bridge smoke tests. Implementer must flag-not-fix; `// INTENTIONALLY-SHALLOW: <reason>` annotation. |

## Parallelism plan

All four modules are file-disjoint via explicit overlap resolution (see below). They can run in parallel from the same `swarm/swarm_c8fcab76-scaffold` base. Per-module PRs against `develop` (4 PRs).

**Sequencing constraint (soft):** Module A's `AudiobookFirstOpenHangTests.swift` is a NEW file — it cannot collide with Module D. Module D MAY rewrite shallow tests in pre-existing audiobook test files (list in D's contract). If Module A and Module D both end up needing to edit the same pre-existing file (e.g. `AudiobookOpenStateRaceTests.swift`), Module A merges first and Module D rebases onto Module A's branch and picks a non-conflicting file from the list. Module A's PR has reviewer priority (critical-path fix); Module D defers.

Integrator merge order:
1. **Module A** (critical-path fix — reviewer attention is the gating resource)
2. **Module B** (critical-path tests — no production behavior change, low review cost)
3. **Module C** (docs-only — independent of A/B/D)
4. **Module D** (test rewrites — last so it can rebase off A's audiobook-test changes if any)

## Overlap-resolution decisions (load-bearing)

### B vs D — `PalaceTests/MyBooks/Download*Tests.swift`

**Module B has EXCLUSIVE WRITE on `PalaceTests/MyBooks/Download*Tests.swift`.** Module D EXCLUDES these files entirely. If Module D's lint-test-quality pass surfaces shallow violations in those files, they are deferred to a future test-deepening swarm — NOT in scope for this swarm's 30–50 cap. Rationale: B is closing documented mutation gaps in those exact files (audit follow-up); a parallel rewrite by D would create merge conflicts AND risk D un-doing B's mutation-killing assertions.

### B vs D — `PalaceTests/Book/BookButtonMapperTests.swift` + `PalaceTests/BookStateManagement/BookButtonMapperTests.swift`

**Module B has EXCLUSIVE WRITE.** Module D EXCLUDES. Rationale: same as above — B is adding the META-regression test that pins exhaustive-switch; D rewriting in parallel risks conflicts.

### A vs D — `PalaceTests/Audiobooks/`

**Module A has EXCLUSIVE WRITE on:**
- (NEW) `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift`
- Additions to `PalaceTests/Audiobooks/Mocks/`

**Module D MAY rewrite shallow tests in pre-existing audiobook test files** (the enumerated list in D's contract: `AudiobookSessionStateTests.swift`, `AudiobookTimeTrackerEdgeTests.swift`, `AudiobookEventsTests.swift`, `TPPReturnPromptHelperTests.swift`, `AudioEngineWrapperTests.swift`, `NowPlayingCoordinatorTests.swift`, `NowPlayingCoordinatorBackgroundTests.swift`, `PlaybackBootstrapperTests.swift`, `AudiobookLoaderFinalizeBuildTests.swift`, `AudiobookLoadFailureSAMLReauthTests.swift`, `AudiobookSessionManagerShutdownTests.swift`, `SAMLPlusBiblioBoardExpirationTests.swift`).

**Module D MUST NOT touch `PalaceTests/Audiobooks/CrossVendorSmokeTests.swift`** — that's contract (the verify-pr.sh smoke gate references it by name).

If Module A's fix needs to touch a pre-existing audiobook test file that Module D is also rewriting (most likely `AudiobookOpenStateRaceTests.swift`), A merges first; D rebases.

### C vs all — `docs/architecture/areas/`

Module C has EXCLUSIVE WRITE on `docs/architecture/areas/{mybooks,audiobook,accounts}/verification-checklist.md`. No other module touches `docs/`.

## Anti-scope (explicit — DO NOT include in any module)

Per the user prompt, these are explicitly deferred to wave 2 after PR #1018 merges:

- Split `.accountNotFound` enum case
- SignInModal full SwiftUI refactor
- `worktree-refactor-saml-auth` continuation
- ANY changes to `Palace/SignInLogic/` or `Palace/Packages/PalaceAuth/`
- Changes to `Palace/Accounts/Library/AccountsManager.swift`, `Palace/Accounts/Account+State.swift`, `Palace/Accounts/AccountStateStore.swift`

Every module contract states these explicitly under "Files explicitly OFF-LIMITS" with a grep verification command that the module diff does NOT touch them. Module C may DESCRIBE accounts production code in the accounts checklist (since the checklist's job is to describe), but MUST NOT MODIFY any of those files.

## Risk notes

### Module A — audiobook toolkit fragility (FLAG)

**Highest-risk module of the four.** Memory pin `reference_audiobook_toolkit_risk_profile.md` documents 25+ submodule revs with frequent regressions and reverts. The first-open hang itself is a PR #990 (toolkit bump) regression — fixing it touches the most regression-prone surface in the codebase. Specific risks:

- **Cross-vendor breakage.** The four vendor adapters (LCP, BearerToken, OpenAccess, LocalFile) share player infrastructure. A Palace-side readiness gate that works for one vendor might break another. The cross-vendor smoke test (`PalaceTests/AudiobookCrossVendorSmokeTests`) is the mandated regression net — Module A's PR must keep all four cases green.
- **Toolkit submodule temptation.** If the readiness signal is missing from the toolkit's public surface, the implementer might be tempted to bump the submodule to add it. **DO NOT.** Per `reference_audiobook_toolkit_risk_profile.md`, every toolkit rev has historically broken at least one vendor. The escalation contract: if the fix REQUIRES a submodule change, STOP and route through the orchestrator for an explicit go-ahead before the bump.
- **Module A's BookButtonMapper test (Module B) is the F-011 regression net at the UI layer.** Module A fixes the engine-layer race; Module B pins the UI-layer fall-through. They are complementary — both must land for the F-011 close-out to be complete.

### Module B — exhaustive-switch defensive contract (FLAG)

The Phase 7 audit's specific concern: a `case .Foo:` added to `TPPBookState` without a corresponding `BookButtonMapper.map` mapping silently falls through to `.unsupported` and reproduces F-011's UI symptom on a new code path. PR #1006 fixed this by making the switch exhaustive. Module B's META-regression test pins the contract — without it, a future PR could re-add `default: return .unsupported` and pass CI silently. The test must read the source file or use `TPPBookState.allCases` parameterization to cover every case explicitly.

### Module C — `audit-before-assert.py` + auth template may be absent at branch base

The hook script and the auth verification-checklist template both landed in PR #1019 per the user prompt. Branch base check (architect):
- `scripts/audit-before-assert.py` — does NOT exist at branch base.
- `docs/architecture/areas/auth/verification-checklist.md` — does NOT exist at branch base.

Module C contract documents both fallbacks: (a) manual grep-verification block in the transcript if `audit-before-assert.py` is absent; (b) derive a template from `docs/architecture/README.md` + the audit/memory corpus if the auth checklist is absent. Both deviations must be flagged in the swarm transcript and surfaced in the PR description.

### Module D — intentionally-shallow tests

Some test files exist as compile-only smoke (ObjC bridge surface, build-target sanity). Rewriting these to "real behavior tests" would be wrong — their entire job is to fail the build if the symbol's gone. Module D's contract requires the implementer to FLAG these files (`// INTENTIONALLY-SHALLOW: <reason>` annotation + transcript entry) rather than rewrite. Heuristic: file has <5 test methods total + only does compile-touch (constructor non-nil, `XCTAssert(x is T)`-shape) + sits in a bridge directory (ObjC bridge headers, snapshot baselines).

## Acceptance criteria

Aggregate gates (every module must satisfy):

- `scripts/verify-pr.sh --quick` passes on the merged branch (build, tests, lint, coverage, accessibility).
- No edits to anti-scope files (`Palace/SignInLogic/`, `Palace/Packages/PalaceAuth/`, `AccountsManager.swift`, `Account+State.swift`, `AccountStateStore.swift`).
- `mcp__forgeos__forge_check_gates`: architect + qa_test gates satisfied for critical-path modules (A, B).
- Per-module PR against `develop` (4 PRs).

Per-module acceptance criteria are pinned in each contract's "Verification criteria" and "Definition of Done evidence" sections.

## Companion documents

- Memory pins (load-bearing per module):
  - **A:** `audiobook_first_open_hang_3_2_0`, `reference_audiobook_toolkit_risk_profile`, `reference_biblioboard_cross_host_token_scoping`, `feedback_audiobook_sim_audio_limitation`, `feedback_swift_concurrency_over_gcd`, `feedback_no_force_unwraps`.
  - **B:** `.forgeos/audits/phase7-synthesis-2026-05-26.md` (note: may not exist at branch base — escalate if so), `feedback_round_trip_wiring_tests` (CLAUDE.md State-machine wiring tests rule).
  - **C:** `docs/architecture/README.md`, `docs/architecture/areas/auth/verification-checklist.md` (template — may not exist at branch base), all `reference_*` and `feedback_*` pins for the three areas.
  - **D:** `feedback_tdd_mandatory` (CLAUDE.md test cardinality rule).

- Prior swarm reference: `.forgeos/swarms/swarm_eefef87a/` (the A+ posture push — same shape, four parallel modules).
