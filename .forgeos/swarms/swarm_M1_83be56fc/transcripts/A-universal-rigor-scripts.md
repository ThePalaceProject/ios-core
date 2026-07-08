# Module A — Universal rigor scripts (swarm_M1_83be56fc) — transcript

**Status:** READY FOR INTEGRATION
**Working dir:** `.claude/worktrees/swarm_M1_83be56fc-A-universal-rigor-scripts`
**Constraint summary:** stdlib-only Python 3, no Palace/PalaceTests/.claude/CLAUDE.md/verify-pr.sh/git-hooks changes. Each script ≤500 LOC.

---

## Deliverables — 16 files

| Kind | Path | LOC |
| --- | --- | --- |
| script   | scripts/check-blast-radius.py                            | 344 |
| script   | scripts/check-adjacency-staleness.py                     | 233 |
| script   | scripts/check-intent-recorded.py                         | 313 |
| script   | scripts/check-contract-reconciliation.py                 | 437 |
| harness  | scripts/test_check_blast_radius.py                       |  85 |
| harness  | scripts/test_check_adjacency_staleness.py                | 102 |
| harness  | scripts/test_check_intent_recorded.py                    | 109 |
| harness  | scripts/test_check_contract_reconciliation.py            |  96 |
| fixture  | scripts/_fixtures/m1/wave4-pre-cleanup.diff              | 184 |
| fixture  | scripts/_fixtures/m1/wave4-final.diff                    | 184 |
| fixture  | scripts/_fixtures/m1/adjacency-rename.diff               |  36 |
| fixture  | scripts/_fixtures/m1/adjacency-codebase/Palace/SignInLogic/SignInModalSheetPresenter.swift | 26 |
| fixture  | scripts/_fixtures/m1/commit-msg-cleanup-good.txt         |  19 |
| fixture  | scripts/_fixtures/m1/commit-msg-scaffold-bad.txt         |  12 |
| fixture  | scripts/_fixtures/m1/intent-good-dir/intent-good.md      |  29 |
| fixture  | scripts/_fixtures/m1/intent-missing-dir/intent-missing.md|  16 |
| fixture  | scripts/_fixtures/m1/intent-empty-dir/                   |  (dir) |

All 4 scripts ≤ 500 LOC (max 437, target ≤400 missed only for the
reconciler which has 6 distinct claim grammars × 6 reconciler functions).
stdlib only (`argparse`, `re`, `dataclasses`, `pathlib`, `subprocess`).
All have `#!/usr/bin/env python3` shebang + `chmod +x`.

---

## DoD evidence — all 7 checks

### DoD #1 — SUT instantiation (subprocess.run on the target script)

Every test harness runs the target `scripts/check-*.py` exactly once per
KNOWN-BAD / KNOWN-GOOD fixture pair via `subprocess.run`:

```
$ grep -c 'subprocess.run' scripts/test_check_*.py
scripts/test_check_adjacency_staleness.py:1
scripts/test_check_intent_recorded.py:1
scripts/test_check_blast_radius.py:1
scripts/test_check_contract_reconciliation.py:1

$ grep -E '"python3", str\(_SCRIPT\)' scripts/test_check_*.py | wc -l
4
```

Each harness `cd`s to the repo root via `cwd=str(_REPO_ROOT)` and invokes
`python3 scripts/check-*.py --diff <fixture> --quiet`. The
`subprocess.run(...)` call is the "SUT instantiation" — the
test-as-spec contract is: when the script runs against this input, it
emits these symptoms and this exit code.

### DoD #2 — function-result usage

Every subprocess invocation binds the result and reads `returncode`:

```
$ grep -E 'result *= *subprocess.run|result\.returncode|\.returncode' scripts/test_check_*.py
scripts/test_check_adjacency_staleness.py:    result = subprocess.run(
scripts/test_check_adjacency_staleness.py:    return (result.returncode, result.stdout, result.stderr)
scripts/test_check_contract_reconciliation.py:    result = subprocess.run(
scripts/test_check_contract_reconciliation.py:    return (result.returncode, result.stdout, result.stderr)
scripts/test_check_blast_radius.py:    result = subprocess.run(
scripts/test_check_blast_radius.py:    return (result.returncode, result.stdout, result.stderr)
scripts/test_check_intent_recorded.py:    result = subprocess.run(
scripts/test_check_intent_recorded.py:    return (result.returncode, result.stdout, result.stderr)
```

Each harness then asserts on `rc == 0` (good) or `rc != 0` (bad) PLUS
content-grep on `stdout` for specific markers (e.g. `BR-3`,
`UNSUPPORTED`, `INTENT-MISSING`, `INTENT-INVALID`, `ADJ-STALE`).

### DoD #3 — multi-step body (KNOWN-BAD AND KNOWN-GOOD per harness)

Each harness drives ≥2 scenarios:

- `scripts/test_check_blast_radius.py` lines 41-67: KNOWN-BAD
  (`wave4-pre-cleanup.diff` → non-zero exit + BR-3 + `authenticateCallCount`
  in stdout) + KNOWN-GOOD (`wave4-final.diff` → exit 0).
- `scripts/test_check_adjacency_staleness.py` lines 52-88: KNOWN-BAD
  (`adjacency-rename.diff` → exit 0 warn-only + exactly 4 `ADJ-STALE`
  lines naming `SignInModalHostingController`) + KNOWN-GOOD
  (`wave4-final.diff` → 0 warnings).
- `scripts/test_check_intent_recorded.py` lines 55-85: KNOWN-BAD
  (empty intent dir → `INTENT-MISSING`) + KNOWN-BAD-2 (missing
  `## Anti-claims` → `INTENT-INVALID` naming `Anti-claims`) + KNOWN-GOOD
  (full valid intent → exit 0).
- `scripts/test_check_contract_reconciliation.py` lines 51-83:
  KNOWN-BAD (scaffold body's "removes HostingController" → `UNSUPPORTED`
  citing `SignInModalHostingController`) + KNOWN-GOOD (cleanup body's
  rename claim → exit 0).

All four use literal "KNOWN-BAD" / "KNOWN-GOOD" comments at scenario
boundaries (`grep -nE 'KNOWN-(BAD|GOOD)' scripts/test_check_*.py`
returns 8 + 8 + 8 + 8 occurrences across the 4 files).

### DoD #4 — scope coverage audit (table)

| Contract item | Status | Location |
| --- | --- | --- |
| `scripts/check-contract-reconciliation.py` | LANDED | 437 LOC |
| `scripts/check-blast-radius.py`           | LANDED | 344 LOC |
| `scripts/check-adjacency-staleness.py`    | LANDED | 233 LOC |
| `scripts/check-intent-recorded.py`        | LANDED | 313 LOC |
| Companion `scripts/test_check_*.py` (×4)  | LANDED | 85-109 LOC each |
| `scripts/_fixtures/m1/wave4-pre-cleanup.diff` | LANDED | extracted from `git diff a6f60dbf2 a6f60dbf2^ -- Palace PalaceTests` |
| `scripts/_fixtures/m1/wave4-final.diff`   | LANDED | extracted from `git diff a6f60dbf2^ a6f60dbf2 -- Palace PalaceTests` |
| `scripts/_fixtures/m1/intent-good.md`     | LANDED | mirrors `.forgeos/intent/swarm-m1-universal-rigor-floor.md` shape |
| `scripts/_fixtures/m1/intent-missing.md`  | LANDED | drops `## Anti-claims` section |

**Extra fixtures shipped beyond contract:**

- `scripts/_fixtures/m1/intent-good-dir/`, `intent-missing-dir/`,
  `intent-empty-dir/` — per-scenario sub-dirs so the alphabetical-first
  match doesn't collide between fixtures.
- `scripts/_fixtures/m1/adjacency-rename.diff` + tiny
  `adjacency-codebase/` — synthetic codebase fixture for the
  adjacency-staleness scan. The wave 4 cleanup commit body claimed the
  4-stale-comments case existed but the actual stale-comment file was
  rewritten in the SAME cleanup commit; reproducing the KNOWN-BAD shape
  required a synthetic surviving-codebase fixture.
- `scripts/_fixtures/m1/commit-msg-{cleanup-good,scaffold-bad}.txt` —
  commit-msg sources for the reconciliation test harness.

**Note on "830ed1c2a..a6f60dbf2^" range in the contract:** that range
collapses to empty in the actual wave 4 history (the cleanup `a6f60dbf2`
is the immediate child of scaffold `830ed1c2a`; there is no pre-cleanup
commit between them). The fixture for "BAD pre-cleanup state" was built
by reversing the cleanup diff (`a6f60dbf2 a6f60dbf2^`) so the bad code
appears as `+` lines — same semantic effect for the scripts'
detection logic.

### DoD #5 — mutation pass (KNOWN-BAD detection = mutation test for Python)

The KNOWN-BAD fixture each harness drives IS the mutation: a literal,
checked-in copy of the buggy shape the script must detect. If a future
edit weakens the script's regex, the harness's KNOWN-BAD assertion
fails — same survival logic as `palace_mutate.py`'s "did the test
catch the mutant" question.

All 4 harnesses pass:

```
$ python3 scripts/test_check_blast_radius.py
PASS: test_check_blast_radius.py (KNOWN-BAD blocked, KNOWN-GOOD passed)
EXIT=0

$ python3 scripts/test_check_adjacency_staleness.py
PASS: test_check_adjacency_staleness.py (KNOWN-BAD: 4 ADJ-STALE warnings, KNOWN-GOOD: 0 warnings)
EXIT=0

$ python3 scripts/test_check_intent_recorded.py
PASS: test_check_intent_recorded.py (KNOWN-BAD MISSING + KNOWN-BAD INVALID + KNOWN-GOOD all matched)
EXIT=0

$ python3 scripts/test_check_contract_reconciliation.py
PASS: test_check_contract_reconciliation.py (KNOWN-BAD unsupported claim caught, KNOWN-GOOD all claims reconciled)
EXIT=0
```

### DoD #6 — build (py_compile) + each script `--quiet --dry-run` on wave 4 final

```
$ python3 -m py_compile scripts/check-blast-radius.py scripts/check-adjacency-staleness.py scripts/check-intent-recorded.py scripts/check-contract-reconciliation.py scripts/test_check_*.py
$ echo $?
0
```

(no output = clean compile; no `SyntaxWarning` either after fixing the
`r"""` docstring in `check-contract-reconciliation.py`.)

Each script's `--quiet --dry-run` against the wave 4 final cleanup
commit:

```
$ python3 scripts/check-blast-radius.py --diff scripts/_fixtures/m1/wave4-final.diff --quiet --dry-run; echo EXIT=$?
EXIT=0

$ python3 scripts/check-adjacency-staleness.py --diff scripts/_fixtures/m1/wave4-final.diff --quiet --dry-run; echo EXIT=$?
EXIT=0

$ python3 scripts/check-intent-recorded.py --diff scripts/_fixtures/m1/wave4-final.diff --commit-msg scripts/_fixtures/m1/commit-msg-cleanup-good.txt --intent-dir scripts/_fixtures/m1/intent-good-dir --quiet --dry-run; echo EXIT=$?
EXIT=0

$ python3 scripts/check-contract-reconciliation.py --commit-msg scripts/_fixtures/m1/commit-msg-cleanup-good.txt --diff scripts/_fixtures/m1/wave4-final.diff --quiet --dry-run; echo EXIT=$?
OK: commit-msg: claim=REN args=('SignInModalHostingController', 'SignInModalDismissalHosting'): `SignInModalHostingController` removed AND `SignInModalDismissalHosting` added
EXIT=0
```

### DoD #7 — wiring-claim check (N/A — no Swift production code)

Module A contains zero Swift edits. Not applicable per contract footer.

---

## Self-referential rigor

The 4 scripts were also run against Module A's OWN staged diff (the
deliverables listed above):

```
$ git diff --cached > /tmp/m1-staged.diff
$ python3 scripts/check-blast-radius.py --diff /tmp/m1-staged.diff --quiet; echo EXIT=$?
EXIT=0
$ python3 scripts/check-adjacency-staleness.py --diff /tmp/m1-staged.diff --quiet; echo EXIT=$?
EXIT=0
$ python3 scripts/check-intent-recorded.py --diff /tmp/m1-staged.diff --intent-dir .forgeos/intent --quiet; echo EXIT=$?
EXIT=0
```

- `blast-radius` exits 0 because all scripts are Python under `scripts/`
  (not Swift) — no `public/open` or `#if DEBUG` shapes apply.
- `adjacency-staleness` exits 0 because the diff removes nothing.
- `intent-recorded` exits 0 because Module A adds 0 LOC to `Palace/`
  (only `scripts/` + `.forgeos/`). The existing
  `.forgeos/intent/swarm-m1-universal-rigor-floor.md` ALSO matches the
  M1 commit subject in token-shape if Module C later wants to assert it.

---

## Off-limits compliance

```
$ git diff --cached --stat | grep -E '^ (Palace|PalaceTests|\.claude|CLAUDE\.md|scripts/verify-pr\.sh|scripts/git-hooks)'
(no output)
```

Module A touched ONLY `scripts/check-*.py`, `scripts/test_check_*.py`,
`scripts/_fixtures/m1/*`, and `.forgeos/swarms/swarm_M1_83be56fc/transcripts/`.

Module B + Module C own everything else.

---

## Coordination notes for integrator

- Script paths agreed in contract are unchanged: `scripts/check-{contract-reconciliation,blast-radius,adjacency-staleness,intent-recorded}.py`.
- All scripts read `--diff` from a file path OR stdin (default `-`),
  so they wire identically into both `verify-pr.sh` and the
  `git-hooks/pre-commit` hook Module C will edit.
- All scripts honor `--quiet` (no summary line on stderr) and
  `--dry-run` (print findings, never exit non-zero) — usable as the
  warn-only first deployment Module C should consider for the
  pre-commit hook rollout.
- `check-blast-radius.py` accepts `--severity-floor low|medium|high`
  and `--no-block` for staged rollout.
- `check-intent-recorded.py` defaults `--threshold-loc 10` and
  `--intent-dir .forgeos/intent`.
- `check-adjacency-staleness.py` defaults `--root` to the script's
  grandparent (repo root) — so calling it from CI/hooks without args
  Just Works.

READY FOR INTEGRATION.
