---
date: 2026-09-22
pr: "#TBD"
source: reviewer-block
reviewer_ids: []
changeset_id: ""
wall: implementer
walls: [implementer, TDD]
severity: high
wall_status: proposed
applied_in: ""
detector_script: ""
detector_status: no-detector
no-detector: "The violating shape is a predicate that COMPILES, READS correctly, and answers a neighbouring question — `hasLocalFiles()` where the consumer gates on `assetFileStatus()`; playback state where the question is queue state; queue contents where the question is whether navigation landed. Nothing distinguishes it syntactically from a correct predicate; the error is entirely in the relationship between the predicate and the fact the CALLER acts on. A static check strong enough to see it would need to model that relationship, which is the program. The guard is the review question in trap 14 plus the structural preference recorded there."
name: adjacent-predicate
type: evolving
status: active
created: 2026-09-22
last_refresh: 2026-09-22
freshness_window: 365d
owners: [audiobooks]
description: Three consecutive fixes to one guard each keyed on a predicate adjacent to the one that mattered; the self-diagnosis was accurate every time and changed nothing
---

# A predicate adjacent to the one that matters

## Finding (verbatim from the qa_test reviewer, round 5)

> Round 3 added the backstop, round 4 keyed it on the wrong predicate, round 5
> re-keys it and is still wrong — in a third way — on a predicate that has never
> had a test in any round. Each round's commit message diagnoses the previous
> round's error as "a predicate ADJACENT to the one that matters", which is an
> accurate self-diagnosis that has now recurred three times without changing the
> method that produces it.

## What actually happened

One guard, three keyings, three wrong:

1. **`hasLocalFiles()`** — "the decrypted URLs exist on disk". The consumer,
   `buildPlayerItem`, gates on `assetFileStatus() == .saved(urls)` with a non-empty
   list and a successful multi-URL composition. Two predicates over one fact.
2. **playback started** (`lastStartedItemKey`) — but the question was whether the
   REBUILD succeeded, not whether audio is currently coming out. Nothing cancels
   the work item on pause, so a patron who tapped a chapter and paused would have
   been shown "Audiobook Unavailable" thirty seconds later.
3. **queue contents** (`currentItem == target && readyToPlay`) — but the rebuild
   inserts the target item FIRST, with a source comment saying so, precisely so
   `currentItem` reflects the intended chapter immediately. True before the seek
   runs. No false positives; vacuous for the failure it exists to catch.

Each is a sentence that reads true about the system. Each answers a question one
step away from the one the caller acts on. And each commit message named the class
correctly while committing the next instance of it — the diagnosis was never the
problem.

## Walls that should have caught it (and why they didn't)

- **implementer**: naming a bug class is not a method for avoiding it. The
  characterisation ("adjacent predicate") is a label applied AFTERWARDS; nothing in
  the writing loop asked, before the fact, *which value does the consumer actually
  branch on, and am I reading that value or a neighbour of it?*
- **TDD**: none of the three keyings had a test in any round. `playCallback`
  carries four of this ticket's six toolkit commits and has zero direct coverage —
  the stub in `LCPStreamingPlayerAsyncContractTests` OVERRIDES `playCallback`, so
  the suite's green says nothing about it. Its entire verification was reading, and
  reading is the instrument whose miss rate this ticket spent five rounds
  measuring.
- **mutation**: an untested method cannot be mutation-scored, and a predicate with
  wrong INPUTS survives every mutation of its operators. A table test over the
  four inputs of keying 3 would have passed.
- **reviewer**: caught all three, one per round — which is the system working, and
  also the reason the loop ran five rounds instead of one.

## Proposed permanent fix

1. **Prefer a shape that makes the question unrepresentable over a predicate that
   has to be right.** `OpenAccessPlayer.waitForItemReady` (:816-846) answers the
   identical "did this item become usable" question via `item.observe(\.status)`,
   cancelling in the observer — pause-independent BY CONSTRUCTION. Keying 2's
   defect was discoverable only because the guard was a predicate somebody had to
   get right; the observer shape has no corresponding way to be wrong.

2. **Checklist question**, audiobook `verification-checklist.md` §7 trap 14: before
   writing a predicate that gates a user-visible outcome, name the exact value the
   CONSUMER branches on and confirm the predicate reads that value — not a
   neighbour that is usually equal to it. Write the disagreement case down. If you
   cannot construct one, you have not found the consumer.

3. **Stop the loop at two.** The second consecutive wrong keying on the same guard
   is evidence about the METHOD, not about the guard. Revert and file, rather than
   iterating on a release candidate. That is what happened here on round five, and
   it should have happened on round four.

## No detector — justification

See `no-detector:`. The shape is invisible syntactically: keying 3 is a correct,
idiomatic, compiling boolean over real AVFoundation state. What makes it wrong is
a fact about a DIFFERENT function forty lines away (the rebuild inserts the target
first). A check able to see that is a check able to read the program.

## Application log

- 2026-09-22 — instances 1-3 found by review across rounds 2, 4 and 5 of PP-5205.
  The guard was reverted and filed as PP-5213 rather than attempted a fourth time.

## Related entries

- `2026-09-22-override-drops-base-state.md` — same ticket, and instance 1 of this
  class is also an instance of that one.
- `2026-09-22-cache-written-only-by-the-signal-it-outruns.md` — the original
  PP-5205 defect, itself a reader keyed on the wrong writer.
