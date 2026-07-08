---
name: swarm-m1-universal-rigor-floor
created: 2026-05-28
author: claude-opus-4-7
---

## Claims

- adds field `scripts/check-contract-reconciliation.py`
- adds field `scripts/check-blast-radius.py`
- adds field `scripts/check-adjacency-staleness.py`
- adds field `scripts/check-intent-recorded.py`
- adds field `.claude/agents/forge-blast-radius-reviewer.md`
- adds field `.claude/skills/intent/SKILL.md`
- extends `CLAUDE.md` Definition of Done from 7 to 10 checks
- adds 4 new gates to `scripts/verify-pr.sh` between test_quality and coverage_floors
- adds M1 floor block to `scripts/git-hooks/pre-commit`
- runs backfill audit against PRs #1018, #1019, #1020, #1022, #1023, #1024

## Anti-claims

- does NOT modify any Palace/*.swift production code
- does NOT modify any PalaceTests/*.swift code
- does NOT modify existing `mcp__forgeos__forge_*` MCP tools
- does NOT restructure `.forgeos/wall-failures/` schema
- does NOT modify user-level `~/.claude/agents/` or `~/.claude/skills/`
- does NOT backport findings to prior PR branches (surfaces as `requires-backport: yes`)
- does NOT touch `Palace/Audiobooks/`, `ios-audiobooktoolkit/`, `Palace/Accounts/`, `Palace/SignInLogic/`

## Files in scope

- scripts/check-contract-reconciliation.py
- scripts/check-blast-radius.py
- scripts/check-adjacency-staleness.py
- scripts/check-intent-recorded.py
- scripts/test_check_*.py (4 files)
- scripts/_fixtures/m1/* (fixtures)
- scripts/verify-pr.sh
- scripts/git-hooks/pre-commit
- .claude/agents/forge-blast-radius-reviewer.md
- .claude/skills/intent/SKILL.md
- .claude/skills/clean-code/SKILL.md
- .claude/skills/rigorous-fix/SKILL.md
- .claude/skills/swarm/SKILL.md
- .claude/skills/forge-review/SKILL.md
- CLAUDE.md
- .forgeos/audits/backfill-2026-05-28.md
- .forgeos/wall-failures/2026-05-28-backfill-*.md (conditional, new findings only)
- .forgeos/wall-failures/INDEX.md (append new entries)
- .forgeos/swarms/swarm_M1_83be56fc/manifest.yaml
- .forgeos/swarms/swarm_M1_83be56fc/plan.md
- .forgeos/swarms/swarm_M1_83be56fc/contracts/*
- .forgeos/swarms/swarm_M1_83be56fc/transcripts/*
