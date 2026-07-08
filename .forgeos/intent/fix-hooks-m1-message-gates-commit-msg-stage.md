---
name: fix-hooks-m1-message-gates-commit-msg-stage
created: 2026-06-04
author: claude-opus-4-8
---

## Summary

pre-commit fires before git writes the new commit message, so the M1
contract-reconciliation and intent-recorded gates were reading the PREVIOUS
commit's message out of COMMIT_EDITMSG — stale claims blocked clean commits
and claims in the commit being authored were never validated. Relocate the
message-dependent gates to the commit-msg hook stage, where git provides the
real in-progress message file as $1.

## Claims

- adds shared tri-state escalation lib `scripts/git-hooks/m1-rigor-lib.sh` (CRITICAL_PATH_REGEX, m1_compute_mode, run_m1_check, m1_enforce) sourced by both hook stages
- adds M1 message-dependent gate section (contract-reconciliation + intent-recorded) to `scripts/git-hooks/commit-msg`, running against `$1` before the exec to the harness stanza hook, skipped when nothing is staged
- removes the COMMIT_EDITMSG capture and the contract_reconciliation / intent_recorded invocations from `scripts/git-hooks/pre-commit`; the diff-only gates (blast-radius, adjacency-staleness) stay
- fixes the prod-LOC pathspec undercount: `Palace/**/*.swift` does not match files directly under `Palace/`, so `Palace/*.swift` is included alongside it

## Anti-claims

- does NOT change any `scripts/check-*.py` gate script
- does NOT change gate thresholds, the critical-path regex, or the tri-state mode table
- does NOT change the harness stanza hook (`~/harness/core/hooks/commit-msg-stanza.sh`) or the secrets blocklist in pre-commit
- does NOT touch any Palace/ production code

## Files in scope

- scripts/git-hooks/pre-commit
- scripts/git-hooks/commit-msg
- scripts/git-hooks/m1-rigor-lib.sh (NEW)
