# Module D — Test Fluff Cleanup Pass (PalaceTests/ only)

**Standard rigor.** Tests-only module. Production code is OFF-LIMITS.

## Goal

Rewrite the highest-priority shallow-violation test bodies in the critical-path test areas — `PalaceTests/(Audiobooks|SignInLogic|MyBooks/Download|Accounts|Network)` — into real behavior tests per CLAUDE.md "TDD & Test Quality" rules. Cap at ~30–50 violations across this swarm so the diff is reviewable in a single sitting. Drive the count toward zero on the highest-signal files first; surface (but DO NOT fix) any test file that appears INTENTIONALLY shallow (e.g. compile-only ObjC bridge smoke).

## Pre-flight finding (architect)

Running `python3 scripts/lint-test-quality.py` produces **232 SHALLOW-001 violations across 90 files**, plus 8 flake + 16 fluff + 0 missing + 0 silent timeouts (256 total). Of the 232 shallow violations, the critical-path scope (Audiobooks/SignInLogic/MyBooks-Download/Accounts/Network) is the highest-priority subset — but **the bulk of shallow violations across the corpus are in `PalaceTests/Accessibility/`, `PalaceTests/CatalogDomain/`, and similar non-critical-path locations**. Module D excludes those; cap is 30–50 violations on critical paths only.

## What public types/protocols change

**No production API changes.** This module is `PalaceTests/`-only.

## What internal seams (DI protocols) need updating

None. Module D operates entirely against existing seams.

## Test contracts the module must satisfy

Each rewritten test MUST satisfy CLAUDE.md "Test quality rules":

1. **Test behavior, not implementation.** Assert what the code DOES, not how it's structured.
2. **Meaningful Arrange → Act → Assert.** A real Act step (driving the SUT, not just instantiating it).
3. **Mocks/stubs for dependencies.** No `.shared` reads, no real network/keychain/UserDefaults.
4. **Edge cases included.** Replacements should add edge cases (empty, nil, error path, expired token, malformed data) — not just deepen a happy path.
5. **Behavior-spec names.** `testFoo_whenX_doesY` shape.
6. **Mutation kill-rate.** When the rewritten file is mutation-tested against the corresponding production file, the change should NOT decrease kill rate. Ideally it should increase by ≥10% per rewritten file with mutation runs.

**Replacement bar:** 1:1 — one shallow test out, one real test in. Do NOT delete tests outright (test count is a tracked signal); REPLACE the body to exercise real logic in the same SUT class.

**Banned patterns** (must NOT appear in any rewritten test):
- `vm.x = 5; XCTAssertEqual(vm.x, 5)` (set-then-assert)
- `XCTAssertEqual(Facet.title.rawValue, "title")` (enum raw values)
- `XCTAssertNotNil(MyClass())` (constructor-non-nil)
- `XCTAssertTrue(x || !x)`, `XCTAssertNotNil(Singleton.shared)`, `XCTAssertTrue(x is SomeType)`, `XCTAssertEqual(x, x)` (tautologies)
- Bool-toggle tests

## Files scoped to THIS implementer

**Critical-path scope** (Module D may rewrite shallow tests in any file under these directories):

- `PalaceTests/Audiobooks/` — but **ONLY files that PRE-EXIST as of the swarm branch base** AND are NOT owned by Module A. Specifically Module D MAY rewrite shallow violations in:
  - `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift`
  - `PalaceTests/Audiobooks/AudiobookTimeTrackerEdgeTests.swift`
  - `PalaceTests/Audiobooks/AudiobookEventsTests.swift`
  - `PalaceTests/Audiobooks/TPPReturnPromptHelperTests.swift`
  - `PalaceTests/Audiobooks/AudioEngineWrapperTests.swift`
  - `PalaceTests/Audiobooks/NowPlayingCoordinatorTests.swift`
  - `PalaceTests/Audiobooks/NowPlayingCoordinatorBackgroundTests.swift`
  - `PalaceTests/Audiobooks/PlaybackBootstrapperTests.swift`
  - `PalaceTests/Audiobooks/AudiobookLoaderFinalizeBuildTests.swift`
  - `PalaceTests/Audiobooks/AudiobookLoadFailureSAMLReauthTests.swift`
  - `PalaceTests/Audiobooks/AudiobookOpenStateRaceTests.swift` (read-only edits — must not collide with Module A; if Module A also edits this file, Module D defers and rewrites a different file from the list)
  - `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift`
  - `PalaceTests/Audiobooks/SAMLPlusBiblioBoardExpirationTests.swift`
  - `PalaceTests/Audiobooks/CrossVendorSmokeTests.swift` — read-only (the smoke gate is contract; Module D MUST NOT modify it)

- `PalaceTests/SignInLogic/` — all test files (high-signal critical-path; ~9 files, ~265 test methods).

- `PalaceTests/Accounts/` — all test files. **EXCEPT** anti-scope wave-2-deferred test files that exercise `AccountsManager.swift`, `Account+State.swift`, `AccountStateStore.swift` PRODUCTION (Module D may TOUCH the test files but MUST NOT touch their production targets; any test rewrite that requires a production seam change is escalated, not bundled).

- `PalaceTests/Network/` — all test files. ~7 files, ~189 test methods.

- `PalaceTests/MyBooks/` — **ONLY non-`Download*Tests.swift` files.** Specifically Module D MAY rewrite shallow violations in MyBooks tests that DO NOT start with `Download` (e.g. `MyBooksViewControllerTests.swift`, `BookCellHelperTests.swift`, etc., if they have shallow violations). **Module D MUST NOT touch `PalaceTests/MyBooks/Download*Tests.swift`** — those are exclusively owned by Module B.

**Overlap-resolution rules (re-stated to be unambiguous):**

- **Audiobook test files:** Module A owns `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift` (NEW) and any additions to `PalaceTests/Audiobooks/Mocks/`. Module D rewrites SHALLOW VIOLATIONS in the pre-existing audiobook test files (list above). If Module A's fix work requires updating a test file Module D is also rewriting in (e.g. `AudiobookOpenStateRaceTests.swift`), the swarm integrator merges Module A first; Module D rebases and chooses a non-conflicting file from the list.

- **MyBooks/Download test files:** Module B owns exclusively. Module D excludes.

- **BookButtonMapper test files:** Module B owns exclusively. Module D excludes (these are not in the critical-path scope list anyway, but stated explicitly).

## Files explicitly OFF-LIMITS

**ALL production code (`Palace/`):** Module D is `PalaceTests/`-only. ZERO production-code edits. Zero `.pbxproj` edits unless Module D adds a NEW test file (it shouldn't — the cap is on REWRITES, not additions).

**Anti-scope (wave-2 deferred — even tests touching these are constrained):**
- `Palace/SignInLogic/`, `Palace/Packages/PalaceAuth/` — Module D MUST NOT modify these.
- `Palace/Accounts/Library/AccountsManager.swift`, `Palace/Accounts/Account+State.swift`, `Palace/Accounts/AccountStateStore.swift` — Module D MUST NOT modify these. Test rewrites that would require a production-side change to these files are ESCALATED, not landed.

**Off-limits per swarm overlap resolution:**

- `PalaceTests/MyBooks/Download*Tests.swift` (Module B's exclusive write).
- `PalaceTests/Book/BookButtonMapper*Tests.swift` (Module B's exclusive write).
- `PalaceTests/BookStateManagement/BookButtonMapperTests.swift` (Module B's exclusive write).
- `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift` (Module A's new file).
- `PalaceTests/Audiobooks/Mocks/AudiobookEngineMock.swift` and any new mocks Module A adds in the same directory (Module A's exclusive write within Audiobooks/Mocks; Module D may read).
- `PalaceTests/Audiobooks/CrossVendorSmokeTests.swift` (contract — read-only).
- `docs/architecture/areas/*` (Module C).

**Intentionally-shallow tests — flag, do not fix:**

Some test files exist deliberately as compile-only smoke (e.g. ObjC bridge surface, build-target sanity, snapshot-baseline regenerators). If a test reads `XCTAssertNotNil(TPPSomeObjCClass())` AND the file header documents this is intentional (or the file has fewer than 5 test methods total and only does compile-touch), Module D should:
1. NOT rewrite it.
2. ADD a header comment `// INTENTIONALLY-SHALLOW: <reason>` if missing.
3. Add a `// lint-test-quality:ignore` annotation if the linter supports one (check `scripts/lint-test-quality.py --help`).
4. Document the file + reason in `transcripts/D-Test-Fluff.md`.

## Verification criteria (MANDATORY — grep-able assertions)

1. **Cap honored — 30–50 violations addressed:**
   ```bash
   python3 scripts/lint-test-quality.py 2>&1 | grep "Total:"
   ```
   Before/after: total violation count MUST decrease by ≥30 and ≤60 (target band 30–50, allow 10-violation flex for cascade fixes within rewritten files). Paste both numbers.

2. **No production code modified:**
   ```bash
   git diff --name-only origin/develop | grep -E '^Palace/'
   ```
   MUST be empty.

3. **No off-limits test files modified:**
   ```bash
   git diff --name-only origin/develop -- 'PalaceTests/MyBooks/Download*Tests.swift' 'PalaceTests/Book/BookButtonMapper*Tests.swift' 'PalaceTests/BookStateManagement/BookButtonMapperTests.swift' 'PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift' 'PalaceTests/Audiobooks/CrossVendorSmokeTests.swift'
   ```
   MUST be empty.

4. **All critical-path scope test files still compile + pass:**
   ```bash
   scripts/verify-pr.sh --quick
   ```
   Must succeed (build, tests, lint, coverage, accessibility).

5. **lint-test-quality.py count decreased in each touched file:**
   For each test file Module D rewrote, paste before/after:
   ```bash
   python3 scripts/lint-test-quality.py --file <path> 2>&1 | grep "Total:"
   ```
   After value MUST be < before value.

6. **No fluff/tautology/coverage-only patterns introduced (banned patterns):**
   ```bash
   git diff origin/develop -- 'PalaceTests/**/*.swift' | grep -E '^\+' | grep -E "XCTAssertTrue\(.* == true \|\|.* == false\)|XCTAssertEqual\(([a-zA-Z_]+), \1\)|XCTAssertNotNil\([A-Za-z_]+\.shared\)"
   ```
   MUST be empty.

7. **Each rewritten test has Arrange→Act→Assert (≥4 lines, ≥1 mock OR ≥1 async, ≥1 assertion):** the SHALLOW-001 rule is `1 assertion, <4 lines, no mocks/async`. After rewrites, the touched tests should NOT match SHALLOW-001 anymore. Verification via Verification #5.

8. **Test count NOT decreased** (the cardinality rule per `feedback_tdd_mandatory.md` — replace 1:1, don't delete):
   ```bash
   git diff origin/develop -- 'PalaceTests/' | grep -E '^\-.*func test[A-Z]' | wc -l
   git diff origin/develop -- 'PalaceTests/' | grep -E '^\+.*func test[A-Z]' | wc -l
   ```
   Added test count MUST be ≥ removed test count. Net delta ≥ 0.

9. **`INTENTIONALLY-SHALLOW` files flagged in transcript:**
   ```bash
   grep -l "INTENTIONALLY-SHALLOW" PalaceTests/**/*.swift
   ```
   Each match cross-references an entry in `.forgeos/swarms/swarm_c8fcab76/transcripts/D-Test-Fluff.md`.

## Definition of Done evidence the implementer must paste

1. **Before/after lint-test-quality totals** (Verification #1) — paste the diff in the PR description.

2. **No production-code diff** (Verification #2 + #3).

3. **`scripts/verify-pr.sh --quick` clean** (Verification #4).

4. **Per-file lint-quality before/after** for each touched test file (Verification #5).

5. **Banned-pattern grep clean** (Verification #6).

6. **Test cardinality preserved or grown** (Verification #8).

## Mutation kill-rate

Not a primary gate for Module D (this is test-quality, not test-coverage-deepening). However, if a rewritten test file corresponds to a critical-path production file (`Palace/SignInLogic/*.swift`, `Palace/MyBooks/Download*.swift` — though Download is Module B's, `Palace/Audiobooks/*.swift`, `Palace/Accounts/*.swift`), the implementer SHOULD run `palace_mutate.py` on the production file with the rewritten tests as the test selector and confirm kill rate does NOT decrease versus origin/develop.

## Implementer prompt (one paragraph)

You are Module D implementer for `swarm_c8fcab76`. Run `~/harness/bin/harness subagent-prelude --domain general`. Your job is to rewrite 30–50 shallow-violation test bodies (per `python3 scripts/lint-test-quality.py`) into real behavior tests, capped to the critical-path matchers `PalaceTests/(Audiobooks|SignInLogic|MyBooks/Download|Accounts|Network)`. **Reread carefully:** `PalaceTests/MyBooks/Download*Tests.swift` is Module B's exclusive write — Module D EXCLUDES those files. `PalaceTests/Book/BookButtonMapper*Tests.swift` and `PalaceTests/BookStateManagement/BookButtonMapperTests.swift` are Module B's exclusive write — Module D EXCLUDES those. `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift` is Module A's new file — Module D EXCLUDES it. `PalaceTests/Audiobooks/CrossVendorSmokeTests.swift` is contract — read-only. Production code is OFF-LIMITS (zero `Palace/` edits). `Palace/SignInLogic/`, `Palace/Packages/PalaceAuth/`, `AccountsManager.swift`, `Account+State.swift`, `AccountStateStore.swift` are wave-2 anti-scope — escalate any test rewrite that requires production changes to those files. Replace 1:1 (CLAUDE.md test cardinality rule: never delete tests, only replace bodies). Flag any test file that appears intentionally shallow (compile-only ObjC bridge smoke) in your transcript and add a `// INTENTIONALLY-SHALLOW: <reason>` header instead of rewriting. Run `scripts/lint-test-quality.py` before AND after on each touched file and paste both numbers. `scripts/verify-pr.sh --quick` MUST be green.
