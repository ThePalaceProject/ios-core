# Swarm `swarm_8ce6f5ae` — State-Management Architecture Campaign · Plan

**Architect triage.** Read-heavy; every claim below re-resolved to live source with
grep (file:line cited in the contracts). Six overlap-free contracts (A–F) map the 7
workstreams onto top-level Palace modules.

## Goal
Move Palace from "one Store consumer, three Effect dialects, a dual-writing
registry, two book-state owners, and unenforced transitions" toward ONE declared
doctrine that is **machine-checked** — without a big-bang rewrite of the
2155-LOC download god-class.

## WS → Contract mapping
| WS  | Theme                              | Contract | Module(s)                          |
|-----|------------------------------------|----------|------------------------------------|
| WS1 | Doctrine ADR                       | **A**    | docs/architecture                  |
| WS2 | Effect unification / boundary      | **B**    | AppInfrastructure + PalaceAuth pkg |
| WS3 | Kill registry dual-write + enforce | **C**    | Book (TPPBookRegistry/State)       |
| WS4 | Sideloaded SoT boundary            | **D**    | MyBooks/Sideload                   |
| WS6 | Pin the god-class (chars)          | **E** (E1)| MyBooks + PalaceTests/Contract    |
| WS7 | Extract the pipeline               | **E** (E2)| MyBooks                           |
| WS5 | Self-verifying arch                | **F**    | docs/.arch + scripts + .github     |

**Merges performed:** WS6+WS7 → **one** contract E (same MyBooks module, hard
E1-before-E2 ordering so no implementer can reorder pin/extract). WS3 and WS4 both
concern book-state ownership but touch **disjoint files** (TPPBookRegistry vs
Sideload/) — kept separate to bound blast radius; C owns TPPBookRegistry
exclusively, D owns Sideload exclusively, neither may edit the other.

## Contracts (letter · module · risk)
- **A** — State-Management Doctrine ADR · docs/architecture · *standard*
- **B** — Effect Unification / Boundary · AppInfrastructure+PalaceAuth · **critical_path**
- **C** — Kill Registry Dual-Write + enforce allowedTransitions · Book · **critical_path**
- **D** — Formalize SideloadedBookRegistry boundary · MyBooks/Sideload · **critical_path**
- **E** — MyBooks Pipeline: PIN (WS6) then EXTRACT (WS7) · MyBooks · **critical_path**
- **F** — Self-Verifying Architecture · scripts/.github/.arch · *standard*

Every critical_path contract triggers mandatory Phase-1a review + 100% mutation on
new logic + an extra SoD reviewer.

## Sequencing (hard dependencies)
```
A ─┬─> B
   ├─> C ─────────────┐
   ├─> D              │
   └─> E (E1 ─> E2)   │
                      ▼
              F  (needs A doctrine + C registry probe + E snapshots)
```
- **A first** — doctrine is the authority B/C/D/E conform to and F encodes.
- **E internal gate (non-negotiable):** E1 (WS6 characterization snapshots) MUST be
  GREEN before E2 (WS7) changes any behavior. Enforced by living in one contract
  with explicit ordering; the manifest also carries the blocking note.
- **F last** — derives sequence diagrams FROM E's snapshots and greps for C's
  `canTransition` enforcement; running it earlier yields false drift.

## Parallelism
After A lands (fast, pure doc), **B, C, D, E1 run in parallel** (disjoint files).
E2 unlocks when E1 is green. F starts once C is in and E1 snapshots exist.
The real serializer is **verification, not authoring** (see risks).

## Risks
1. **Verification is a serial bottleneck.** CI parity is
   `scripts/xcode-test-optimized.sh` (~7k executions, `-test-iterations 3
   -retry-tests-on-failure`) — one long run. Five parallel implementers still funnel
   through one full-suite gate each. This, not authoring, caps one-day throughput.
2. **WS3 (C) blast radius is large — 9 observers across 6 modules + 2 external
   posters** (verified). A full dual-write removal in one pass is unsafe; C is
   deliberately scoped to enforce-transitions + gate-the-post + migrate-2 + track
   the rest as debt. Over-reaching here is the #1 way to redden the board.
3. **WS7 (E2) is a 2155-LOC god-class.** A full cutover is multi-day. E2 is scoped
   to a snapshot-tested reducer SEAM on top of green E1 — NOT a cutover.
4. **`harness arch drift` is machine-local, absent on CI runners.** F must vendor a
   stdlib `scripts/arch-drift-check.py`; wiring the harness binary into
   `tooling-checks.yml` would ship a gate that only ever passes locally.
5. **Effect true-collapse needs a shared SPM module** PalaceAuth can import without
   the app module. B does the landable half (add the missing `Sendable` bound +
   formalize the boundary + probe count==2-justified); collapse-to-1 is a follow-up.
6. **allowedTransitions hard-reject is dangerous** (could drop legitimate retry
   transitions). C enforces log-only in RELEASE / assert in DEBUG for this pass.

## Acceptance criteria (rollup)
Each contract carries grep-able "Verification criteria" the orchestrator runs at
Phase 4.5. Swarm-level done = A–F all pass their AC blocks AND a full CI-parity
suite is green AND F's `scripts/arch-drift-check.py` exits 0 on the integrated tree.

## HONEST landable-and-verifiable-in-ONE-DAY assessment
**Realistically lands + verifies today (author + one full-suite gate each):**
- **A** — doctrine ADR. Pure doc. ✅
- **E1 (WS6)** — characterization snapshots for the two undocumented return
  branches + CLAUDE.md:259 fix. Framework + most snapshots already exist; this is
  gap-fill. ✅ **This is the highest-value, lowest-risk win — it PINS the god-class
  so any later extraction is safe.**
- **D** — Sideload boundary: doc header + read-seam protocol + boundary test. ✅
- **B** — the formalize-boundary half (add `Sendable` bound + doc + probe). ✅
  (collapse-to-one-Effect deferred).
- **F** — `arch-drift-check.py` + facts.json expansion + tooling-checks wiring +
  rule-#4 pytest. ✅ *if* it starts after E1 snapshots exist (serial tail).

**Sets up a gated follow-up (NOT safely one-day):**
- **C** full dual-write removal + all-9-observer migration → follow-up; today only
  enforce-transitions + gate-post + migrate-2.
- **E2 (WS7)** god-class cutover → follow-up; today only the reducer seam.
- **B** true Effect collapse into a shared SPM module → follow-up.

**Recommended split/defer:**
- SPLIT WS3 (C) explicitly into **C-now** (enforce + gate + 2 observers) and
  **C-follow-up** (remaining 7 observers + delete the post). The follow-up is its
  own critical-path change with its own full-suite gate.
- DEFER WS7 (E2) cutover; keep only the seam. The pin (E1) is what makes the
  deferral safe — that ordering is the whole point of the campaign.
- WS2 (B) collapse deferred behind the boundary-formalization + probe.
