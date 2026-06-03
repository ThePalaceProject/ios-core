# swarm_4b64e4e0 — Wave 1 implementation plan

**Mode:** implementation. **Output:** Fix 1 + Fix 2 from swarm_f88ae9e3/outcome.md landed against `develop` via two parallel module implementers, gated by architect + SoD review.

## Goal

Eliminate the two highest-leverage iOS test-flakiness sources identified in `swarm_f88ae9e3` outcome:

1. **Fix 1 — PalaceTestSetup XCTestObservation reset hook.** Closes A's blast radius + D's process-global state + B's SpyDelegate Task leak (partial) with one process-wide observer that walks a registered resetter list after every test.
2. **Fix 2 — AppContainer._resetForTesting() DEBUG-only seam.** Closes the structural root of A: the static `_cached` AppContainer constructs `AccountsManager()` without the test opt-out, spawning a process-lifetime background `loadCatalogs` task. The new seam rebuilds the graph with the opt-out flag set, between tests.

User-approved direction (from `swarm_f88ae9e3/outcome.md` decisions section):
- Structural first, no stop-the-bleeding patch.
- Implementation mode: /swarm.
- Palace-noDRM scheme decision (remove `testExecutionOrdering="random"` from both schemes) — Wave 2 / Fix 5, NOT this swarm.

## Modules

| Module | Scope | Files (touched) | Critical-path? | Mutation gate |
|---|---|---|---|---|
| **A — Test infrastructure** | Test-target only. SingletonResetRegistry + XCTestObservation + URL stub resetters. | PalaceTestSetup.swift, HTTPStubURLProtocol.swift, URLSession+Stubbing.swift; NEW: Support/SingletonResetRegistry.swift + 3 new test files | NO (test target) | N/A (test code) |
| **B — Production seams** | AppContainer._resetForTesting + AccountsManager.cancelBackgroundWork | Palace/AppInfrastructure/AppContainer.swift, Palace/Accounts/Library/AccountsManager.swift; NEW: 2 new test files | YES (AppContainer + AccountsManager both critical-path per CLAUDE.md) | ≥80% AppContainer.swift, ≥50% AccountsManager.swift |

Total: 5 production-file modifications (3 test target, 2 production) + 6 NEW files (4 new test files + 1 new test-support file + 1 new pbxproj-only registration burst) + 6 pbxproj entries added via `scripts/pbxproj_add_swift.rb`.

## Parallelism plan

A and B run in parallel.

**Cross-reference contract:** Module A's `PalaceTestSetup.swift` references `AppContainer._resetForTesting` by NAME (the closure body is `AppContainer._resetForTesting()`). Module B owns the symbol. Resolution:

1. A and B branch off `swarm/swarm_4b64e4e0-scaffold` in parallel.
2. A wraps its registry-bootstrap call in `#if DEBUG ... #endif` so the closure body compiles even if B's branch hasn't merged. The closure is invoked at RUNTIME, so as long as B's symbol exists when the test bundle loads, the registry resolves. If B's branch lands AFTER A in CI/develop ordering, the symbol-missing window is the brief moment between A's merge and B's merge — and CI is gated by `verify-pr.sh` which fails build if the symbol is missing, so the safety net catches a bad merge order.
3. Integrator merges A first ONLY if `develop` already carries an `AppContainer._resetForTesting` definition (it does not — confirmed by grep). Therefore the merge order is: B first → A second.
4. Alternative (simpler): integrator bundles A + B as a single squash-merged PR. This is the recommended path; it avoids the merge-order safety dance.

**Integrator default**: bundled PR. Two implementers branch off the swarm scaffold; integrator rebases and bundles before opening the PR against `develop`.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `static let _cached` → `static var _cached` regresses dispatch_once semantics | HIGH | Module B contract verification #4 (`production()` signature unchanged) + Module B's mutation pass (≥80% kill rate). Existing AppContainerTests must stay green. |
| Residual cancellation race window after `_resetForTesting` | MED | Documented intentional. The old AccountsManager is unreachable from `production()` post-reset; only code paths holding strong refs to the prior instance observe its background-completion side effects. Acceptable per user direction. |
| XCTestObservation observer dropped by ARC | LOW | Module A contract verification #6 — the `static var observer:` retain. Test #1 of `PalaceTestSetupObservationTests` pins idempotence (re-bootstrap returns same instance). |
| NotificationCenter audit's `debugDescription` regex parse fails on a future Xcode version | LOW | Audit-only — failure path returns nil and silently skips the audit for that test. NOT a hard assertion. The fallback is documented in the observer's docblock. |
| `URLSession._resetStubbedSession()` racing with in-flight test completion handlers | MED | The implementation uses `finishTasksAndInvalidate()` (NOT `invalidateAndCancel`) per the existing file's header. The contract test `testResetStubbedSession_inFlightTaskOnOldSession_completesGracefully` pins this property. |
| Per-module commit hooks block on `check-blast-radius.py` for the new `#if DEBUG` test seam | LOW | Module B's `_resetForTesting` IS `#if DEBUG`-guarded. The script's heuristic treats `#if DEBUG`-guarded test seams as test-only. If the script flags it, the implementer adds the standard `// test-seam:` marker per `scripts/check-blast-radius.py` docs. |
| Mutation pass on AppContainer.swift exceeds time budget | MED | `palace_mutate.py --diff-only` scopes mutation to the new lines (the new function + the `let`→`var` line). Cache hits accelerate repeat runs. |

## Acceptance criteria

- [ ] Both contracts pass their verification grep batteries (Module A: 12 criteria, Module B: 17 criteria).
- [ ] Module B mutation kill-rate ≥80% diff-scoped on AppContainer.swift, ≥50% on AccountsManager.swift.
- [ ] `scripts/verify-pr.sh --quick` PASS.
- [ ] `scripts/check-blast-radius.py --quiet` exit 0.
- [ ] `scripts/check-contract-reconciliation.py --commit-msg <commit-msg-file> --quiet` exit 0.
- [ ] All 18 new tests across the 5 new test files pass on iPhone 16 Pro / iOS 26.
- [ ] Existing AppContainerTests + AccountsManagerStateMachineWiringTests still green.
- [ ] No new force unwraps, no new `.shared` reads in production code.
- [ ] DoD evidence (CLAUDE.md 10-check list) pasted in each implementer's transcript.
- [ ] SoD reviews: architect (this doc), qa_test reviewer, clean_code reviewer ALL signed off (per CLAUDE.md critical-path rule for AppContainer + AccountsManager).
- [ ] PR body cites swarm_f88ae9e3 outcome.md Fix 1 + Fix 2 as the justification.
- [ ] Wall-failure improvement entry stub `.forgeos/wall-failures/2026-05-29-flakiness-singleton-residue.md` updated post-merge (Wave 2 follow-up — already noted in outcome.md).

## Sequencing

1. **Phase 1 (this output)**: architect contracts + manifest + plan persisted. Orchestrator commits scaffold.
2. **Phase 2**: orchestrator dispatches Module A + Module B implementers in parallel (each on its own branch off `swarm/swarm_4b64e4e0-scaffold`).
3. **Phase 3**: both implementers report READY with DoD evidence.
4. **Phase 4**: orchestrator integrates (bundled PR) + runs Phase 4.5 verification battery from Module A + Module B contracts.
5. **Phase 5**: SoD review — architect (this doc) + qa_test reviewer + clean_code reviewer.
6. **Phase 6**: open PR against `develop`. Promote via ForgeOS gate.

## Wave 2 reminders (NOT in this swarm)

- Remove `testExecutionOrdering="random"` from `Palace.xcscheme` lines 88 + 99 (uniform default ordering across both schemes). This is Fix 5 per outcome.md.
- Land Fix 3 (HTTPStubURLProtocol restructure: narrow `canInit`, drop `releaseGate.wait(3.0)`) — currently the largest residual flake amplifier per investigator D.
- Land Fix 4 (lint suite) — `check-singleton-leaks.py` + sibling scripts.
- Land Fix 6 (actor-iso Tier 1+2 cleanup) — `HoldsBookViewModel.id` nonisolated + CarPlay observer methods.

Wave 1 (this swarm) restores enough determinism that Wave 2 work can land incrementally without each PR triggering the random-order flake cascade.
