## Contract C — `.forgeos/swarms/swarm_51f248d5/contracts/C-Apply-Arch1-Fixes.md`

```markdown
# Module C — Apply permanent fixes from arch1 wall-failure entry

**Standard rigor** (process module — zero Swift, zero production code touched).

## Goal

Apply the three layered permanent fixes from `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` to the contract template (swarm + rigorous-fix), CLAUDE.md Definition of Done, and Phase 4.5 orchestrator skeptic pass. Update the wall-failure entry's status + applied_in fields. Append a row to derived-improvements.md.

## Public types/protocols changing

**No public API changes. No Swift files touched. Zero production code.**

## Internal seams

None.

## Test contracts

None — process/docs module.

Verification is "did the verbatim text land in the cited section, and does the file still parse/render as markdown."

## Files scoped to THIS implementer

- `CLAUDE.md` (MODIFIED — append new "Multi-step / wiring-claim check (v2)" sub-clause to the "Definition of Done" section)
- `.claude/skills/swarm/SKILL.md` (MODIFIED — add `try await`/`await` boundary clause to the contract template's "Verification criteria" section AND add Phase 4.5 check 5b)
- `.claude/skills/rigorous-fix/SKILL.md` (MODIFIED — add the same `try await`/`await` boundary clause to its Verification criteria section)
- `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` (MODIFIED — `status: proposed` → `applied`; `applied_in: ""` → placeholder commit SHA the orchestrator fills in at integration)
- `.forgeos/wall-failures/derived-improvements.md` (MODIFIED — append a new row)

Tooling:
- None (pure markdown edits).

## Files explicitly OFF-LIMITS

**Anti-scope (universal):**
- `Palace/Audiobooks/`, audiobook test files, `Palace/Audiobooks/PlaybackReadinessGate.swift`, `Palace/Audiobooks/AudiobookSessionManager.swift`
- `ios-audiobooktoolkit/`
- `worktree-refactor-saml-auth` continuation files

**Off-limits per swarm overlap resolution:**
- All of `Palace/`, all of `PalaceTests/` — Module C touches ZERO Swift files. If a Swift change is needed, STOP and escalate; that's a scope expansion.
- All of `Palace/Accounts/` (Module A territory)
- All of `Palace/SignInLogic/` (Module B territory)

## Specific edits to apply

### Edit 1 — `CLAUDE.md` Definition of Done — append sub-clause to check #3

Locate the "Definition of Done" section (anchor: line 183 `## Definition of Done — paste evidence before declaring work complete`). After check #3 (the existing "Multi-step test body check"), add a NEW check #3b OR a new top-level check #7 (orchestrator picks the cleaner anchor — recommend numbered 7 to avoid renumbering). Verbatim text from wall-failure fix #2:

> **Multi-step / wiring-claim check (v2):** for every test name claiming to exercise a multi-step path through production code, line-coverage report must show non-zero hits on the cited lines from that test.

### Edit 2 — `.claude/skills/swarm/SKILL.md` Verification-criteria template (lines ~153-166) — add the `try await`/`await` boundary clause

Locate the "Verification criteria (MANDATORY)" section in the contract template (line 153). Add a new bullet item to the example list. Verbatim text from wall-failure fix #1:

> For every new `try await` / `await` boundary added in production code, the contract must include a grep showing a test that drives that exact line via the public entry point. If no such grep is possible, the implementer must STOP with BLOCKED + scope-deferral.

### Edit 3 — `.claude/skills/swarm/SKILL.md` Phase 4.5 — add check 5b

Locate the Phase 4.5 block (line 385 `### Phase 4.5: Orchestrator skeptic pass`). After the existing Check 5 (line 442 — "Check 5: Verify implementer pasted Definition-of-Done evidence"), add a new Check 5b. Verbatim text from wall-failure fix #3:

> Phase 4.5 orchestrator skeptic-pass grep: check 5b — for every claimed production-seam test, confirm the body calls the production entry point AND has no early-return mock that bypasses the cited line range.

(The exact bash implementation may be a stub `# TODO: implement check 5b mechanically — for now, manual review` per the existing pattern at line 458 acknowledging stubs.)

### Edit 4 — `.claude/skills/rigorous-fix/SKILL.md` Verification-criteria section — same `try await`/`await` boundary clause

Locate the "Verification criteria (grep-able assertions before declaring done)" section (line 70). Add the same verbatim bullet from wall-failure fix #1:

> For every new `try await` / `await` boundary added in production code, the contract must include a grep showing a test that drives that exact line via the public entry point. If no such grep is possible, STOP with BLOCKED + scope-deferral.

### Edit 5 — `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` — frontmatter update

Change:
```
status: proposed
applied_in: ""
```
to:
```
status: applied
applied_in: "<COMMIT_SHA_PLACEHOLDER>"
```

(The orchestrator fills `<COMMIT_SHA_PLACEHOLDER>` with the actual integration commit SHA at Phase 5.)

Also append a line to the "## Application log" section:
> - 2026-05-28 — applied via swarm_51f248d5 Module C (CLAUDE.md DoD check 7 + swarm SKILL.md contract template + Phase 4.5 check 5b + rigorous-fix SKILL.md verification criteria).

### Edit 6 — `.forgeos/wall-failures/derived-improvements.md` — append a new row to the table

Append (at the end of the table, before `## What the B3 backtest changes about my model`):

```
| 2026-05-28 | Production `try await`/`await` boundary clause in contract template + Multi-step / wiring-claim check (v2) in CLAUDE.md DoD + Phase 4.5 check 5b in swarm SKILL.md | 2026-05-28-cs847892e8-arch1 | swarm_51f248d5 Module C — `<COMMIT_SHA_PLACEHOLDER>` | applied |
```

## Verification criteria (MANDATORY)

1. **CLAUDE.md DoD check 7 (or 3b) added with verbatim text:**
   ```bash
   grep -c "Multi-step / wiring-claim check (v2)" CLAUDE.md
   grep -c "line-coverage report must show non-zero hits on the cited lines from that test" CLAUDE.md
   ```
   Both MUST return ≥1.

2. **swarm SKILL.md contract-template clause added:**
   ```bash
   grep -c "try await.*await boundary added in production code" .claude/skills/swarm/SKILL.md
   grep -c "BLOCKED + scope-deferral" .claude/skills/swarm/SKILL.md
   ```
   Both MUST return ≥2 (one in the contract template; second occurrence may exist already from the wall-failure-catalog section).

3. **swarm SKILL.md Phase 4.5 check 5b added:**
   ```bash
   grep -c "Check 5b\|check 5b\|# Check 5b" .claude/skills/swarm/SKILL.md
   grep -c "no early-return mock that bypasses the cited line range" .claude/skills/swarm/SKILL.md
   ```
   Both MUST return ≥1.

4. **rigorous-fix SKILL.md clause added:**
   ```bash
   grep -c "try await.*await boundary added in production code" .claude/skills/rigorous-fix/SKILL.md
   ```
   MUST return ≥1.

5. **Wall-failure entry status updated:**
   ```bash
   grep -c "^status: applied" .forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md
   grep -c "^applied_in: \"" .forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md
   ```
   First MUST return 1 (status flipped). Second MUST return 1 with non-empty placeholder.

6. **derived-improvements row appended:**
   ```bash
   grep -c "swarm_51f248d5 Module C" .forgeos/wall-failures/derived-improvements.md
   grep -c "2026-05-28-cs847892e8-arch1" .forgeos/wall-failures/derived-improvements.md
   ```
   Both MUST return ≥1.

7. **No Swift files modified by this module:**
   ```bash
   git diff --cached --name-only | grep -E "\.swift$" | wc -l
   ```
   MUST return 0 from C's diff alone (verify by isolating C's commit).

8. **Files outside C's scope NOT touched:**
   ```bash
   git diff --cached --name-only
   ```
   MUST be a subset of: `CLAUDE.md`, `.claude/skills/swarm/SKILL.md`, `.claude/skills/rigorous-fix/SKILL.md`, `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md`, `.forgeos/wall-failures/derived-improvements.md`.

## Definition of Done evidence (paste before declaring READY)

(Process-module variant — the 6 CLAUDE.md DoD checks are mostly N/A; provide what applies:)

1. **SUT instantiation check:** N/A — no Swift, no tests.
2. **Function-result usage check:** N/A — no Swift.
3. **Multi-step test body check:** N/A — no tests added.
4. **Scope coverage audit:** all 6 specific edits above landed (paste the 6 verification-criteria grep outputs).
5. **Mutation pass:** N/A — no production Swift.
6. **Build + verify-pr:** `scripts/verify-pr.sh --quick` PASS (build + lint should be unaffected by markdown edits; verify the docs-only diff does not trigger any markdown-lint rule).

## Implementer prompt (one paragraph)

You are Module C implementer for `swarm_51f248d5`. This is a PURE PROCESS / DOCS module — zero Swift, zero production code. Your job: apply the three layered permanent fixes from `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` (read the entry verbatim) by making targeted edits to 5 specific files: CLAUDE.md (add Definition-of-Done check 7 verbatim from wall-failure fix #2), `.claude/skills/swarm/SKILL.md` (add `try await`/`await` boundary clause to the contract-template Verification-criteria section + add Phase 4.5 check 5b), `.claude/skills/rigorous-fix/SKILL.md` (add the same `try await`/`await` boundary clause to its Verification criteria section), `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` (flip `status:` to `applied`, set `applied_in:` to a placeholder commit SHA), and `.forgeos/wall-failures/derived-improvements.md` (append the new row linking back to the entry). Lift all clause text VERBATIM from the wall-failure entry's "Proposed permanent fix" section. NO Swift edits. NO production code. NO test additions. If you discover an existing wall-failure clause already covers one of the three fixes, STOP and report — duplicate clauses pollute the DoD checklist. The orchestrator will replace `<COMMIT_SHA_PLACEHOLDER>` with the real commit SHA at Phase 5 integration time. Use `Edit` (not `Write` from scratch) on each markdown file to preserve existing structure. After edits, verify via `scripts/verify-pr.sh --quick` that markdown-lint rules still pass and no Swift-build path was affected.
```

---

