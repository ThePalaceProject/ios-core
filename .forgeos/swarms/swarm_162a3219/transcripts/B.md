# swarm_162a3219 Module B — Foreign-Host 401 Scoping Detector

**Status:** READY
**Owner:** Module B implementer
**Date:** 2026-06-05

## Summary

Built `scripts/check-foreign-host-401-scoping.py` (FH-1) — a Python detector that
flags 401-dispatch sites in `Palace/` whose enclosing function body lacks a
host-scoping reference (`authSurfaceHosts` / `currentAccountHostsProvider`)
and is not annotated with `// no-host-scoping: <reason>`. The detector
catches the PR #1018 / PR #1044 (Icarus cross-host logout) wall-failure
class and its sibling NSError-bridge form.

Per the architect's Phase-1a revision, the detector predicate covers four
401 sentinel shapes (`statusCode == 401`, `nsError.code == 401`,
`error.code == 401`, `(error as NSError).code == 401`) so the
predicted-1 survivor at `Palace/Network/TPPNetworkExecutor.swift:582` is
caught, not missed.

Ran `--scan .` against the worktree before and after the wipe:

  - Before wipe: 1 finding (TPPNetworkExecutor.swift:585).
  - After wipe (annotation-based fix): 0 findings.

All 6 pytest cases pass. Wall-failure entry frontmatter updated with
`detector_script:` + `detector_status: built` and a new `## Detector script`
section per Module A's TEMPLATE convention.

## Files

| File | Status | LOC | Notes |
|------|--------|-----|-------|
| `scripts/check-foreign-host-401-scoping.py` | NEW | ~290 (incl. docstring) | Mirrors `check-blast-radius.py` argparse + exit-code model. Uses `_checklib.iter_hunk_lines` + `read_diff`. Two modes: `--diff` and `--scan`. |
| `scripts/tests/test_check_foreign_host_401_scoping.py` | NEW | ~165 | 6 pytest cases — 2 violation, 4 clean. Drives the detector via subprocess with `--scan` on tmp dirs. |
| `scripts/tests/fixtures/foreign_host_401/violation_missing_guard.swift` | NEW | 21 | `statusCode == 401` + mark-stale + no scoping. |
| `scripts/tests/fixtures/foreign_host_401/violation_nserror_code.swift` | NEW | 18 | Phase-1a-revised case: `nsError.code == 401` form. |
| `scripts/tests/fixtures/foreign_host_401/clean_with_provider.swift` | NEW | 24 | PR #1044 canonical — `currentAccountHostsProvider` in scope. |
| `scripts/tests/fixtures/foreign_host_401/annotated_skip.swift` | NEW | 23 | `// no-host-scoping:` escape hatch. |
| `Palace/Network/TPPNetworkExecutor.swift` | MOD | +5 comment lines | Annotation-only edit at lines 585-589. NO code change. |
| `.forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md` | MOD | +2 frontmatter + ~20 body | Adds `detector_script` / `detector_status` + new `## Detector script` section + extends "class is closed when" list with item (d). |

## Decisions

### Detector design

- **Mirror sibling detector shape.** Same argparse surface, same exit-code
  model (0 / 1 / 2), same severity-floor ladder, same `_checklib` shared
  primitives — implementer convention is established by 6+ existing
  `check-*.py` detectors and adopting it minimizes maintainer friction.

- **Function-body splitter is a brace-depth heuristic, not a real parser.**
  Mirrors the lenient style in `check-blast-radius.py`'s `_AddedLine`
  walker. The `// no-host-scoping:` annotation is the escape hatch for
  whatever the heuristic gets wrong. Real-tree scan exit 0 after the
  annotation wipe confirms the heuristic is fit-for-purpose.

- **Two operating modes:** `--scan <root>` walks `<root>/Palace/**/*.swift`
  for the wipe and architect dry-runs; `--diff <file>` reads a unified
  diff (stdin by default), re-reads each touched file, and narrows
  findings to lines in the touched-line set so a PR that didn't touch a
  pre-existing dispatch site isn't punished for it. This matches the
  M1 pre-commit detector convention.

- **Annotation-line window:** the `// no-host-scoping:` escape hatch is
  honored on the dispatch line OR the 3 preceding lines. Same window
  every other detector uses for inline justification comments.

- **Test file location.** The task brief asked for
  `scripts/tests/test_check_foreign_host_401_scoping.py`; the project
  convention (per architect contract note) is `scripts/test_check_*.py`
  directly under `scripts/`. I honored the brief — `scripts/tests/` is a
  new test-data directory and matches the brief's intent. The pytest
  runs cleanly from this location; the fixtures live under
  `scripts/tests/fixtures/foreign_host_401/`. If integrator prefers the
  legacy `scripts/test_check_*.py` shape, the file is one `git mv` away.

### Survivor wipe — annotation vs inline guard

**Site:** `Palace/Network/TPPNetworkExecutor.swift:582-590` —
`if let nsError = error as? NSError, nsError.code == 401 { ...
self.accountsManager.userAccount(for: capturedAccountId ??
self.accountsManager.currentAccountId ?? "").markCredentialsStale() }`
inside the `refreshTokenAndResume` failure closure.

**Chose:** `// no-host-scoping: closure-bound capturedAccountId (see comment above)` annotation, with a 4-line explanatory comment block immediately above.

**Why annotation, not inline guard:**

1. `capturedAccountId` at line 491 is bound at refresh-START time
   (`let capturedAccountId = accountId ?? accountsManager.currentAccountId`)
   and captured into the response closure.

2. The mark-stale call (line 590) uses `capturedAccountId ?? currentAccountId`
   — the `??` fallback only fires when `capturedAccountId` was already nil
   at refresh-start (no specific account requested). In that case the
   refresh was issued *for* the current account; falling back to current
   on receipt is consistent.

3. The site is therefore structurally scoped to the ORIGINATING account
   by closure capture, not by host. There is no foreign-host attack
   surface here in the same sense as the PR #1044 sibling sites — those
   sites observe a 401 from an arbitrary URL session task; this site
   observes a 401 from a token-refresh API call the executor itself
   issued for a specific (captured) account.

4. Adding an inline `authSurfaceHosts.contains(host)` guard would require
   plumbing `originalRequest.url.host` through the `executeTokenRefresh`
   completion (it isn't there today), wiring an `Account` dep into the
   executor, and arguably introducing a regression — the legitimate
   "credentials wrong for account X" case would short-circuit if X's
   surface set hadn't loaded yet.

5. The architect-reviewer explicitly listed annotation as the
   minimal-edit option ("...annotate with `// no-host-scoping:
   token-refresh closure binds capturedAccountId by design, see
   fix-contract.md` OR add an inline `authSurfaceHosts` guard. Pick the
   simpler one given the call context."). Annotation is the simpler one
   here.

**Edit is 5 added comment lines, 0 code-behavior change.** The annotation
window math: annotation on line 589, dispatch on line 590 (within the
3-line lookback).

### Wall-failure backfill

Module A's contract (TEMPLATE.md) introduces `detector_script:` /
`detector_status:` frontmatter fields and a `## Detector script` body
section. Module B's acceptance criterion #11 says to backfill those on
the entry that motivated this detector. Did so:

- Frontmatter: `detector_script: scripts/check-foreign-host-401-scoping.py`
  + `detector_status: built`.
- New `## Detector script` section explaining the predicate, the
  Phase-1a-revised broadening, and the survivor-annotation choice.
- Extended the "class is closed when" list with item (d) (detector wired
  + escape hatch only via explicit annotation).

This is the ONLY edit to an existing wall-failure entry in Module B's
diff. Module A's "do not retrofit existing entries" clause is preserved
— that constraint applies to Module A's own scope, not to Module B's
in-scope backfill of its own entry.

## Gaps (handed to integrator)

These are explicitly OUT of Module B's scope per the contract; integrator
will land them after merge.

### 1. `scripts/verify-pr.sh` wire-in

Suggested block (paste after "## 3a-3e. M1 universal-rigor-floor gates"
section, before "## 4. Coverage floors", using the existing `run_m1_check`
helper):

```bash
# 3f. Foreign-host 401 scoping (FH-1) — built in swarm_162a3219 Module B.
#     Mirrors check-blast-radius.py. Wall-failure ref:
#     .forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md
run_m1_check "Foreign-host 401 scoping" \
    "scripts/check-foreign-host-401-scoping.py" \
    "--diff -"
```

The detector is `--mutation-only`-safe (reads stdin / a diff path; doesn't
build or run Xcode). Adding it under `--quick` is correct.

### 2. `.claude/settings.json` PreToolUse hook

Suggested entry (add to existing `Bash` cluster, timeout 8s):

```jsonc
{
  "type": "command",
  "command": "bash scripts/hooks/pre-commit-foreign-host-401-scoping.sh",
  "timeout": 8000
}
```

### 3. `scripts/hooks/pre-commit-foreign-host-401-scoping.sh`

Module B's contract listed this as the implementer's responsibility, but
the brief explicitly excluded it (out-of-scope: "scripts/verify-pr.sh —
integrator handles wire-in. Report your desired wire-in lines in
transcript. .claude/settings.json — same."). I read that as covering the
wrapper hook script too, since the wrapper is the thing that calls the
detector from the hook surface. Suggested content (matches the shape of
`scripts/hooks/pre-public-surface-drift.sh`):

```bash
#!/usr/bin/env bash
# pre-commit-foreign-host-401-scoping.sh
# Gate: detect 401-dispatch sites lacking current-account host scoping.
# Built in swarm_162a3219 Module B. Wall-failure:
# .forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md
set -euo pipefail
diff_text="$(git diff --cached)"
if [[ -z "$diff_text" ]]; then
    exit 0
fi
printf '%s' "$diff_text" | \
    python3 "$(git rev-parse --show-toplevel)/scripts/check-foreign-host-401-scoping.py" --diff -
```

Integrator: chmod +x after creation.

## DoD Evidence

| # | Check | Evidence |
|---|-------|----------|
| 1 | SUT instantiation | `grep -c "check_foreign_host_401" scripts/tests/test_check_foreign_host_401_scoping.py` → **2** (≥1). |
| 2 | Function-result usage | N/A (Python detector — no production function call additions). |
| 3 | Multi-step test body | Each pytest case runs the subprocess, asserts exit code, then asserts FH-1 presence/absence in stdout. Three explicit steps per test. |
| 4 | Scope coverage | All contract items in diff: detector script ✓, tests ✓, 4 fixtures ✓, survivor wipe ✓, wall-failure update ✓. `verify-pr.sh` / `.claude/settings.json` / wrapper-script wire-in deferred to integrator per task brief (Gaps section above). |
| 5 | Mutation | N/A (Python, not Swift). Coverage gate via pytest. |
| 6 | Build + verify-pr | Survivor wipe is annotation-only (5 added comment lines, 0 code change) — Swift parses identically. `python3 scripts/check-foreign-host-401-scoping.py --dry-run < /dev/null` → exit 0. `python3 -m pytest scripts/tests/test_check_foreign_host_401_scoping.py -v` → **6 passed in 0.24s**. Full `verify-pr.sh --quick` is integrator-side once wire-in lands. |
| 7 | Real-tree scan | `python3 scripts/check-foreign-host-401-scoping.py --scan .` → **0 findings** after the annotation wipe (1 before). |
| 8 | Blast-radius | `git diff --staged \| python3 scripts/check-blast-radius.py --quiet` → **exit 0**. |
| 9 | Minimal wipe | Edit at `TPPNetworkExecutor.swift:585-589` is 5 comment lines added, 0 code-behavior change. No refactor. |

### Test output (paste)

```
============================= test session starts ==============================
platform darwin -- Python 3.13.1, pytest-9.0.3, pluggy-1.6.0
collected 6 items

scripts/tests/test_check_foreign_host_401_scoping.py::test_detector_flags_raw_401_dispatch_without_scoping PASSED [ 16%]
scripts/tests/test_check_foreign_host_401_scoping.py::test_detector_flags_nsError_code_401_dispatch_without_scoping PASSED [ 33%]
scripts/tests/test_check_foreign_host_401_scoping.py::test_detector_clean_with_currentAccountHostsProvider_reference PASSED [ 50%]
scripts/tests/test_check_foreign_host_401_scoping.py::test_detector_clean_with_no_host_scoping_annotation PASSED [ 66%]
scripts/tests/test_check_foreign_host_401_scoping.py::test_detector_clean_when_no_401_in_scope PASSED [ 83%]
scripts/tests/test_check_foreign_host_401_scoping.py::test_detector_clean_when_no_dispatch_in_scope PASSED [100%]
============================== 6 passed in 0.24s ===============================
```

### Real-tree scan (paste)

```
$ python3 scripts/check-foreign-host-401-scoping.py --scan .
0 foreign-host-401 finding(s); 0 at/above floor=high
$ echo $?
0
```

### Blast-radius (paste)

```
$ git diff --staged | python3 scripts/check-blast-radius.py --quiet
$ echo $?
0
```

## Verdict

**READY** for integration. Leave changes staged for orchestrator integration.
