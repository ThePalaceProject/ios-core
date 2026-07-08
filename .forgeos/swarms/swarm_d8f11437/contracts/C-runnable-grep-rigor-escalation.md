## Contract C — `.forgeos/swarms/swarm_d8f11437/contracts/C-runnable-grep-rigor-escalation.md`

````markdown
# Module C — Runnable-grep rigor escalation (wave 4)

**Standard-risk module.** Process / scripts / docs only. No critical-path code. clean_code reviewer only.

**Self-referential:** This module's script gates Module A's tests in Phase 4.5. If Module C ships a broken script, Module A's wiring test could pass the wall via vacuous-check. Test the script against KNOWN-GOOD and KNOWN-BAD examples.

## Goal

Land the runnable-grep escalation derived from wall-failure cs_9a267b63 (architect rev_bc20951b). Three artifacts:

1. **`scripts/check-test-name-vs-body.py`** — NEW Python script that parses test method names embedding multi-step verbs + PascalCase class nouns; greps the test body for the noun being instantiated or statically called. Exits non-zero if a mismatch is found.
2. **`.claude/skills/swarm/SKILL.md` Phase 4.5 check 5b** — replace the documented "manual review / TODO" with an actual `python3 scripts/check-test-name-vs-body.py` invocation that exits non-zero on failure.
3. **`CLAUDE.md` DoD check #1** — extend from FILE-LEVEL SUT instantiation to METHOD-LEVEL using the new script.

## Resolved decision: script lives in `scripts/`, NOT in harness

Per orchestrator recommendation (referenced in the task brief): `scripts/check-test-name-vs-body.py` lives in the iOS repo (`scripts/`), NOT in `~/harness/core/lib/`. Justification: the script is specific to Swift test conventions (XCTest method-naming + Swift identifier syntax + `func test*()` patterns) and runs against this repo's test files. Maintainer-only tooling in `~/harness/` is for harness-internal logic; this script is iOS-specific.

## Script specification

**File:** `scripts/check-test-name-vs-body.py`
**Estimated LOC:** ~120-180

### Command-line interface

```
Usage: python3 scripts/check-test-name-vs-body.py [--strict] <test-file> [<test-file> ...]

Options:
  --strict    Treat warnings as errors (default: warnings exit 0, errors exit 1)
  --quiet     Suppress per-file progress; only print findings

Exit codes:
  0 — all multi-step test names have matching bodies (or no multi-step names)
  1 — at least one multi-step test name has a body that doesn't instantiate the embedded noun
  2 — file parse error or arg error
```

### Detection algorithm

1. **Read each `<test-file>`** (must be a Swift file under `PalaceTests/`).
2. **Find every `func test*(...)`** declaration using a regex that handles `async`, `throws`, and various arg shapes. Extract the test name.
3. **Filter to multi-step names.** A test name is "multi-step" if it contains ANY of these case-insensitive substrings as token boundaries:
   - `Path` / `path`
   - `via` (e.g. `viaAuthCoordinator`)
   - `through` / `Through`
   - `invokes` / `Invokes`
   - `roundtrip` / `Roundtrip`
   - `across` / `Across`
   - `inProduction` / `InProduction`
   - `viaX` literal (rare; appears in wall-failure entry's pattern list)
   - `Wiring` (literal — case-sensitive — to match swarm SKILL Phase 4.5 check 5b's existing regex)
4. **For each multi-step test name, extract PascalCase identifiers.** Use a regex like `[A-Z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*` to find compound PascalCase tokens. Then split on transitions where useful (e.g. `TPPReauthenticatorPath` → consider both `TPPReauthenticatorPath` and `TPPReauthenticator` as candidate nouns).
5. **Skip well-known noise patterns.** A skip-list (configurable, hardcoded for v1):
   - `XCTestCase`
   - `XCTAssert*` family
   - `Bundle`
   - `String`, `Int`, `Bool`, `URL`, `Data`, `Date`, `Set`, `Array`, `Dictionary` (primitives)
   - `MainActor`
   - `Task`, `Combine`, `Publisher`
   - `Path` alone (not a class, just a verb token in the name)
   - `Via`, `Through`, `Invokes`, `Roundtrip`, `Across`, `InProduction`, `Wiring`, `Test`, `Tests`, `When`, `Then`, `Should`, `Returns`, `For`, `From`, `With` (helper verbs, not nouns)
6. **Extract the test method body.** From the `func test*(...) { ... }` brace pair. Use brace-counting to find the matching `}`.
7. **For each candidate noun, check the body:**
   - Pattern 1 (instantiation): `<Noun>\(` — matches `TPPReauthenticator(` or `TPPReauthenticator()`. 
   - Pattern 2 (static call): `<Noun>\.` — matches `TPPReauthenticator.someMethod`.
   - Pattern 3 (type usage): `: <Noun>` or `<Noun>?` or `<Noun>!` — matches `let x: TPPReauthenticator = ...`.
   - If NONE of the three match, the noun is "missing from body". Record a finding.
8. **Print findings.** Format:
   ```
   FAIL: <test-file>:<line>  test name `<testName>` embeds noun `<noun>` but body never references it.
         Suggested fix: instantiate `<noun>(` in the test body, OR rename the test to not embed `<noun>`.
         (Wall-failure shape: .forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md — fake-wiring-test pattern.)
   ```
9. **Exit code:** 0 if zero FAILs, 1 if ≥1 FAIL.

### Hardening / edge cases

- **String literals in the method body should NOT count.** If the noun appears only inside `"..."` or `#"..."#` (Swift string interpolation), it's not a real reference. (Implement by stripping string literals before the body-grep.)
- **Comments don't count.** Strip `//` line comments and `/* ... */` block comments before the body-grep.
- **PascalCase noun extraction edge case:** `TPPReauthenticatorPath` → both `TPPReauthenticatorPath` and `TPPReauthenticator` are candidates. The script tries the LONGEST candidate first; if found, done. If not, try `TPPReauthenticator`. The "noun" reported is the longest one that matched OR the most-specific one that failed.
- **Negative test fixture (for the script's own self-test):**
  ```swift
  // KNOWN-BAD example — the script must report a FAIL.
  func testReauth_TPPReauthenticatorPath_invokesPresentationViaSafelyPresent() {
      let presenter = makePresenter(...)
      presenter.presentSignInModalForCurrentAccount { ... }
      // TPPReauthenticator NEVER appears in the body — fake wiring
  }
  ```
- **Positive test fixture:**
  ```swift
  // KNOWN-GOOD example — the script must accept.
  func testReauth_TPPReauthenticator_authenticateIfNeeded_drivesSpy() {
      let reauth = TPPReauthenticator()  // ← instantiates the embedded noun
      reauth.authenticateIfNeeded(...)
  }
  ```
- **The script MUST self-test against these two fixtures.** Embed them in the script's `--self-test` mode (optional) OR as a separate `scripts/test_check_test_name_vs_body.py` companion (recommended).

## SKILL.md Phase 4.5 check 5b wiring

**Replace** the existing block at `.claude/skills/swarm/SKILL.md:458-479` (currently a "warning + TODO + manual review" stub) with:

```bash
# Check 5b: for every claimed production-seam test in the diff, run the
# runnable-grep check that catches the wall-failure cs_9a267b63 pattern
# (fake-wiring tests where the name embeds a production class noun that
# the body never instantiates).
DIFF_TESTS=$(git diff --cached --name-only | grep -E "PalaceTests/.*Tests\.swift$" || true)
if [ -n "$DIFF_TESTS" ]; then
  python3 scripts/check-test-name-vs-body.py $DIFF_TESTS || {
    echo "BLOCK: scripts/check-test-name-vs-body.py reported fake-wiring test(s)"
    echo "  Wall-failure shape: .forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md"
    echo "  Action: either instantiate the embedded production-class noun in the test body,"
    echo "          or rename the test to not embed it (only the name promises the wiring)."
    exit 1
  }
fi
```

## CLAUDE.md DoD check #1 extension

**Extend** the existing block at `CLAUDE.md` line 189 (DoD check #1 — "SUT instantiation check") with the following addition AFTER the existing file-level check description:

```markdown
**Method-level extension (added wave 4 / cs_9a267b63 escalation):** For each test METHOD whose name embeds a PascalCase production-class noun (e.g. `testX_TPPReauthenticatorPath_invokesY` embeds `TPPReauthenticator` and `Y`), the same test method's body must call `TPPReauthenticator(...)` (instantiation) or `TPPReauthenticator.method(...)` (static call) or have an explicit type annotation `: TPPReauthenticator`. Verify mechanically with:

```bash
python3 scripts/check-test-name-vs-body.py PalaceTests/<your-modified-file>.swift
```

A non-zero exit means the test name embeds a noun the body doesn't reference. Fake-wiring tests of this shape have escaped into the codebase twice (cs_847892e8 arch1 + cs_9a267b63 arch1) and the runnable script is the structural fix that makes the pattern impossible to land.
```

## Files scoped to THIS implementer

**NEW:**
- `scripts/check-test-name-vs-body.py`

**MODIFIED:**
- `.claude/skills/swarm/SKILL.md` — replace Phase 4.5 check 5b (lines 458-479)
- `CLAUDE.md` — extend DoD check #1 with method-level clause

**Tooling:**
- No pbxproj changes (Python script is not part of the Xcode project)

**Self-test fixtures (optional but recommended):**
- `scripts/test_check_test_name_vs_body.py` — pytest-style tests with KNOWN-GOOD and KNOWN-BAD swift fixtures

## Files explicitly OFF-LIMITS

**Anti-scope (universal):** same as Module A.

**Off-limits per Module A and Module B ownership:** every file in their manifest lists.

## Verification criteria

1. **Script exists and is executable:**
   ```bash
   test -f scripts/check-test-name-vs-body.py
   python3 scripts/check-test-name-vs-body.py --help  # MUST not error
   ```

2. **Script catches the wall-failure shape:** Create a tmp file with the KNOWN-BAD fixture above; run the script; assert exit code 1.
   ```bash
   cat > /tmp/fake_wiring_test.swift <<'EOF'
   func testReauth_TPPReauthenticatorPath_invokesPresentationViaSafelyPresent() {
       let presenter = makePresenter()
       presenter.presentSignInModalForCurrentAccount { }
   }
   EOF
   python3 scripts/check-test-name-vs-body.py /tmp/fake_wiring_test.swift
   echo "exit=$?"  # MUST print exit=1
   rm /tmp/fake_wiring_test.swift
   ```

3. **Script accepts a good test:** KNOWN-GOOD fixture exits 0.
   ```bash
   cat > /tmp/good_wiring_test.swift <<'EOF'
   func testReauth_TPPReauthenticator_authenticateIfNeeded_drivesSpy() {
       let reauth = TPPReauthenticator()
       reauth.authenticateIfNeeded(account, usingExistingCredentials: true, authenticationCompletion: nil)
   }
   EOF
   python3 scripts/check-test-name-vs-body.py /tmp/good_wiring_test.swift
   echo "exit=$?"  # MUST print exit=0
   rm /tmp/good_wiring_test.swift
   ```

4. **Script runs cleanly against existing PalaceTests (no false positives):**
   ```bash
   python3 scripts/check-test-name-vs-body.py PalaceTests/SignInLogic/SignInModalLifecycleTests.swift \
                                              PalaceTests/SignInLogic/SignInModalPredicateTests.swift \
                                              PalaceTests/SignInLogic/SignInModalSAMLOIDCTests.swift \
                                              PalaceTests/SignInLogic/TPPReauthenticatorTests.swift
   # Expected: exit 0 against the current (un-modified-by-Module-A) state IF the existing tests are clean,
   # OR exit 1 with a FAIL specifically for the wave-3 wiring test pattern at SignInModalLifecycleTests.swift
   # (which Module A is migrating away from — that's expected).
   # The wall-failure test fixup commit (d75fd9520) already renamed the offending test, so the current
   # state should be clean.
   ```

5. **SKILL.md wired:**
   ```bash
   grep -c "python3 scripts/check-test-name-vs-body.py" .claude/skills/swarm/SKILL.md  # MUST be ≥1
   grep -c "TODO: implement check 5b mechanically" .claude/skills/swarm/SKILL.md  # MUST be 0 (the old TODO is gone)
   ```

6. **CLAUDE.md extended:**
   ```bash
   grep -c "check-test-name-vs-body.py" CLAUDE.md  # MUST be ≥1
   grep -c "Method-level extension" CLAUDE.md  # MUST be ≥1
   ```

7. **Script lint (Python):**
   ```bash
   python3 -m py_compile scripts/check-test-name-vs-body.py  # syntax check
   # If pyflakes/black/ruff are in use locally, run them.
   ```

8. **Integration test (run Module C's script against Module A's diff during Phase 4.5):**
   - Orchestrator runs this command at Phase 4.5 after integration:
     ```bash
     python3 scripts/check-test-name-vs-body.py \
       PalaceTests/SignInLogic/SignInModalLifecycleTests.swift \
       PalaceTests/SignInLogic/SignInModalPredicateTests.swift
     ```
   - Expected: exit 0 (Module A's wiring test instantiates `TPPReauthenticator` and references `AppContainer`).
   - If exit 1: BLOCK Module A; do NOT advance to Phase 5.

## Implementer prompt (one paragraph)

You are Module C implementer for `swarm_d8f11437` (wave 4). Build `scripts/check-test-name-vs-body.py` (NEW) — a Python script that parses Swift test method names embedding multi-step verbs (`Path`, `via`, `through`, `invokes`, `roundtrip`, `across`, `inProduction`, `viaX`, `Wiring`), extracts PascalCase class nouns from the names, and greps the test method body for each noun being instantiated (`<Noun>(`), called statically (`<Noun>.`), or typed (`: <Noun>`). Skip a hardcoded noise list (`XCTestCase`, `Bundle`, primitives like `String`/`Int`/`Bool`, verbs like `Path`/`Via`/`Through`). Strip string literals and comments from the body before grepping (so noun mentions in strings/comments don't count). Exit 1 if any multi-step-named test has a body that doesn't reference the embedded noun; exit 0 otherwise. Self-test with KNOWN-GOOD and KNOWN-BAD fixtures (embed them in `scripts/test_check_test_name_vs_body.py` or as `--self-test` mode). Then wire the script into `.claude/skills/swarm/SKILL.md` Phase 4.5 check 5b — REPLACE the existing TODO/manual-review block (lines 458-479) with an actual `python3 scripts/check-test-name-vs-body.py $DIFF_TESTS || exit 1` invocation. Extend `CLAUDE.md` DoD check #1 from FILE-LEVEL SUT instantiation to METHOD-LEVEL: paste the new method-level clause that points at the script. Critical self-referential rigor invariant: Module A's wiring test `testReauth_TPPReauthenticatorAuthenticateIfNeeded_drivesSpyPresenterViaAppContainerSeam` MUST be caught-or-cleared by your script in Phase 4.5. Test your script against the wall-failure example (`testPresenter_TPPReauthenticatorPath_invokesPresentationViaSafelyPresent` from wave 3 BEFORE the fixup rename) — it must FAIL that test name. Test against the wave 3 fixup name (`testPresenter_presentForCurrentAccount_publishesState_invokesDriver_clearsState_firesCompletion`) — it must PASS (no PascalCase production-class noun embedded; verbs are not nouns). NO files other than `scripts/check-test-name-vs-body.py`, `.claude/skills/swarm/SKILL.md`, `CLAUDE.md`, and optionally `scripts/test_check_test_name_vs_body.py`. Module A owns the SignInModal migration; Module B owns the AppContainer seam — DO NOT modify their files.
````

---

