---
name: swarm-core-convergence-adr
type: evolving
status: proposed
created: 2026-06-10
last_refresh: 2026-06-10
freshness_window: 365d
---

# ADR: Converging `/swarm` onto a deterministic Workflow engine (`swarm-core`)

<!-- audit-verified -->
<!-- Citations spot-checked 2026-06-10: SKILL.md = 779 lines; harness_telemetry.py
exposes default_state_dir/now_ts/parse_ts/append_record/read_jsonl/within_window/
html_escape/html_page; CRITICAL_REGEX present in pre-critical-path-mutation.sh;
.forgeos/wall-failures = 26 entries. -->

**Status:** Proposed · **Date:** 2026-06-10

**Decision driver:** The `/swarm` SKILL.md is a ~780-line prose orchestration
program. It hand-rolls fan-out, integration sequencing, structured returns,
resumability, and token accounting in natural language that a model
re-interprets every run. A deterministic Workflow engine provides those
primitives natively. This ADR decides whether and how to migrate.

**Recommendation (stated up front, because it's the honest answer):**
**Partial migration ("strangler with a permanent seam").** Extract the
*control plane* (fan-out, dispatch ordering, barrier/pipeline, resume, token
accounting, gate sequencing) into a reusable `swarm-core` Workflow. Keep the
*Palace governance payload* as declarative config (`profile`) plus a small
number of **prose-resident judgment hooks** that deliberately do NOT migrate to
JS, because they are model-judgment tasks, not control flow. Do not attempt a
100% code-driven swarm — Section C shows three classes of governance that get
*worse* if forced into deterministic JS.

---

## A. Seam analysis

The current `/swarm` conflates **mechanism** (how agents are dispatched and
sequenced) with **policy/payload** (what Palace requires of each agent and gate).
Every SKILL.md responsibility classified engine / payload / delete-as-redundant:

| # | Responsibility | Lines | Classification | Rationale |
|---|---|---|---|---|
| 1 | Orchestrator worktree + Carthage/submodule/secrets setup | Phase 0, 72–137 | **PAYLOAD (hook)** | iOS-specific (toolkit real-clone vs symlink; `Carthage/Build` copy-not-symlink). Engine `isolation:'worktree'` owns generic worktree; provisioning is `profile.worktreeSetup`. **Encodes the 2026-05-19 incident — must not be lost (C).** |
| 2 | Cross-session lock via `manifest.yaml` status + pre-destructive hook | 57–68, 746–755 | **PAYLOAD + ENGINE (resume)** | Journaled cache owns resumability; destructive-op lock is a Palace hook keyed off swarm status. |
| 3 | Swarm/project/base-ref gathering | 44–49 | **ENGINE** | Run identity + params. `swarm_<hex>` becomes the run id. |
| 4 | Artifact tree (manifest/plan/contracts/transcripts/outcome) | 51–66 | **ENGINE (shape) + PAYLOAD (content)** | Journaled cache *is* the manifest; schema is `profile.artifactSchema`. |
| 5 | Phase 1 architect triage + contract-delta authoring | 139–192 | **PAYLOAD prompt on ENGINE phase** | `agent(prompt,{schema,phase:'triage'})`. Prompt+schema are payload; contract-first ordering is engine. |
| 6 | Verification-criteria greps written by architect, run at 4.5 | 159–172, 484–490 | **PAYLOAD** | Model-generated per-run grep assertions → typed agent output the engine runs; neither static JS nor prose. |
| 7 | Phase 1a architect-post-review + non-skippable-for-critical-path | 196–244 | **PAYLOAD prompt on ENGINE phase+skip-gate** | Skip predicate is policy: `profile.gates.architectReview.required(modules)`. |
| 8 | Phase 1b commit-scaffold-immediately | 246–265 | **ENGINE** | "Persist phase output before fan-out" = journaled checkpoint + `profile.commit`. |
| 9 | Phase 2 ForgeOS changeset creation | 267–279 | **PAYLOAD (hook)** | `profile.onTriageComplete → forge_propose_changeset`. |
| 10 | Phase 3 subagent-prelude injection | 282–298 | **PAYLOAD (hook)** | `profile.preludeFor(module)`. |
| 11 | Phase 3 parallel implementer dispatch | 281–283, 443 | **ENGINE** | `parallel(modules.map(...))` with concurrency cap. Biggest hand-rolled mechanism replaced outright. |
| 12 | Implementer prompt + scope-deferral protocol | 300–352 | **PAYLOAD** | Prompt is Palace; `BLOCKED` becomes typed `{status:'blocked',proposal}`. |
| 13 | 11-point Definition of Done self-checks | 354–441; CLAUDE.md 229–264 | **SPLIT** | Mechanical (1,2,5,6,8,9,10,11) → ENGINE gate steps calling `check-*.py`/`palace_mutate.py`. Judgment (3,4,7) → PAYLOAD agent-evaluated. |
| 14 | Phase 4 integrate (transcripts, gaps, contract `--check`) | 446–453 | **ENGINE barrier + PAYLOAD gap-resolution** | Barrier is engine; cross-module wiring is an agent phase. |
| 15 | Phase 4.0a class-scan reconciliation | 453 | **PAYLOAD (gate)** | `profile.gates.classScan` shell+grep step. |
| 16 | Phase 4.5 skeptic pass — Checks 0–8 | 455–657 | **ENGINE sequencing + PAYLOAD each check** | Ordered fail-closed `pipeline` of gate stages; each check is `{cmd, blockOn, wallFailureRef}`. |
| 17 | Phase 5 forge-review (3 reviewers, blast-radius floor) | 664–681 | **PAYLOAD (hook)** | `profile.review → /forge-review`; engine sequences + consumes `{verdict}`. |
| 18 | Wall-failure-on-block protocol | 31–42, 672–680; CLAUDE.md 315–335 | **PAYLOAD (hook) — partially un-automatable** | Engine forces the phase to exist (block promote until artifact present); model authors it. See C3. |
| 19 | Phase 6 promote + ADR-per-contract + outcome + commit + PR | 682–729 | **PAYLOAD hooks on ENGINE final phase** | All Palace MCP/git calls. |
| 20 | "≥2 modules or single-agent" gate | 18–27, 152–153 | **PAYLOAD predicate — partially DELETE** | Early-exit on `modules.length < 2`; risk override stays a predicate. |
| 21 | Risk-driven rigor bar override | 29; CLAUDE.md 290–305 | **PAYLOAD predicate** | `profile.rigor(modules)` drives which gates are mandatory. |
| 22 | "No swarm vocabulary in PR bodies" | CLAUDE.md 711–727 | **PAYLOAD — DELETE prose, keep linter** | Migrate to deterministic `profile.prBodyLint` regex; strictly better in JS. |
| 23 | Failure-mode recovery narratives | 731–743 | **DELETE-AS-REDUNDANT (mostly)** | "Re-spawn failed implementer" is native (resumable per-item cache). Judgment routing stays a small hook. |
| 24 | Architect module-sizing heuristics (200–600 LOC) | 757–767 | **PAYLOAD (prompt)** | Stays in architect prompt. |
| 25 | Cross-session safety narrative + bypass env | 744–755 | **PAYLOAD (hook) — KEEP** | `HARNESS_SWARM_BYPASS=1` semantics survive. |

**Net seam:** ~60% of SKILL.md by volume is mechanism the engine owns or makes
redundant; ~35% is payload that survives as config/hooks/prompts; ~5% (rows 18,
13-judgment, 6) is irreducibly model-judgment and must remain agent-evaluated.

---

## B. Target architecture

### B.1 `swarm-core` (engine-owned, project-agnostic)

A reusable Workflow that knows nothing about iOS/Palace/ForgeOS; all domain
behavior arrives via `profile`. Sketch of the phases:

- **Phase 0** — engine `enterWorktree`; `profile.provisionWorktree(wt)` does the
  iOS Carthage/submodule provisioning (row 1).
- **Phase 1** — ONE architect `agent(profile.architectPrompt(task), {schema:
  profile.contractSchema, phase:'triage'})`; early-exit if `modules.length <
  profile.minModules`; `journal.checkpoint('triage')`; `profile.commit` scaffold.
- **Phase 1a** — if `profile.gates.architectReview.required(modules)`, an
  `agent()` review; `BLOCKED` → `resume.retryPhase('triage', findings)`.
- **Phase 2** — `profile.onTriageComplete` (ForgeOS changeset).
- **Phase 3** — `parallel(modules.map(m => () => agent(profile.implementerPrompt(
  m, profile.preludeFor(m), triage), {schema, isolation:'worktree'})))`,
  concurrency-capped — the barrier (row 11).
- **Phase 4** — `profile.integrate(wt, results, triage)`.
- **Phase 4.5** — `for (gate of profile.gates.preReview)` fail-closed; each gate
  is `{id, cmd, block, wallFailureRef}`; a block re-runs only the implicated item.
- **Phase 5** — `profile.review` (delegates to `/forge-review`); `anyBlocked` →
  `profile.onReviewBlock` (forces wall-failure artifact, C3) → re-review.
- **Phase 6** — `profile.promote` (ADRs + outcome + PR); `journal.checkpoint`.

`budget.spent()`/`remaining()` replaces the prose "give my pass more budget" —
the engine enforces a per-implementer token ceiling and surfaces
`BLOCKED: budget` deterministically.

### B.2 The Palace `profile` (all domain knowledge, declarative)

`palace-ios.profile.mjs` carries: `provisionWorktree` (the extracted
`palace-worktree-setup.sh`), `preludeFor`, `contractSchema`, the architect /
implementer prompts (kept in separate `.md` files, not inline strings),
`rigor(modules)`, and a `gates.preReview[]` where each gate is
`{id, cmd, block, wallFailureRef}` — every gate traces to its wall-failure
incident (submodule-staged→pr1018-arch1, sut-instantiation→pr1018-qa2/qa3,
name-vs-body→cs9a267b63-arch1, m1-floor→swarm_M1_83be56fc,
content-type-invariant→PP-4161, impl-test-rerun→cs_c96660a2). `review` delegates
to `/forge-review`; `onReviewBlock` requires a wall-failure artifact (C3);
`promote` does the MCP/git calls.

### B.3 SKILL.md becomes a thin wrapper (~40 lines)

Launch swarm-core with the Palace profile (background, resumable, journal at
`.forgeos/swarms/<run_id>/`); read `plan.md`, confirm with user, resume.
Everything in rows 3,8,11,16,23 disappears from prose. What remains: the
human-in-the-loop confirmation point + the C1/C2/C3 judgment passages.

### B.4 Telemetry spine

swarm-core emits per-phase to the existing `harness_telemetry.py` spine
(`append_record` in the spine's `TS_FMT` jsonl) so `gate-report.py` and a future
`swarm-report` page read it via `read_jsonl`/`within_window` and render with the
shared `html_page` palette. Record carries `run_id, phase, event, wall_ms,
tokens_out, budget_spent, agents, blocked, gate_blocks, outcome`. Two derived
series fall out free: **process-cost** (budget per run → tokens-per-landed-PR;
per phase → which phase is expensive) and **cycle-time** (wall_ms per phase) —
the exact metrics the new `process-cost` and `cycle-time` subsystems consume.
Same observability surface as gates/wall-failures.

---

## C. What is genuinely lost or at risk (adversarial — the load-bearing section)

**C1. Architect module-boundary improvisation (real loss, partially mitigated).**
Model-driven `/swarm`'s architect invents boundaries that don't match the rigid
"module = top-level `Palace/` subdir" rule (real runs do; the heuristics split
>800-LOC modules and fold <100-LOC ones). The engine does
`parallel(triage.modules.map(...))` over whatever the architect emits. *Risk:* a
future "optimization" that derives modules from `git diff` path prefixes would
kill "these two dirs are one contract because they're entangled." *Preserve:* the
architect phase MUST stay a free-form `agent()` emitting a typed list — **module
partitioning is explicitly a model-judgment phase; do not replace it with
path-prefix derivation.** The engine owns dispatch *over* the partition, never the
partition.

**C2. Governance that's a predicate over fuzzy state (hard in JS).**
The Phase 1a skip rule is skippable only if "every touched area has a *current,
authoritative* verification-checklist." A naive `fs.existsSync(checklist)` would
**silently downgrade** the rule. The risk-driven rigor override's *spirit* ("a
30-LOC `BookReturnService` change gets full rigor") is a judgment about
consequence, and new critical paths get discovered (the 2026-06-05 icarus entry
*added* `Account.authSurfaceHosts` scoping). *Preserve:* fail-closed predicates
(critical-path ⇒ always required; "authoritative checklist" requires an explicit
agent-authored `skipped.reason` the engine **records but does not auto-grant**);
keep `isCriticalPath` as easily-extended profile data + an advisory gate flagging
touched paths matching a *new* critical pattern not yet classified.

**C3. Wall-failure protocol — the system's evolution mechanism — cannot be fully
automated, and the migration could silently neuter it (HIGHEST RISK).**
The protocol is *why the system gets less leaky over time*: every BLOCK gets a
dated entry, classified by which wall failed, with a structural fix. 26 entries
drive the gate battery; every `wallFailureRef` traces to one. *Where the cutover
drops it:* a deterministic engine naturally "handles a block" by retrying the
implementer — if `onReviewBlock` just loops to fixup, the **wall-failure-authoring
phase evaporates**; the finding is fixed for *this* PR but the wall stays leaky.
**The engine's own efficiency is the threat.** *Preserve:* make the wall-failure
artifact a **hard gate on promotion** — `profile.onReviewBlock` blocks Phase 6
until `.forgeos/wall-failures/<dated-entry>.md` exists per finding and is in
INDEX.md; the *content* stays an `agent()` task. Engine enforces existence+timing;
model authors substance. **Non-skippable; intentionally not migrated to JS.**

**C4. Lesser risks.** Judgment DoD checks 3/4/7 are semantic;
`check-test-name-vs-body.py` is a *structural proxy*, not a replacement — keep
check 4 (scope-coverage honesty, the PR #1018 Module C lesson) as an agent
assertion. Prose recovery routing ("architectural reject → re-triage; cosmetic →
fix inline") stays a small `classifyReviewBlock` hook. Gate ordering commentary
must survive as `wallFailureRef` + one-line `description` or a future maintainer
deletes a gate they don't understand. `run-contract-verification.py` /
`migration-completeness-check.py` actually exist (not stubs) — verify behavior
during shadow-run.

---

## D. Phased cutover (strangler-fig — `/swarm` never breaks)

Invariant: at every phase, today's `/swarm` keeps working unchanged.

- **Phase 0 — Engine lands dark.** `swarm-core.mjs` + journal + telemetry shim,
  unit-tested against a fake profile/agent runner; synthetic 3-module run proving
  fan-out, barrier, journal, **resume-only-failed-thunk**. No Palace code touched.
  Rollback: delete the dir.
- **Phase 1 — Palace profile, opt-in flag.** `palace-ios.profile.mjs` + thin SKILL
  wrapper behind `SWARM_CORE=1`; extract `palace-worktree-setup.sh` verbatim (the
  2026-05-19 home — tested script, not re-typed prose). Validate on a throwaway
  2-module docs+test change end-to-end; gate battery + forge-review + artifacts
  match. Rollback: unset flag.
- **Phase 2 — Shadow replay against a REAL landed swarm.** Replay harness re-runs
  swarm-core against corpus anchors: `swarm_47883816` (6 modules, primary) and
  `swarm_c8fcab76` (4 modules, has a known wall-failure → **exercises C3**).
  **Acceptance to flip:** (1) gate-coverage parity = 100% (diff the gate set, not
  just outcome); (2) **C3 proof** on `swarm_c8fcab76` — if it lands a fix without
  forcing the artifact, STOP; (3) artifact schema match; (4) process-cost ≤ 1.15×;
  (5) cycle-time ≤ baseline.
- **Phase 3 — Default flip, prose fallback (`SWARM_LEGACY=1`).** Run 5 real swarms;
  5/5 gate parity, no wall-protocol skips, ≥1 critical-path swarm (forces C2).
  Rollback: per-run legacy flag or revert the flip commit.
- **Phase 4 — Retire prose.** After ≥10 swarm-core runs with zero legacy fallbacks
  and ≥1 wall-failure authored by a swarm-core run, delete the ~780-line prose
  body; SKILL = thin wrapper + C1/C2/C3 notes. History preserves prose.

---

## E. Validation & success metrics

**Quality (gate, no trade-off against cost):** gate-coverage parity = 100% (any
dropped gate fails); wall-failure protocol intact (zero blocks "fixed silently" —
the single most important metric); reviewer-block rate not worse than prose.

**Process-cost (from `budget.spent()`):** tokens-per-landed-PR median ≤ 1.0× prose
(target cheaper — engine removes per-module re-orientation), hard ceiling 1.15×;
per-phase attribution (triage/implement/gate/review).

**Cycle-time (from `wall_ms`):** wall-clock per PR ≤ prose (true concurrency +
resume-only-failed-thunk); measurable reduction in 1-of-N failure re-spawn cost.

**Flip bar (2→3):** parity=100% AND C3 proven AND process-cost ≤1.15× AND
cycle-time ≤ baseline on both anchors. **Retire bar (4):** ≥10 live runs, zero
legacy fallbacks, ≥1 swarm-core-authored wall-failure.

---

## F. Risks, effort, recommendation

**Do it — as a partial migration, primarily for reliability, not cost.** ~780
lines of prose control flow re-interpreted every run, and an 86-line inline-bash
gate battery, are exactly what should be deterministic code with telemetry, not
narrative the model might skip under context pressure. The corpus shows real
drift: runs stuck at `triaged`/`in-flight`/`bundled` that never reached `complete`
are prose loops that stalled — a journal makes stall-and-resume first-class.

**Top risks:** (1) **C3 neutering** (highest) — hard promotion gate; treat a
Phase-2 run that fixes a block without an artifact as a blocking defect. (2) Silent
guardrail drop via naive predicates — fail-closed, record-not-grant. (3)
Prompt-migration defect — keep prompts in `.md` files, caught by shadow gate-parity
+ reviewer-block-rate. (4) Two-language seam — engine shells out to existing
Python/bash; don't reimplement. (5) Critical-path list rot — advisory gate +
budgeted maintenance.

**Effort:** engine+journal+telemetry ~700–1000 LOC JS; profile+prompts+worktree
script ~500–700 (mostly lifted); replay harness ~200–300; thin SKILL+wiring ~150.
**~1600–2200 LOC net new.** Calendar ~5–7 weeks, most of it soak time, not coding.

**The honest "partial" call — do NOT target 100% code-driven.** Three things stay
model-resident by design (say so explicitly so a future contributor doesn't "finish
the migration" and break them): (1) module partitioning stays a free-form architect
agent; (2) wall-failure authoring stays an agent phase (only existence/timing is
engine-enforced); (3) semantic DoD checks 3/4/7 + review-block routing stay agent
judgments. Everything else — fan-out, dispatch, integration ordering, the 8-stage
gate battery, resume, token accounting, telemetry — moves to the engine and is
strictly better there.

---

*Pairs with [`swarm-workflow.md`](./swarm-workflow.md) (the current `/swarm`
rationale). The `swarm-core` engine lives in `~/harness/core/` and emits to the
`harness_telemetry.py` spine introduced 2026-06-10.*
