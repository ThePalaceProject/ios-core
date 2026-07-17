# Swarm `swarm_8ce6f5ae` — State-Management Architecture Campaign · Plan

**Architect triage.** Read-heavy; every claim re-resolved to live source with grep
(file:line cited in the contracts). Six overlap-free contracts (A–F) map the 7
workstreams onto top-level Palace modules.

## Execution model — "ship today, verify Monday" (budget is NOT a constraint)
Every contract's Definition-of-Done has **two tiers**:
- **TODAY (per-implementer, fast/local):** implemented; changed files COMPILE clean
  (`xcodebuild ... build`); diff-scoped mutation via `scripts/palace_mutate.py
  --diff-only` (100% on critical-path lines); characterization + unit tests written
  and pass via `-only-testing:` selectors; transcript + DoD evidence pasted.
  **Implementers do NOT run the full ~7k CI suite today.**
- **MONDAY MERGE GATE (orchestrator, not implementer):** full CI-parity suite
  (`scripts/xcode-test-optimized.sh`) + `/forge-review` 3 SoD reviewers
  (architect + qa_test + blast_radius) + `arch drift` clean. **Nothing merges to
  `develop` until Monday-green.**
Scope is NOT cut for the one-day window; the full-suite gate simply moves to Monday.

## Goal
Move Palace from "one Store consumer, three Effect dialects, a dual-writing registry,
two book-state owners, unenforced transitions" to ONE declared doctrine that is
**machine-checked** — completing the COMPLETE dual-write kill and extracting the
already-decomposed pipeline's DECISION CORES into pure reducers.

## WS → Contract mapping
| WS  | Theme                              | Contract | Module(s)                          |
|-----|------------------------------------|----------|------------------------------------|
| WS1 | Doctrine ADR                       | **A**    | docs/architecture                  |
| WS2 | Effect unification / boundary      | **B**    | AppInfrastructure + PalaceAuth pkg |
| WS3 | Kill registry dual-write + enforce | **C**    | Book (TPPBookRegistry/State) + 6 modules |
| WS6 | Pin EVERY branch (chars)           | **E** (E1)| MyBooks + PalaceTests/Contract    |
| WS7 | Extract decision cores             | **E** (E2)| MyBooks                           |
| WS4 | Sideloaded SoT boundary            | **D**    | MyBooks/Sideload                   |
| WS5 | Self-verifying arch                | **F**    | docs/.arch + scripts + .github     |

**Merges performed:** WS6+WS7 → **one** contract E (same MyBooks module, hard
E1-before-E2 ordering so pin/extract can't be reordered). WS3 and WS4 concern
book-state ownership but touch **disjoint files** — kept separate; C owns
TPPBookRegistry + the 9 observers, D owns Sideload only.

## Contracts (letter · module · risk)
- **A** — State-Management Doctrine ADR · docs/architecture · *standard*
- **B** — Effect Unification / Boundary · AppInfrastructure+PalaceAuth · **critical_path**
- **C** — Kill Registry Dual-Write (FULL) + enforce allowedTransitions · Book · **critical_path**
- **D** — Formalize SideloadedBookRegistry boundary · MyBooks/Sideload · **critical_path**
- **E** — MyBooks: PIN every branch (WS6) then EXTRACT decision cores (WS7) · MyBooks · **critical_path**
- **F** — Self-Verifying Architecture · scripts/.github/.arch · *standard*

Every critical_path contract triggers mandatory Phase-1a review + 100% mutation on
new logic + an extra SoD reviewer (part of the Monday gate).

## Scope corrections baked in (from coordinator)
1. **C is FULL — no split.** Enforce `allowedTransitions` at `setState` AND migrate
   ALL 9 observers across 6 modules to the Combine publishers AND delete
   `postStateNotification` (`:639`) + the direct sync post (`:283`). Internal order:
   enforce-before-purge (wire Combine + enforcement, migrate every observer, delete
   posts last). This is high blast-radius but done in one landing.
2. **E2 re-scoped — MBDC is ALREADY decomposed.** `MyBooksDownloadCenter` (2155 LOC)
   is a delegation HUB owning ~27 extracted collaborators (verified: empty delegate
   conformances at MBDC:1809-1926; prior swarms #1009/#1018/#1024/#1212 did the
   structural extraction). E2 is NOT "decompose the god-class" — it converts the
   **decision cores** of `BorrowOperation` (989), `BookReturnService` (744), and
   `DownloadStartDispatcher` (321) into pure `reduce`-style functions per the WS1
   doctrine, leaving MBDC + collaborators as the effect-runners. Bounded,
   per-collaborator. **E1 still pins EVERY borrow/return/download branch first.**

## Sequencing (hard dependencies)
```
A ─┬─> B
   ├─> C (enforce ─> migrate-9 ─> delete-posts)
   ├─> D
   └─> E (E1 pin-every-branch ─> E2 extract-decision-cores)
                      │
                      ▼
              F  (needs A doctrine + C canTransition probe + E snapshots)
```
- **A first** — doctrine is the authority B/C/D/E conform to and F encodes.
- **E internal gate (non-negotiable):** E1 (every branch pinned, snapshots green)
  MUST precede E2 (decision-core extraction). One contract, one implementer.
- **C internal gate:** enforce-before-purge — never delete the posts before every
  observer is migrated.
- **F last** — derives diagrams FROM E's snapshots, greps for C's `canTransition`.

## Parallelism
After A lands (fast, doc), **B, C, D, E run in parallel** (disjoint files; C touches
only the :2076 observer block inside MBDC, E touches the decision cores — coordinated
split of that one file). E2 unlocks when E1 is green; F starts once C + E1 exist.

## Risks
1. **Monday full-suite is the serial gate.** The CI-parity suite
   (`scripts/xcode-test-optimized.sh`, ~7k executions, `-test-iterations 3
   -retry-tests-on-failure`) runs once per contract at the Monday gate — parallel
   authoring today, serial verification Monday. This is by design under the new model.
2. **C blast radius is large — 9 observers across 6 modules + 2 external posters +
   both posts deleted.** The enforce-before-purge ordering + full observer migration
   in one contract is the #1 board-reddening risk; the Monday full-suite + 3 SoD
   reviewers are the safety net. Behavior parity must be proven by the migrated-observer
   behavioral tests before deletion.
3. **allowedTransitions hard-reject is dangerous** (could drop legit retry
   transitions). C enforces log-only in RELEASE / assert in DEBUG — never drops state.
   The transition SET is seeded from E's green snapshots.
4. **E2 behavior-preservation** rests entirely on E1 being complete FIRST — every
   branch pinned, each core's snapshot shape-equal to the E1 service snapshot.
5. **`harness arch drift` is machine-local, absent on CI runners.** F vendors a
   stdlib `scripts/arch-drift-check.py`; wiring the harness binary would ship a gate
   that only passes locally. Confirmed in Contract F (AC5 asserts the harness binary
   is NOT referenced in the workflow).
6. **Effect true-collapse needs a shared SPM module.** B does the landable half (add
   the missing `Sendable` bound + formalize the boundary + probe count==2-justified);
   collapse-to-1 is a follow-up.

## Acceptance criteria (rollup)
Each contract carries grep-able "Verification criteria" the orchestrator runs at
Phase 4.5, plus a two-tier DoD (TODAY compile+mutation+targeted-tests / MONDAY
full-suite+review+drift). Swarm-level done = A–F pass their AC blocks AND the Monday
gate is green for each (full CI-parity suite + 3 SoD reviewers + `arch-drift-check.py`
exits 0 on the integrated tree).

## HONEST assessment under the new model
The two-tier model removes the one-day full-suite bottleneck as a *scoping*
constraint — implementers finish TODAY at compile + per-file mutation + targeted
tests, and the expensive verification batches to Monday. That makes the FULL versions
of C and E (not the earlier de-scoped versions) realistic to author today:
- **A** — doc, done today. ✅
- **E1** — pin every borrow/return/download branch. Framework + most snapshots exist;
  gap-fill. Highest-value, lowest-risk. ✅
- **E2** — three bounded decision-core extractions on top of green E1. Realistic today
  because it's per-collaborator pure-function extraction, NOT a hub re-plumb. ✅
- **C (FULL)** — enforce + migrate-9 + delete-posts. Authorable today; its RISK is
  concentrated at the Monday full-suite (regression surface across 6 modules). The
  new model is what makes the full version viable — but C is the contract most likely
  to come back red Monday, so it gets the closest SoD scrutiny.
- **D** — boundary doc + seam + test. ✅
- **B** — Sendable-bound + boundary formalization + probe. ✅ (collapse-to-1 deferred).
- **F** — stdlib drift checker + facts expansion + tooling-checks wiring + rule-#4
  pytest. Its OWN gate (ubuntu tooling-checks, ~1 min) is exercisable today; only the
  snapshot-derived diagrams wait on E's Monday pass. ✅

**Remaining deferrals (genuine follow-ups, not one-day-cuttable):** B's true Effect
collapse into a shared SPM module; any hub re-plumb of MBDC (explicitly out of scope —
the hub is already decomposed). No workstream needs to be dropped under the new model;
the only deferrals are the two above, both flagged as follow-ups in their contracts.
