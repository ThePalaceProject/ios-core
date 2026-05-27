# swarm_66819d80 — outcome

**Status:** complete
**Initiative:** init_fd2178b0 — 3.2.0 Auth Architecture Remediation
**Changeset:** cs_8f163b41
**Branch:** swarm/swarm_66819d80-scaffold
**Base:** origin/develop @ d7f115adeb69032fb3abed33ba07b3deeb245f4b
**Worktree:** .claude/worktrees/swarm_66819d80-orchestrator
**Started:** 2026-05-27 ~13:18 ET
**Completed:** 2026-05-27 ~17:58 ET (~4h45m wall)

## What shipped

Cross-cutting auth-error consolidation at the PalaceAuth SPM boundary, plus predicate cleanup, plus structured telemetry. Before this swarm, every network consumer (BookReturnService, BorrowOperation, TokenRefreshInterceptor, TPPNetworkResponder, DownloadAuthRetryHandler, AudiobookSessionManager) handled 401/403 with subtly-different per-call-site code — each prior release shipped at least one patch for this class of bug (#910, #930, #931, #935, #909, #933). After: those callers route through `AuthErrorClassifier` (typed `(URLResponse, ProblemDoc?, Data?) → AuthOutcome`) → `AuthCoordinator` (single-flight actor with 30s cooldown, owns mechanism choice). The next regression of this class is structurally impossible rather than individually patchable.

## Modules

| Module | Surface | Pass count |
|---|---|---|
| **A — PalaceAuth** | `AuthErrorClassifier` + `AuthCoordinator` + `AuthOutcome` + `AuthCoordinatorSeams` in `Palace/Packages/PalaceAuth/` | 1 implementer pass |
| **B — isBrowserBased** | `AccountDetails.Authentication.isBrowserBased`; 6 scattered predicates consolidated | 1 implementer pass + 1 fixup (missing test file) |
| **C — CallerMigration** | BookReturnService, AudiobookSessionManager, TPPNetworkResponder, TokenRefreshInterceptor, DownloadAuthRetryHandler, BorrowOperation routed through AuthCoordinator | 3 implementer passes (initial scaffold + 5 site completion + reviewer fixup) |
| **D — TelemetryFixtures** | `AuthDecisionEvent` + `AuthDecisionRecorder` (main target Crashlytics wrapper) + `AuthDecisionPayload` (PalaceAuth value type); 5 surface points instrumented; recording gap report | 1 implementer pass |

## Diff

- 52 files changed: 8,438 insertions / 104 deletions (incl. 4 Phase 0 recon docs and 4 module contracts)
- 11 new production files (PalaceAuth SPM seams + main-target conformance adapters + telemetry)
- 14 new test files (60 PalaceAuth SPM tests + 25 new main-target tests)
- 6 modified production files (the migrated callers)
- 2 modified PalaceTests (AppContainer test updates for new required init param)

## Test surface (verified green)

- **PalaceAuth SPM:** 97 tests (60 net-new + 35 telemetry + 2 pre-existing smoke)
  - AuthErrorClassifierTests: 34/34 + AuthErrorClassifierPropertyTests: 1/1 (200 trials) — 100% mutation (17/17)
  - AuthCoordinatorTests: 23/23 + AuthCoordinatorWiringTests: 2/2 — 100% mutation (10/10)
  - AuthDecisionPayloadTests + AuthTelemetryEmissionTests: 35/35
- **Main target Auth-side tests:** 16 new spy-coordinator suites (BookReturn/Borrow/TokenRefresh/Download/NetworkResponder, all instantiating real services post-fixup) + 12 telemetry emission tests
- **Module B truth-table + behavior pins:** 13 (10 truth + 3 broadening for Clever)
- **Critical-path regression suite (15 suites, 147 tests):** 100% green

## Reviewer history

| Round | Architect | QA |
|---|---|---|
| 1 | rev_61cc1bc4 BLOCKED (3 findings: submodule typechanges, fake wiring test, dead TPPNetworkResponder classifier call) | rev_3d0048c7 BLOCKED (3 findings: half-done circuit-breaker test, fake responder test, fake service test) |
| 2 | rev_c654b55b APPROVED (with 2 non-blocking warnings) | rev_3cfc4d1e APPROVED (with 1 cosmetic warning) |

**Lesson:** Both reviewers independently flagged TPPNetworkResponder migration as fake (classifier called but outcome only logged) and the responder/service-level tests as not actually exercising the services they claimed to. The SoD pattern worked exactly as designed — neither finding would have been caught by mutation testing or verify-pr.sh alone.

## Non-blocking warnings (follow-up next sprint)

1. **TokenRefreshInterceptor.swift:106 + DownloadAuthRetryHandler.swift:109** still call `indicatesAuthenticationNeedsRefresh` — out of scope for this swarm's TPPNetworkResponder migration, flagged for follow-up.
2. **Filename mismatch:** `AppContainerAuthCoordinatorWiringTests.swift` contains class `AppContainerAuthCoordinatorRegistrationTests`. Rename in follow-up.
3. **TPPNetworkResponderAuthCoordinatorTests.swift:103-118** docstring describes ARCH-3 carve-out but test body pins no-credentials short-circuit. Cosmetic.
4. **Legacy `else` fallback branches** in 4 of the migrated callers retain ~150 LOC of duplicated dispatch alive — rollback-safe but creates two-places-to-edit risk. Schedule 3.2.x cleanup ticket.
5. **9 pre-existing test-isolation flakes** in `verify-pr.sh --quick` full-suite (NetworkExecutorResponseRegression, TPPReaderBookmarksBL, TPPBookRegistryPersistence, TokenRefresh, NotificationServiceStateMachine, AccountSwitchLifecycle) — each class passes 100% in isolation. Tracked by parallel CI-flake hardening PRs #989/#999/#984/#1011.

## Explicit non-goals (deferred to next sprint)

- Full trunk move of `TPPSignInBusinessLogic` + 7 extensions + `TPPReauthenticator` + 5 UI files into PalaceAuth.
- Strategy-pattern rewrite (explicitly rejected in `calm-knitting-thunder.md`).
- Per-IdP simdrive recordings for the 11 UNKNOWN IdP×scenario cells in `docs/3.2.0-auth-idp-catalog.md` (gap report in `transcripts/D-fixtures-gap-report.md`).
- Migration of `TokenRefreshInterceptor` + `DownloadAuthRetryHandler` to drop `indicatesAuthenticationNeedsRefresh` (warning #1 above).

## Agents

- 1 architect (general-purpose, Phase 0 recon + 4 contracts + plan + manifest)
- 4 initial implementers (A, B, C, D — parallel A+B, then C+D)
- 1 B fixup (missing BookReturn test file)
- 1 C continuation (5 deferred sites + wiring test)
- 1 reviewer-fixup (6 reviewer findings)
- 2 architect reviewers (1 blocked + 1 approved)
- 2 qa_test reviewers (1 blocked + 1 approved)
- **Total: 12 subagent invocations**

## Gates promoted

- review (architect): passed 2026-05-27 21:58:12Z
- testing (qa_test): passed 2026-05-27 21:58:17Z
- release (no role): passed 2026-05-27 21:58:35Z
