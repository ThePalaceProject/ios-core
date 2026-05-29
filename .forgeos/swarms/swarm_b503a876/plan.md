# swarm_b503a876 — Wave 2 plan (tight)

**Source:** `swarm_f88ae9e3/outcome.md` Fix 3 + 4 + 5 + 6 (user-approved).
**Mode:** implementation. 4 parallel modules, no inter-dependencies.
**Discipline (per 2026-05-29 user observation):** commit body is the canonical record; no per-module contract files; no on-disk reviewer verdicts (ForgeOS `rev_*` URLs are durable); transcripts only if an implementer reports a non-obvious decision the commit message can't carry.

## Modules

| Mod | Fix | Scope summary | Files | Critical-path? |
|-----|-----|---------------|-------|----------------|
| A | Fix 3 | HTTPStubURLProtocol restructure: narrow `canInit` to URL-predicate, drop process-wide stubbed-session singleton, replace 3s `releaseGate.wait` with non-blocking completion. ADDITIVE — legacy API still compiles; 35 callers do NOT migrate this PR. | `PalaceTests/Mocks/HTTPStubURLProtocol.swift`, `PalaceTests/Mocks/URLSession+Stubbing.swift`, new `PalaceTests/Support/HTTPStubTestCase.swift` | No (test infra) |
| B | Fix 4 | Lint suite: 5 new stdlib-Python scripts at `scripts/check-singleton-leaks.py`, `check-keychain-guard-coverage.py`, `check-sleep-in-tests.py`, `check-protocol-isolation.py`, `check-test-tautology.py`. Each <300 LOC; KNOWN-BAD + KNOWN-GOOD fixtures; wired into `verify-pr.sh` (warn-only first) + `pre-commit` tri-state. | `scripts/check-*.py`, `scripts/test_check_*.py`, `scripts/_fixtures/w2/`, `scripts/verify-pr.sh`, `scripts/git-hooks/pre-commit` | No (tooling) |
| C | Fix 6 | Actor-iso Tier 1+2 cleanup (NOT Tier 3): `HoldsBookViewModel.id → nonisolated`, CarPlay observers nonisolated+hop, `TPPSignIn{Out,}BusinessLogicUIDelegate` + `NYPLUserAccountInputProvider` `@MainActor` at protocol def, `ErrorLogExporter` drop `@MainActor` on class + `Task { @MainActor in }` for mail composer delegate. | `Palace/Holds/HoldsViewModel.swift`, `Palace/CarPlay/CarPlayTemplateManager.swift`, `Palace/SignInLogic/TPPSignInBusinessLogicUIDelegate.swift` (or wherever defined), `Palace/Settings/AccountDetailViewModel.swift`, `Palace/Logging/ErrorLogExporter.swift` | **Yes** — SignInLogic, Settings touched |
| D | Fix 5 | Remove `testExecutionOrdering="random"` from `Palace.xcscheme` (both occurrences); keep `Palace-noDRM.xcscheme` unchanged (per user direction); port `--diff-baseline` rerun-in-isolation INTO `scripts/xcode-test-optimized.sh` (do NOT touch `.github/workflows/unit-testing.yml`). | `Palace.xcodeproj/xcshareddata/xcschemes/Palace.xcscheme`, `scripts/xcode-test-optimized.sh` | No (build infra) |

## Parallelism

All 4 modules dispatch in parallel. Disjoint file sets verified. Module C is the only critical-path; full DoD 10-check on it.

## Acceptance criteria (orchestrator-scoped)

1. Each module's implementer pastes DoD evidence (per CLAUDE.md) in the commit body.
2. `verify-pr.sh --quick` PASS after integration.
3. Wiring tests (Wave 1 regression) still 13/13 random-order × 25 runs.
4. SoD review: architect + qa_test + blast-radius on the integrated commit. ForgeOS `cs_*` records hold the verdicts; no on-disk copies.
5. Wall-failure entry for any reviewer BLOCK (per CLAUDE.md catalog rule).

## Out of scope

- Tier 3 actor-iso (`NYPLBasicAuthCredentialsProvider`) — real architectural call; separate ticket.
- HTTPStub caller-migration sweep (35 files) — separate PR after Wave 2 settles.
- ios-audiobooktoolkit submodule actor-iso — separate PR pipeline.
- `.github/workflows/unit-testing.yml` edits — architect chose to keep YAML untouched and port logic into `xcode-test-optimized.sh` instead.
