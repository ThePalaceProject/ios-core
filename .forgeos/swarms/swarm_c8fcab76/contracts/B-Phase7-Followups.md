# Module B — Phase 7 Audit Follow-ups (BookButtonMapper + Download tests)

**Critical-path module.** Closes the remaining Phase 7 audit follow-ups referenced in `.forgeos/audits/phase7-synthesis-2026-05-26.md` (note: audit file lives on the orchestrator's branch and may not be checked in here — the two items below are the substantive close-out).

## Pre-flight verification finding (architect read)

**PR #1006 already addressed (1) — `.SAMLStarted` is no longer falling through.** Current `Palace/Book/UI/BookDetail/BookButtonMapper.swift` (lines 37–68) uses an exhaustive `switch registryState` with no `default:` and explicitly maps `.SAMLStarted` → `.downloadInProgress` (line 40–45). The header comment (lines 18–24) calls out the Phase 7 audit and the F-011 trap.

**Regression test PINNING this case ALREADY EXISTS** at `PalaceTests/BookStateManagement/BookButtonMapperTests.swift:84` (`testMapSAMLStarted_returnsDownloadInProgress`). Audit follow-up (1) is therefore **fully closed in tree** — Module B's job for item (1) is to **add a META-regression test that asserts the switch remains exhaustive** (no `default:` clause), so a future PR cannot silently re-introduce the fall-through. This is the Phase 7-shape regression net.

## Goal

(1) Add a META-regression test that pins the exhaustive-switch contract in `BookButtonMapper.map(...)` so a future PR cannot silently re-introduce the F-011 fall-through (i.e. so a contributor cannot add `default: return .unsupported` and pass CI). (2) Close the ~3 documented mutation kill-rate test gaps in `DownloadStartDispatcher` / `DownloadAuthRetryHandler` / `BookButtonMapper` test files — flip kill-rate to ≥80% diff-scoped on changed test surface (CLAUDE.md critical-path bar).

## What public types/protocols change

**No public API changes.** Module B is tests + (at most) trivial comment-only changes to `BookButtonMapper.swift` if a Swift comment marker is required to defend the exhaustive-switch contract.

## What internal seams (DI protocols) need updating

None. Module B operates entirely on existing seams.

## Test contracts the module must satisfy

### (B1) BookButtonMapper exhaustive-switch META-regression

New test in `PalaceTests/BookStateManagement/BookButtonMapperTests.swift` (preferred location since it already pins SAMLStarted):

- `testMapAllRegistryStates_areExplicitlyHandled_noFallthroughToUnsupported` — uses `TPPBookState.allCases` to parameterize across every case; for each case, builds a minimal availability context and asserts the result is NOT `.unsupported` UNLESS the case is genuinely `.unsupported` or `.unregistered` with nil availability. Pins the "no silent .unsupported fallthrough" invariant. This is the F-011-shape regression net.

- `testMap_exhaustiveSwitch_noDefaultClause` (source-level invariant): reads `BookButtonMapper.swift` from the test bundle's main bundle resources (or via `#filePath` parent resolution) and asserts the function body contains no `default:` line. If file-read at test time is awkward, an equivalent CI-side grep gate is acceptable — but a test-suite-level pin is preferred so it travels with the test file. Per CLAUDE.md "TDD & Test Quality": "Reviewer checklist: when a PR adds a `case .Foo:` to a state-machine switch, ask 'where's the test that proves we can recover from being IN `.Foo`?'" — this test is that pin.

### (B2) DownloadStartDispatcher mutation gap close-out

`PalaceTests/MyBooks/DownloadStartDispatcherTests.swift` currently has 14 test methods. Per `.forgeos/audits/phase7-synthesis-2026-05-26.md` it has ≥1 documented mutation gap. Module B implementer must:

1. Run `python3 scripts/palace_mutate.py --file Palace/MyBooks/DownloadStartDispatcher.swift --tests PalaceTests/DownloadStartDispatcherTests` and capture the surviving mutants list.
2. For each surviving mutant: either (a) extend an existing test with an additional assertion that would kill the mutant, or (b) add a new test method that exercises the mutant's branch through the production seam. Aim for ≥80% diff-scoped kill rate, ≥80% absolute kill rate on the file overall.
3. Test additions MUST follow CLAUDE.md "Test quality rules" — no fluff (set-then-assert), no tautologies, no constructor-non-nil patterns.

### (B3) DownloadAuthRetryHandler mutation gap close-out

`PalaceTests/MyBooks/DownloadAuthRetryHandlerTests.swift` currently has 11 test methods. Same drill as (B2):

1. Run `python3 scripts/palace_mutate.py --file Palace/MyBooks/DownloadAuthRetryHandler.swift --tests PalaceTests/DownloadAuthRetryHandlerTests`.
2. Close the surviving mutants per (B2.2).
3. Per `.forgeos/audits/phase7-synthesis-2026-05-26.md` the documented gap relates to post-borrow predicate coverage; PR #1005 already partly addressed this (`captureAttemptDownload in SpyDelegate; pin post-borrow predicate`). Verify that gap is closed via mutation testing — if it's already 100%, paste the mutation report as evidence and skip.

### (B4) BookButtonMapper mutation kill-rate

After (B1) lands, run `python3 scripts/palace_mutate.py --file Palace/Book/UI/BookDetail/BookButtonMapper.swift --tests PalaceTests/BookButtonMapperTests --diff-only`. Kill rate ≥80% diff-scoped, ≥90% absolute (high bar — this is a 100-LOC mostly-switch file).

### Round-trip wiring (where applicable)

DownloadStartDispatcher tests must exercise the dispatch → registry → completion lifecycle through the production seam. If any added test uses `_setState`-style shortcuts on the registry instead of driving through the dispatcher's public surface, the test does not satisfy this contract (CLAUDE.md State-machine wiring tests rule).

## Files scoped to THIS implementer

Production (read-only or comment-only changes; no behavior changes):
- `Palace/Book/UI/BookDetail/BookButtonMapper.swift` (comment-only — defend the exhaustive-switch contract with a `// EXHAUSTIVE-SWITCH-CONTRACT — pinned by testMap_exhaustiveSwitch_noDefaultClause` marker if helpful; behavior unchanged)
- `Palace/MyBooks/DownloadStartDispatcher.swift` (read-only — Module B does NOT change production behavior here; only adds tests)
- `Palace/MyBooks/DownloadAuthRetryHandler.swift` (read-only — same)

Test (exclusive write):
- `PalaceTests/BookStateManagement/BookButtonMapperTests.swift` (modified — add B1 cases)
- `PalaceTests/Book/BookButtonMapperTests.swift` (modified ONLY if duplicated coverage is needed; preferred location is BookStateManagement; check whether the two files duplicate — if so, consolidate via the test file the audit references, NOT both)
- `PalaceTests/MyBooks/DownloadStartDispatcherTests.swift` (modified — close B2 mutation gap)
- `PalaceTests/MyBooks/DownloadAuthRetryHandlerTests.swift` (modified — close B3 mutation gap)

## Files explicitly OFF-LIMITS

**Anti-scope (deferred to wave 2 after PR #1018 merges):**
- `Palace/SignInLogic/` — entire directory
- `Palace/Packages/PalaceAuth/` — entire package
- `Palace/Accounts/Library/AccountsManager.swift`
- `Palace/Accounts/Account+State.swift`
- `Palace/Accounts/AccountStateStore.swift`

**Off-limits per swarm overlap resolution:**

- `Palace/Audiobooks/` (Module A's production scope) — Module B does not touch audiobook production.
- `PalaceTests/Audiobooks/` — Module B does not touch audiobook tests.
- `PalaceTests/MyBooks/Download*Tests.swift` — **Module B has EXCLUSIVE WRITE on these test files** (B2, B3 mutation close-out). **Module D MUST NOT touch any `PalaceTests/MyBooks/Download*Tests.swift` file.** Overlap resolution: B owns Download test files entirely; D's MyBooks/Download scope is empty. If Module D's lint-test-quality.py pass surfaces shallow tests in these files, those violations are deferred to a future test-deepening swarm — they do NOT belong in Module D's 30–50 critical-path cap for this swarm.
- `PalaceTests/Book/BookButtonMapper*Tests.swift` and `PalaceTests/BookStateManagement/BookButtonMapperTests.swift` — **Module B has EXCLUSIVE WRITE.** Module D does NOT rewrite shallow tests in these files for this swarm.
- `docs/architecture/areas/*` (Module C)

**Other production files** — Module B does NOT change download/borrow production behavior in this swarm; mutation-gap close-out is test-side only. If a surviving mutant cannot be killed without a production change (e.g. an unreachable branch), the implementer must escalate to the orchestrator BEFORE adding a production hook.

## Verification criteria (MANDATORY — grep-able assertions)

1. **Exhaustive-switch META test exists:**
   ```bash
   grep -c "testMapAllRegistryStates_areExplicitlyHandled_noFallthroughToUnsupported\|testMap_exhaustiveSwitch_noDefaultClause" PalaceTests/BookStateManagement/BookButtonMapperTests.swift
   ```
   MUST return ≥1.

2. **All `TPPBookState` cases are exercised in the parameterized test:**
   ```bash
   grep -c "TPPBookState.allCases\|allCases.forEach\|for state in TPPBookState.allCases" PalaceTests/BookStateManagement/BookButtonMapperTests.swift
   ```
   MUST return ≥1.

3. **Confirm exhaustive switch is still present in production (no regression):**
   ```bash
   grep -c "default:" Palace/Book/UI/BookDetail/BookButtonMapper.swift
   ```
   MUST return 0 (zero `default:` clauses — exhaustive switch).
   ```bash
   grep -c "case .SAMLStarted:" Palace/Book/UI/BookDetail/BookButtonMapper.swift
   ```
   MUST return 1.

4. **SUT instantiation in BookButtonMapper test file (CLAUDE.md SUT rule):**
   ```bash
   grep -c "BookButtonMapper\." PalaceTests/BookStateManagement/BookButtonMapperTests.swift
   ```
   MUST return ≥1 (the SUT is `BookButtonMapper` — static methods, so the grep is `BookButtonMapper.` for `.map`/`.stateForAvailability`).

5. **DownloadStartDispatcher mutation kill-rate ≥80% diff-scoped:**
   ```bash
   python3 scripts/palace_mutate.py --file Palace/MyBooks/DownloadStartDispatcher.swift \
     --tests PalaceTests/DownloadStartDispatcherTests --diff-only --diff-base origin/develop
   ```
   Paste output. Killed / Total ≥ 80%.

6. **DownloadAuthRetryHandler mutation kill-rate ≥80% diff-scoped:**
   ```bash
   python3 scripts/palace_mutate.py --file Palace/MyBooks/DownloadAuthRetryHandler.swift \
     --tests PalaceTests/DownloadAuthRetryHandlerTests --diff-only --diff-base origin/develop
   ```
   Paste output. Killed / Total ≥ 80%.

7. **BookButtonMapper mutation kill-rate ≥80% diff-scoped:**
   ```bash
   python3 scripts/palace_mutate.py --file Palace/Book/UI/BookDetail/BookButtonMapper.swift \
     --tests PalaceTests/BookButtonMapperTests --diff-only --diff-base origin/develop
   ```
   Paste output. Killed / Total ≥ 80%.

8. **No production behavior changes (modulo trivial comment markers):**
   ```bash
   git diff origin/develop -- Palace/Book/UI/BookDetail/BookButtonMapper.swift Palace/MyBooks/DownloadStartDispatcher.swift Palace/MyBooks/DownloadAuthRetryHandler.swift | grep -E '^\+' | grep -vE '^(\+\+\+|\+//)'
   ```
   Should be empty or only test seams (`internal` visibility hooks). Behavior code MUST NOT change without escalation.

9. **No off-limits files modified:**
   ```bash
   git diff --name-only origin/develop -- Palace/SignInLogic/ Palace/Packages/PalaceAuth/ Palace/Accounts/Library/AccountsManager.swift Palace/Accounts/Account+State.swift Palace/Accounts/AccountStateStore.swift Palace/Audiobooks/ PalaceTests/Audiobooks/
   ```
   MUST be empty.

10. **lint-test-quality.py clean on changed test files:**
    ```bash
    python3 scripts/lint-test-quality.py --file PalaceTests/BookStateManagement/BookButtonMapperTests.swift
    python3 scripts/lint-test-quality.py --file PalaceTests/MyBooks/DownloadStartDispatcherTests.swift
    python3 scripts/lint-test-quality.py --file PalaceTests/MyBooks/DownloadAuthRetryHandlerTests.swift
    ```
    Total violations MUST NOT INCREASE versus `origin/develop`. Decreasing is preferred.

## Definition of Done evidence the implementer must paste

1. **TDD evidence — surviving-mutant before/after for each of B2, B3, B4:**
   - Before: `palace_mutate.py` output captured BEFORE test additions, showing surviving mutants.
   - After: same command, showing fewer surviving mutants. Kill rate Δ ≥ +20% if any mutants were surviving.

2. **`scripts/lint-test-quality.py --file <each-test-file>`** clean or no-net-new violations.

3. **Full test suite green:** `scripts/verify-pr.sh --quick` passes.

4. **Mutation kill-rate** ≥80% diff-scoped on each of the four target files (B1 BookButtonMapper, B2 DownloadStartDispatcher, B3 DownloadAuthRetryHandler, B4 BookButtonMapper rerun). Critical-path 100% is ideal per CLAUDE.md.

5. **Diff is test-only or comment-only:** `git diff --stat origin/develop` shows production behavior code unchanged (test files, comment-only production diff hunks).

6. **Cross-references intact:** `Palace/Book/UI/BookDetail/BookButtonMapper.swift` header comment (lines 18–24) still references the Phase 7 audit + F-011 trap; the new META test file/header references the same audit so the chain is traceable.

## Implementer prompt (one paragraph)

You are Module B implementer for `swarm_c8fcab76`. Phase 7 audit follow-up (1) — SAMLStarted fall-through — was already closed by PR #1006 (verified by architect: exhaustive switch + existing pinned test at `BookButtonMapperTests.swift:84`). Your job is the META-regression test that locks the exhaustive-switch contract (so a future PR cannot silently re-introduce `default: return .unsupported`) AND closes the mutation kill-rate gaps in `DownloadStartDispatcher`, `DownloadAuthRetryHandler`, and `BookButtonMapper` test files. This is test-only / comment-only work — DO NOT change production behavior; if a surviving mutant cannot be killed without a production change, escalate to the orchestrator. Use `TPPBookState.allCases` for the parameterized exhaustive test. Critical-path mutation bar: ≥80% diff-scoped kill rate per CLAUDE.md (100% ideal). DO NOT touch `Palace/Audiobooks/`, `PalaceTests/Audiobooks/`, `Palace/SignInLogic/`, `Palace/Accounts/`, or `docs/architecture/areas/`. Run `scripts/lint-test-quality.py` on each changed test file and confirm no net-new violations.
