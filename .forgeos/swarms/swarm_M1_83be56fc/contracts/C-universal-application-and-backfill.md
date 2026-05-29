# Module C — Universal application + DoD extension + backfill + intent skill (M1)

**Critical-path-meta.** Depends on Modules A + B (sequential — start AFTER they land).

## Goal

Wire Modules A+B into universal hooks; extend CLAUDE.md DoD; run backfill audit; ship intent skill.

## Deliverables

### 1. `CLAUDE.md` Definition of Done extension (7→10 checks)

Append after existing check #7. Verbatim text:

```
8. **Contract reconciliation** — for non-trivial work (≥10 prod LOC), every "removes X" / "deletes X" / "migrates Y to Z" / "renames X to Y" / "adds field A to type B" claim in your commit body, PR body, or `.forgeos/intent/<name>.md` must reconcile against the staged diff. Run `python3 scripts/check-contract-reconciliation.py --commit-msg <file>` — exit 0 means all claims supported. Catches cluster pattern from waves 1-4. Paste exit code.

9. **Blast-radius check** — for ANY commit, run `python3 scripts/check-blast-radius.py --quiet`. Exit 0 means no new public API surface, no `#if DEBUG` on production paths, no test-only AppContainer init params, no discarded function results without `// TODO(ticket):` justification. High-severity findings block. Paste exit code.

10. **Adjacency staleness check** — for ANY commit removing/renaming a production type, run `python3 scripts/check-adjacency-staleness.py --quiet`. Warn-only. Paste output.
```

### 2. `scripts/verify-pr.sh` — 4 new gates between `test_quality` and `coverage_floors`

Insert AFTER test_quality block (currently lines ~340-355), BEFORE coverage_floors block (~361).

Each gate follows existing `record "<name>" "<status>" "<msg>"` pattern:
- `contract_reconciliation` — python3 check-contract-reconciliation.py → pass/fail
- `blast_radius` — python3 check-blast-radius.py → pass/fail
- `adjacency_staleness` — python3 check-adjacency-staleness.py → pass/warn (always pass, count warnings)
- `intent_recorded` — python3 check-intent-recorded.py → pass/fail

### 3. `scripts/git-hooks/pre-commit` — append M1 floor block

Tri-state escalation:
- <10 added prod-LOC under Palace/ → warn-only
- ≥10 prod LOC AND no critical-path file → block on contract-reconciliation/blast-radius/intent FAIL
- ANY critical-path prefix file → always-block

Critical-path regex: `^(Palace/SignInLogic/|Palace/Packages/PalaceAuth/|Palace/Audiobooks/|Palace/MyBooks/(Download|Borrow|BookReturn)|Palace/Network/TPPNetworkExecutor\.swift|Palace/Network/TPPNetworkResponder\.swift|Palace/Migrations/)`

Bypass: `--no-verify` (per project policy — only for emergencies with rationale).

### 4. Backfill audit — `.forgeos/audits/backfill-2026-05-28.md`

Run all 4 scripts retroactively against final commits of PRs #1018, #1019, #1020, #1022, #1023, #1024.

For each PR:
- Resolve final commit via `gh pr view <num> --json mergeCommit -q .mergeCommit.oid` (or `--json commits` for unmerged ones)
- Run each script against the diff: `git diff <sha>^...<sha>`
- Tabulate findings per PR (HIGH / MED / LOW counts per script)

For every NEW high-severity finding (not already in `.forgeos/wall-failures/`), create entry at `.forgeos/wall-failures/2026-05-28-backfill-pr<NNNN>-<short-id>.md` using `.forgeos/wall-failures/TEMPLATE.md`. Update INDEX.md.

### 5. `.claude/skills/intent/SKILL.md` (NEW)

Frontmatter + body explaining when to invoke + the `.forgeos/intent/<name>.md` format:
- Frontmatter: `name`, `created`, `author`
- Sections: `## Claims`, `## Anti-claims`, `## Files in scope`
- Invoke at start of ≥10 prod LOC OR critical-path work, BEFORE writing code

## Constraints

- Surgical inserts on CLAUDE.md + verify-pr.sh + pre-commit (don't rewrite).
- Module C is SEQUENTIAL after A + B. Check A's scripts exist on disk + B's agent exists before starting.
- Backfill audit is in-scope; new wall-failure entries are MANDATORY for new high-sev findings.

## Files OFF-LIMITS

- `scripts/check-*.py` (Module A)
- `.claude/agents/`, `.claude/skills/{clean-code,rigorous-fix,swarm,forge-review}/` (Module B)
- All Palace/* and PalaceTests/*

## Definition of Done (paste in transcript)

1. Gate names appear verbatim in verify-pr.sh + report output.
2. Every `python3 scripts/check-*.py` invocation binds exit code (`if python3 ... ; then` or `EXIT=$?`).
3. Backfill audit shows all 4 scripts × 6 PRs = 24 invocations.
4. CLAUDE.md DoD ends at #10; verify-pr.sh has 4 new gates; pre-commit has 4 invocations; intent skill exists; audit covers 6 PRs.
5. Pre-commit against KNOWN-BAD fixture exits 1; against KNOWN-GOOD exits 0.
6. `scripts/verify-pr.sh --quick` runs cleanly with 4 new gates in report.
7. Wall-failure entries created for backfill audit's new findings; INDEX.md updated.

## Implementer prompt

You are Module C of swarm_M1_83be56fc. cd to `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_M1_83be56fc-C-universal-application-and-backfill`. WAIT until Module A's 4 scripts exist on disk AND Module B's agent file exists (check with `git log --oneline --all | head` and `ls scripts/check-*.py .claude/agents/forge-blast-radius-reviewer.md`). Then perform the 5 deliverables in this contract. Backfill audit: resolve each PR's final commit via gh CLI, run 4 scripts against `git diff <sha>^...<sha>`. Write findings to `.forgeos/audits/backfill-2026-05-28.md`. New high-severity findings → wall-failure entries. Self-applied DoD: M1 itself triggers the new pre-commit hook + new verify-pr gates — make sure `.forgeos/intent/swarm-m1-universal-rigor-floor.md` exists before staging. Paste all 7 DoD checks before READY.
