# Module A — Phase 3.5 META-TOOLING rollout

**Owner module:** Skills + governance docs (no Palace/ touched)
**Risk:** critical_path_meta (the wall itself gets thicker — applies to every future swarm/rigorous-fix)
**Est LOC:** ~250 lines across 4 docs

## Scope (in)

| File | Change | Est lines |
|------|--------|-----------|
| `.claude/skills/rigorous-fix/SKILL.md` | Insert new section "### Phase 3.5 — Class-scan rollout" between current Phase 3 (skeptic-pass) and Phase 4 (forge-review). Content per spec below. | +90 |
| `.claude/skills/swarm/SKILL.md` | Add Phase 3.5 reference to Phase 4 (integrator) so swarm implementers run class-scans too. Insert paragraph + cross-link to rigorous-fix Phase 3.5 + Phase 4.5 check 9 (new). | +35 |
| `.forgeos/wall-failures/README.md` | Add **Detector requirement** subsection under "Workflow" — every entry MUST have `detector_script: scripts/check-<wall-id>.py` OR `no-detector: <reason>` in frontmatter. Add `detector_status` enum (built/queued/no-detector). Add `detector_script` to schema example. | +40 |
| `.forgeos/wall-failures/TEMPLATE.md` | Add `## Detector script` section between `## Proposed permanent fix` and `## Application log`. Frontmatter additions: `detector_script:`, `detector_status:`. | +30 |
| `.forgeos/wall-failures/derived-improvements.md` | Add one row recording Module A's Phase 3.5 rollout as a cluster-level improvement, source: this swarm_162a3219. | +5 |
| `docs/architecture/phase-3.5-class-scan.md` (NEW) | Standalone doc explaining the 5-step loop + 3-tier mechanism + discipline guardrails. Linked from skills + CLAUDE.md. | +60 |

### Phase 3.5 content to insert in rigorous-fix/SKILL.md

````markdown
### Phase 3.5 — Class scan + detector codify (MANDATORY when a new bug-class is identified)

**Fire when** any of:
- (Phase 1 architect) recon surfaces a pattern that recurs at ≥2 call sites — even if only 1 is currently broken.
- (Phase 2 implementer) writing the fix, notices the same shape elsewhere in the diff hunks they touched.
- (Phase 3 skeptic) running `/clean-code` or the per-area verification-checklist greps, finds the same shape.
- (Phase 4 qa-reviewer) blocks with a finding that classifies as a *class*, not a single instance.
- (any phase) the human says "scan for this elsewhere."

**The 5-step loop:**

1. **Characterize** — write a 1-paragraph definition of the bug class. What is the call-pattern that, when present, indicates a defect? Be precise enough that someone else can grep for it.
2. **Scan** — use the right tier (see below). Output: a list of survivor sites with file:line.
3. **Triage** — for each survivor, classify: (a) trivial inline fix (apply now), (b) scope-deferral (queue with ticket and rationale), or (c) false positive (annotate with `// no-<wall-id>: <reason>`).
4. **Wipe** — apply (a) fixes in this PR. The PR fixes the class, not just the originally-reported instance.
5. **Codify detector** — add `scripts/check-<wall-id>.py` that catches future instances. **This is the load-bearing artifact**, not the one-time wipe. Wire it into `scripts/verify-pr.sh` (both `--quick` and full) and `.claude/settings.json` PreToolUse hooks. Add `scripts/test_check_<wall-id>.py` per the existing detector test convention.

**3-tier mechanism — pick the right one:**

- **Tier 1 — `grep`/`ripgrep`.** When the class is a single literal call-pattern with no semantic disambiguation needed. Cheap, ~1 second. Example: every site that calls `markCredentialsStale()` literally.
- **Tier 2 — Explore subagent.** When the class needs *reading* (semantic disambiguation: which `Timer.publish(every:)` calls should invalidate during backgrounding vs which shouldn't). Cost: ~10 minutes / one subagent invocation. Output: file:line list with brief rationale per finding.
- **Tier 3 — dedicated detector script at `scripts/check-<wall-id>.py`.** Runs in `scripts/verify-pr.sh` + pre-commit. **THIS IS THE PERMANENT WALL.** The one-time wipe catches *current* instances; the detector catches *future* ones. Without Tier 3 the class can recur next month.

**Discipline guardrails (NON-NEGOTIABLE):**

- **Scope-deferral protocol applies.** If the class scan returns >5 survivors and fixing all of them would push this PR past 600 LOC, STOP with the BLOCKED + scope-reduction proposal per CLAUDE.md. Do not silently ship "we fixed 3 of 8 sites and the PR title is `fix(<thing>)` while the issue remains in 5 sites." Tier 3 still lands in this PR — the detector catches the deferred sites at the next commit they touch.
- **Triage budget.** Small class (≤3 survivors, ≤50 LOC fix): instant fix, no follow-up ticket. Big class (>3 survivors or >50 LOC fix): scope-defer, file a Jira follow-up *and* land the detector. The detector + the deferred-follow-up ticket together IS the wall — neither alone is sufficient.
- **The detector script catches future instances; the wipe only catches current ones.** When the choice is "spend the budget on the wipe vs the detector," **prefer the detector**.

**Output of Phase 3.5 (committed at PR time):**
- `scripts/check-<wall-id>.py` + `scripts/test_check_<wall-id>.py`
- Wiring in `scripts/verify-pr.sh` (both `--quick` and full) — use the existing `run_m1_check` helper shape
- `.claude/settings.json` PreToolUse Bash hook entry (`scripts/hooks/pre-commit-<wall-id>.sh` if a wrapper is needed, otherwise inline)
- Wall-failure entry `.forgeos/wall-failures/YYYY-MM-DD-<short-id>.md` with `detector_script:` populated
- Commit body reconciles "wiped N sites, detector covers future" via `check-contract-reconciliation.py`
````

### Phase 3.5 content to insert in swarm/SKILL.md Phase 4 (integration)

````markdown
**Phase 4.0a — Class-scan from implementer transcripts.** Before running Phase 4.5 skeptic-pass, read each transcript's `class_scan:` block (if any). For every class identified, confirm the implementer either (a) executed the Tier 1/2 scan and either wiped survivors or filed scope-deferral, or (b) committed a Tier 3 detector. If a class was identified but NO detector landed and NO deferral ticket was filed, that's a Phase 3.5 violation — send the implementer back. See `/rigorous-fix` Phase 3.5 for the full 5-step loop + 3-tier mechanism + discipline guardrails. **A swarm implementer who finds a class but does not land Tier 3 has shipped against the wall-failure catalog rules.**
````

### Wall-failures/README.md additions

````markdown
**Detector script requirement (2026-06-05, swarm_162a3219).** Every wall-failure entry MUST have either:
- `detector_script: scripts/check-<wall-id>.py` in frontmatter, AND a `## Detector script` section in the body describing the catch-pattern + linking to `scripts/test_check_<wall-id>.py`, OR
- `no-detector: <reason>` in frontmatter — only acceptable when the class is semantic-only and a static script genuinely cannot encode it (e.g., "behavior depends on runtime state in a 3rd-party library"). The reason must be specific; "too hard" is not acceptable.

The entry's `detector_status:` is one of: `built` (script + tests landed) / `queued` (entry exists, detector pending in named follow-up PR) / `no-detector` (justification recorded).

A wall-failure entry without one of these is `wall_status: open` regardless of whether the one-time fix landed. The detector is the wall — the wipe is just the incident response.
````

### TEMPLATE.md additions (insert before `## Application log`)

````markdown
## Detector script

**Script:** `scripts/check-<wall-id>.py`
**Tests:** `scripts/test_check_<wall-id>.py`
**Wired into:** `scripts/verify-pr.sh` (both `--quick` and full); `.claude/settings.json` PreToolUse hook(s).

**What it catches (one paragraph):** describe the call-pattern in grep-able terms. What goes wrong if this lands? What is the canonical fix shape?

**False-positive escape hatch:** `// no-<wall-id>: <reason>` on the same or preceding line — same convention as `// no-superpartner:` per `scripts/check-superpartner-spectrum.py`. Document the escape hatch here so future engineers don't `--no-verify`.

**Severity (high/medium/low) and rationale:** ...

(If `no-detector` justified instead, replace this entire section with a `## No detector — justification` section that's specific about why no static check can encode the class.)
````

## Scope (out — DO NOT touch)

- **CLAUDE.md** edits beyond a single 2-line cross-reference to Phase 3.5 in the "Wall-failure catalog — every reviewer block becomes a permanent improvement" section (one line: "See `/rigorous-fix` Phase 3.5 for the operational mechanism (5-step loop + 3-tier mechanism) every wall-failure entry must land with."). Do NOT touch any other CLAUDE.md sections.
- `scripts/verify-pr.sh` itself — Module B owns this wire-in. Module A only documents the convention.
- `.forgeos/wall-failures/INDEX.md` — leave alone; updated separately as wall-failure entries land.
- Existing wall-failure entry markdowns (e.g. `2026-06-05-pr1018-icarus-cross-host-logout.md`) — Module A does NOT retrofit existing entries to add detector frontmatter. The convention applies forward; backfill is a separate pass.

## Verification criteria (grep-able)

1. `grep -c "Phase 3.5" .claude/skills/rigorous-fix/SKILL.md` ≥ 4 (section header + 3 internal cross-refs)
2. `grep -c "Phase 3.5\|class.scan" .claude/skills/swarm/SKILL.md` ≥ 2 (Phase 4.0a section + 1 cross-ref)
3. `grep -c "detector_script\|no-detector" .forgeos/wall-failures/README.md` ≥ 3
4. `grep -c "detector_script\|## Detector script" .forgeos/wall-failures/TEMPLATE.md` ≥ 2
5. `grep -E "phase-3.5-class-scan" docs/architecture/ -rln` ≥ 1
6. `python3 scripts/check-contract-reconciliation.py --quiet` exit 0 (commit body's "adds Phase 3.5 to /rigorous-fix" / "adds detector_script to wall-failure README+TEMPLATE" claims reconcile)
7. `python3 scripts/check-blast-radius.py --quiet` exit 0 (no new public Swift API; doc-only Module)

## Tests required

This is a docs-only module. No XCTest. Verification by greppable assertions above + `scripts/verify-pr.sh --quick` docs-only fast-path PASS.

## Acceptance

- All 7 verification greps pass
- `scripts/verify-pr.sh --quick` PASS (docs-only fast-path applies)
- Wall-failure entry NOT required for Module A (the entire module IS the catalog improvement) — Module A is referenced from `derived-improvements.md` as the source of the cluster-fix
- Next swarm/rigorous-fix that identifies a new bug-class produces a wall-failure entry with `detector_script:` populated; observation pass logged in `derived-improvements.md`

## Round-trip wiring requirement

N/A — docs-only.

## Mutation requirement

N/A — docs-only.
