# Module C — Runnable-grep rigor escalation — TRANSCRIPT

**Status:** READY FOR INTEGRATION
**Module:** C-runnable-grep-rigor-escalation (STANDARD-rigor — scripts + docs only)
**Worktree:** `.claude/worktrees/swarm_d8f11437-C-runnable-grep-rigor-escalation`

## Deliverables

1. **NEW:** `scripts/check-test-name-vs-body.py` — Python 3 script (stdlib only,
   executable, shebanged) that detects fake-wiring tests where the test method
   name embeds a multi-step verb (`Path`, `via`, `through`, `invokes`,
   `roundtrip`, `across`, `inProduction`, `viaX`, `Wiring`) PLUS a PascalCase
   production-class noun, but whose body never references that noun.

2. **MODIFIED:** `.claude/skills/swarm/SKILL.md` Phase 4.5 check 5b — replaced
   the "WARNING + TODO + manual review" stub (lines 458-479) with a real
   `python3 scripts/check-test-name-vs-body.py` invocation that exits non-zero
   on failure and BLOCKs Phase 4.5.

3. **MODIFIED:** `CLAUDE.md` DoD check #1 — extended from file-level
   SUT-instantiation to a method-level sub-clause that references the new
   script. Quotes the wall-failure entry (cs_9a267b63) and documents the
   "Method-level extension (added wave 4 / cs_9a267b63 escalation)" requirement.

## Definition-of-Done evidence (7 checks)

### Check 1 — SUT instantiation check

N/A. This module does not add Swift test files. The new script itself does
not have a Swift SUT. Method-level check from the new sub-clause IS the
deliverable, not the artifact-under-test.

### Check 2 — Function-result usage check

N/A. No new production-code function calls introduced. Module C is process
tooling only.

### Check 3 — Multi-step test body check

N/A. No Swift test files added. The Python script's CLI is invoked via
shell wrapper in SKILL.md; SKILL.md is documentation + bash, not a Swift
test.

### Check 4 — Scope coverage audit

Original contract deliverables (3):

| # | Deliverable                                                              | In diff?                                                       |
| - | ------------------------------------------------------------------------ | -------------------------------------------------------------- |
| 1 | NEW `scripts/check-test-name-vs-body.py` (Python script)                 | YES — `scripts/check-test-name-vs-body.py` (431 LOC, stdlib)   |
| 2 | Wire script into `.claude/skills/swarm/SKILL.md` Phase 4.5 check 5b       | YES — replaces WARNING stub with `python3` invocation + BLOCK  |
| 3 | Extend `CLAUDE.md` DoD check #1 with method-level sub-clause              | YES — adds "Method-level extension" block referencing script   |

100% scope coverage. No deferred items. No partial-ship.

### Check 5 — Mutation pass

N/A. No critical-path Swift production files modified (Module C touches
zero `Palace/*.swift` files). The script itself is process tooling, not
critical-path runtime code.

### Check 6 — Build + verify-pr

- **`xcodebuild build`:** N/A — Module C does not touch any Swift / pbxproj /
  build inputs.
- **`python3 -m py_compile scripts/check-test-name-vs-body.py`:** PASS
  (exit 0).

```text
$ python3 -m py_compile scripts/check-test-name-vs-body.py && echo "exit=0 OK"
exit=0 OK
```

- **`python3 scripts/check-test-name-vs-body.py --help`:** PASS (does not error).

### Check 7 — Multi-step / wiring-claim check (v2) / Self-verification

The script itself IS the v2 mechanism. Self-verification of the script:

**(a) No false positives on existing renamed tests:**

```text
$ python3 scripts/check-test-name-vs-body.py \
    PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift \
    PalaceTests/SignInLogic/SignInModalLifecycleTests.swift
OK: 2 file(s) checked, 0 fake-wiring tests found.
exit=0
```

The wave-3 fixup test `testPresenter_presentForCurrentAccount_publishesState_invokesDriver_clearsState_firesCompletion`
is NOT flagged (correct — it has no embedded PascalCase production-class
noun; the renamed version describes the behavioural lifecycle).

**(b) True positive on the original wave-3 BAD test name (in-repo round-trip):**

Temporarily renamed the wave-3 fixup test back to its original
`testPresenter_TPPReauthenticatorPath_invokesPresentationViaSafelyPresent`
form to verify the script catches it, then reverted before declaring READY.

```text
$ python3 scripts/check-test-name-vs-body.py PalaceTests/SignInLogic/SignInModalLifecycleTests.swift
1 fake-wiring test(s) found across 1 file(s).
Wall-failure shape: .forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md
Action: either instantiate the embedded production-class noun in the test body,
        or rename the test to not embed it (only the name promises the wiring).
PalaceTests/SignInLogic/SignInModalLifecycleTests.swift:227: \
  testPresenter_TPPReauthenticatorPath_invokesPresentationViaSafelyPresent: \
  claims 'TPPReauthenticatorPath' but body has no reference
exit=1
```

Then reverted. Confirmed clean post-revert:

```text
$ git diff PalaceTests/
[empty]
$ python3 scripts/check-test-name-vs-body.py PalaceTests/SignInLogic/SignInModalLifecycleTests.swift
OK: 1 file(s) checked, 0 fake-wiring tests found.
exit=0
```

**(c) Full PalaceTests sweep — zero false positives:**

```text
$ python3 scripts/check-test-name-vs-body.py $(find PalaceTests -name "*Tests.swift" -type f)
OK: 473 file(s) checked, 0 fake-wiring tests found.
exit=0
```

473 test files scanned. Zero false positives. The conservative noun-extraction
heuristic (Palace acronym prefix OR recognized class-name suffix, with
leading-verb / leading-adjective filter, and file-level SUT exclusion) catches
the wall-failure shape without flagging legitimate behavioural test names like:

- `testNavigationCoordinator_*` (excluded — file SUT)
- `testBookCreationViaDictionary` (not class-like; `BookCreation` is descriptive)
- `testLoad_RoundTripsThroughOPDS2CatalogsFeedDecoder` (leading verb `Round`)
- `testCompletionBridge_thumbnail_invokesOnMainThread` (`Bridge` removed from suffixes)
- `testProductionAppContainer_authCoordinator_isSingletonAcrossCalls` (leading adjective `Production`)
- `testURLHashValue_isNotStableAcrossComputations` (no `TPP`/`NYPL` prefix, no class suffix)

**(d) KNOWN-BAD / KNOWN-GOOD fixtures:**

```text
$ # KNOWN-BAD: fake wiring test
$ python3 scripts/check-test-name-vs-body.py /tmp/fake_wiring_test.swift
1 fake-wiring test(s) found across 1 file(s).
/tmp/fake_wiring_test.swift:3: testReauth_TPPReauthenticatorPath_invokesPresentationViaSafelyPresent: claims 'TPPReauthenticatorPath' but body has no reference
exit=1  # ✓ correct

$ # KNOWN-GOOD: instantiates the embedded noun
$ python3 scripts/check-test-name-vs-body.py /tmp/good_wiring_test.swift
OK: 1 file(s) checked, 0 fake-wiring tests found.
exit=0  # ✓ correct
```

## Files touched

| Path                                              | Status   | Notes                                            |
| ------------------------------------------------- | -------- | ------------------------------------------------ |
| `scripts/check-test-name-vs-body.py`              | NEW (?)  | 431 LOC, Python 3 stdlib only, `chmod +x`        |
| `.claude/skills/swarm/SKILL.md`                   | MODIFIED | Phase 4.5 check 5b: stub → real `python3` invoke |
| `CLAUDE.md`                                       | MODIFIED | DoD #1 method-level sub-clause                   |
| `.forgeos/swarms/swarm_d8f11437/transcripts/`     | NEW      | This file                                        |

Zero `Palace/*.swift` files touched (correct — Modules A + B own production).
Zero `PalaceTests/*.swift` files touched (the in-repo round-trip test was
reverted before reporting; `git diff PalaceTests/` is empty).

## Algorithm summary (for reviewer)

1. **Read each Swift test file** under `PalaceTests/`.
2. **Strip strings + comments** so the noun-grep doesn't match noun mentions
   inside string literals or `///` docstrings.
3. **Find every `func test*(...)` declaration** via regex; brace-match to get
   the method body.
4. **Filter to multi-step-named tests** (name contains a case-insensitive
   match for `path`, `via`, `through`, `invokes`, `roundtrip`, `across`,
   `inproduction`, `viax`, or `wiring`).
5. **Extract candidate PascalCase nouns** from the test name:
   - Strip leading `test`.
   - Split on underscores; for uppercase-led segments, yield the segment +
     peeled forms (strip trailing NOISE words) + individual CamelCase words.
   - For verb-led segments, yield only internal CamelCase tokens.
   - Filter through `NOISE_NOUNS` (~150 generic words / framework types).
   - Filter through `looks_class_like` (must start with `TPP`/`NYPL` acronym
     prefix OR end with a class-name suffix from `CLASS_NAME_SUFFIXES`;
     reject leading-verb / leading-adjective tokens).
6. **Drop file-level SUT names** (derived from `<SUT>Tests.swift` filename;
   handles common multi-test suffix conventions like `Lifecycle`, `Predicate`,
   `Wiring`, `Extended`).
7. **Body-grep each candidate noun:** match `<Noun>(` (instantiation),
   `<Noun>.` (static call), or type-annotation patterns. Also accept the
   camelCase property form (`audiobookSession` for `AudiobookSession`).
8. **Report failures** in greppable format. Exit 1 if any test fails; 0
   otherwise.

## Wave 4 self-referential rigor (the wall heals)

When Module A integrates, the orchestrator's Phase 4.5 step will run:

```bash
python3 scripts/check-test-name-vs-body.py \
  PalaceTests/SignInLogic/SignInModalLifecycleTests.swift \
  PalaceTests/SignInLogic/TPPReauthenticatorTests.swift \
  PalaceTests/SignInLogic/SignInModalPredicateTests.swift
```

Module A's new wiring test
`testReauth_TPPReauthenticatorAuthenticateIfNeeded_drivesSpyPresenterViaAppContainerSeam`
embeds `TPPReauthenticator` and `AppContainer`. The body MUST call
`TPPReauthenticator(` AND reference `AppContainer.production()` — otherwise
the script BLOCKs Module A at Phase 4.5. If Module A ships a fake-wiring
test of the cs_9a267b63 shape, Module C's script (this module) catches it
mechanically rather than relying on a reviewer.

This is the runnable-grep escalation working as designed: documentation-only
fixes (DoD check #7) failed to prevent recurrence between waves 2 → 3; the
script is the structural fix that makes the pattern impossible to land.
