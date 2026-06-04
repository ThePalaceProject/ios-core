---
name: verify-pr-quick-gate-fixes
created: 2026-06-04
author: claude-opus-4-8
---

## Summary

Two robustness fixes surfaced by running `scripts/verify-pr.sh --quick` on the
PP-917 branch: the script dies with "DIFF_BASELINE: unbound variable" under
`set -u` whenever the unit-test pass condition is false and `--diff-baseline`
was not passed, masking the real test verdict. Also record intent files for
the hook-stage relocation commit and this one so the intent_recorded gate
reconciles against the branch HEAD.

## Claims

- adds `DIFF_BASELINE=false` default to `scripts/verify-pr.sh` next to the other flag defaults
- adds intent file `.forgeos/intent/fix-hooks-m1-message-gates-commit-msg-stage.md` for the prior hook-stage commit
- adds intent file `.forgeos/intent/verify-pr-quick-gate-fixes.md` (this file)

## Anti-claims

- does NOT change any verify-pr gate logic, thresholds, or the checks it runs
- does NOT change the hardcoded SIM_ID fallback (machine-local concern; `HARNESS_SESSION_SIM_UDID` env override exists)
- does NOT touch any Palace/ production code

## Files in scope

- scripts/verify-pr.sh
- .forgeos/intent/fix-hooks-m1-message-gates-commit-msg-stage.md (NEW)
- .forgeos/intent/verify-pr-quick-gate-fixes.md (NEW)
