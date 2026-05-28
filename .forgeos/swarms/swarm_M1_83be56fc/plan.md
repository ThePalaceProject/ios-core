# Swarm M1 (83be56fc) — Universal rigor floor

**Base branch:** `swarm/swarm_d8f11437-scaffold` (stacked on PRs #1020 → #1022 → #1023 → wave 4 d8f11437).
**Risk bar:** all three modules CRITICAL-PATH-META — defects propagate to every future commit.

## Why this swarm exists

Waves 1-4 surfaced 11 manual-review findings AFTER /swarm rigor passed. Gap class: contract-vs-diff drift, blast-radius leaks (test-only public counters, test-only inits on AppContainer, `#if DEBUG` reachable from prod), adjacent staleness. Only /swarm and /rigorous-fix currently get architect + qa_test review. Every PR must clear the same floor.

## Modules

- **A — universal-rigor-scripts:** 4 stdlib-only Python 3 scripts in `scripts/` — `check-contract-reconciliation.py`, `check-blast-radius.py`, `check-adjacency-staleness.py`, `check-intent-recorded.py`. Each ≤500 LOC; companion `test_check_*.py` self-verification harnesses.
- **B — blast-radius-reviewer-agent:** New `.claude/agents/forge-blast-radius-reviewer.md` SoD reviewer + wire into 4 skills (clean-code, rigorous-fix, swarm, forge-review). Universal floor: blast_radius always included.
- **C — universal-application-and-backfill:** CLAUDE.md DoD 7→10 + verify-pr.sh 4 new gates + pre-commit tri-state escalation + new `.claude/skills/intent/SKILL.md` + backfill audit of PRs #1018-#1024.

## Parallelism plan

- Phase 1: A + B parallel (path-string coordination, no exec deps).
- Phase 2: C sequential after A+B (C invokes A's scripts + references B's agent).

## Self-referential rigor (MANDATORY)

1. Self-applied DoD #1-#7 on M1 itself.
2. Phase 1a non-skippable.
3. Existing forge-architect-reviewer proxies blast-radius for M1's PR (chicken-and-egg solved).
4. Module C's backfill audit runs A's scripts against waves 1-4 — new findings get wall-failure entries.

## Anti-scope

- Palace/Audiobooks/, ios-audiobooktoolkit/
- Palace/Accounts/, Palace/SignInLogic/ (meta-tooling only)
- Existing forge_* MCP tools
- .forgeos/wall-failures/ schema
- User-level ~/.claude/agents/ + skills/
