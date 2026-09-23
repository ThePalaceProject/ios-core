---
date: 2026-09-21
source: near-miss
walls: [contract, architect-review]
severity: high
wall_status: open
detector_script: ""
---

# guard-refusal-renders-as-success

## Finding

Five defects in one /rigorous-fix contract (PP-5191), across five architect rounds, all one
shape: **a guard whose refusal path is indistinguishable from success.**

1. **rev1 verification criteria.** Three of eight were already satisfied on `origin/develop`
   before any code existed — `grep -rn hasCredentials …AudiobookSessionManager.swift` printed 8,
   the CarPlay one matched `:81`, and `grep -n "case isBundled"` could never match either way
   (the line reads `case timestamp, hash, isBundled`). A criterion that cannot go red is not a gate.
2. **rev3 INV-2 predicate.** `numberOfItems == nil` read as PARTIAL. `PalaceTests/OPDS2CatalogsFeed.json`
   is 171 catalogs with no such field and backs five Accounts suites; `serializeAsCatalogsFeed`
   drops it, so every shipped on-disk cache decodes nil. First launch after upgrade would refuse
   its own cache and come up empty for 100% of installs — rendering like a normal cold-cache launch.
3. **rev4 INV-2 cell 3.** `COMPLETE ← PARTIAL ⇒ REFUSE` refused the change's own write: resident
   bundled 1142/nOI 1142 is COMPLETE, the merged superset 1242/nOI 1457 is PARTIAL. Rejected by
   the invariant it introduced, self-healing next launch — **green while doing nothing**.
4. **rev5 A-4/A-5.** `crawl():277` serializes `feedMetadata ?? …` and `AccountRegistryLoader:628-632`
   supplies it from the **cached** feed, so a genuine 1457→1400 shrink reads PARTIAL and is refused
   **forever**, rendering as "no deletions to reconcile". And `nil ⇒ COMPLETE` gave delete authority
   to `fallbackFetchFromNetwork`, which GETs `/libraries` — measured 2026-09-21: 1457 catalogs,
   **no `numberOfItems`**.
5. **The report about the pattern.** Summarising the four above, the author wrote that the permanent
   artifact **is** `scripts/check-contract-criteria-red.py` and **makes** instance 1 structurally
   impossible — present tense, for a file that does not exist (`ls` → No such file). The wall entry
   said "detector not yet written"; the narration did not. An unwritten gate rendering as a gate
   that exists and passes.

## What actually happened

Each looked correct because the failure mode produces the *same observable* as the success mode:
a green grep, an empty registry on a cold launch, a bucket that repairs itself a launch later, a
deletion that never arrives, a detector that is never run because it was never written. The author
checked each guard by asking "does it fire on the bad input?" and never "what does its refusal look
like from outside, and can I tell that apart from things going fine?"

Instances 2-4 were caught only by an independent reviewer running arithmetic against the real
`bundled_registry.json` and the live endpoints. Instance 1 was caught by *executing* criteria the
author had written but never run. Instance 5 was caught by `ls`.

## Walls that should have caught it

- **contract** — did not. Nothing required criteria to be executed against the base ref; they were
  authored as intentions and read as evidence.
- **architect-review** — DID catch all five, but only because it ran the greps, re-derived the
  numbers, and `ls`-ed the artifact. A reviewer that *read* the contract would have passed it.
- **TDD / mutation** — could not have: 1-5 are pre-code contract defects, and 3 is invisible to any
  suite because it self-heals across launches.

## Proposed permanent fix

**Tier 3 — `check-contract-criteria-red.py`, NOT YET WRITTEN.** `wall_status` stays `open` and
`detector_script` stays empty until it exists; per this README, the detector is the wall.

Scope and siting, settled in review:
- **Re-execute** each grep-shaped criterion against the base ref and fail any already satisfied.
  A recorded "Observed on base" column is *not* a gate — it is an assertion by the same author who
  wrote the criterion, which is the trust relationship that produced instance 1.
- Assert **green-on-tip** as well: red-on-base proves it could fail, green-on-tip proves the work happened.
- **Cannot-evaluate must FAIL, never `skip`.** `verify-pr.sh:846` records `skip` for a missing
  script — for this detector that is precisely the failure it exists to prevent.
- Grep-shaped criteria only. Extending to test-shaped ones means running a suite against the base
  ref, which gets disabled, which is worse than not having it.
- **Lives in `~/harness`, not `scripts/`** — it parses `.forgeos/changesets/**` and so is harness
  tooling per CLAUDE.local.md #8 and closed PR #1351; `verify-pr.sh` is the harness-FREE leg.
  Must be added to `~/harness/bin/install` or it reaches exactly one checkout.
- CLAUDE.md CI rule #4 in full, including the clean-contract-passes assertion.

**Not mechanizable — checklist, not detector.** Instances 2-5 are design/report review. Add to
`docs/architecture/areas/accounts/verification-checklist.md` §7:

> **A guard's refusal must not render as success.** For every guard, invariant, or early return
> added, state what its refusal looks like from outside and name the observable distinguishing it
> from the healthy path. If the answer is "it self-heals", "it comes up empty", or "nothing
> happens", it needs an error log carrying both operands plus a test asserting the refused state is
> non-empty and reports honestly. The same applies to claiming an artifact exists: `ls` it.

Deliberately no detector for these: a grep cannot tell a correct refusal from a wrong one, and one
firing on every `guard` would be noise — which is this same failure shape again.

## Application log

- 2026-09-21 — opened from PP-5191 architect rounds 1-5. Contract rev6 carries the §7 trap text.
  Detector not written; entry stays `open`.
