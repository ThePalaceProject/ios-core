---
date: 2026-09-22
pr: "#TBD"
source: reviewer-block
reviewer_ids: []
changeset_id: ""
wall: TDD
walls: [TDD, implementer]
severity: high
wall_status: proposed
applied_in: ""
detector_script: ""
detector_status: no-detector
no-detector: "The violating shape is `.onChange(of: X) { arm() }` with no sibling `.onAppear`/`.task` in the same chained view expression. A line-based check cannot tell which `.onChange` handlers must also run at birth — most must not, and flagging them all would be tuned away within a week. An AST check would need to model SwiftUI modifier chains. The durable guard here is the design change (one `applyLoadTimeoutArming(for:)` called from both hooks) plus the review question recorded in the audiobook checklist; a detector keyed to arming-verbs was considered and rejected as a false-positive engine."
name: onchange-has-no-birth-fire
type: evolving
status: active
created: 2026-09-22
last_refresh: 2026-09-22
freshness_window: 365d
owners: [audiobooks]
description: Centralising a lifecycle hook onto .onChange deleted the birth fire, making the load-error path unreachable on a cold open
---

# `.onChange` does not fire for the value a view is born with

## Finding (verbatim from the qa_test reviewer)

> `armLoadTimeout()` is now called from **exactly one site**, inside
> `.onChange(of: loadingOverlayCurrentState)`. `.onChange` has no initial fire.
> Cold open is `isLoaded == false`, not downloading, not started → `.skeleton` at
> first evaluation, **no transition, no timer**. The old `.skeleton.onAppear`
> armed it. So a player that stalls on cold open never reaches `.loadError` —
> verbatim the "dead player behind working-looking chrome, no error, no Retry"
> the commit body argues `.awaitingReload` exists to prevent.

## What actually happened

PP-5205's first commit refactored the overlay so arming was "a property of WHICH
STATE we are in, not of which branch happened to draw" — a real improvement, and
the commit argued for it well. The old design armed the timer from
`playerLoadingSkeleton.onAppear` (`origin/release/3.3.0:917-918`). The new one
armed it from `.onChange(of: loadingOverlayCurrentState)` and nothing else.

`.onChange` fires on TRANSITIONS. A view opened cold is *born* in `.skeleton`;
there is no transition into it. So the 30-second timeout was never armed, and
`loadingTimedOut` could never become true, and `.loadError` — the state carrying
the only Retry button — was unreachable for the life of the session.

The changeset that introduced this contains, in its own source, the sentence
explaining why that outcome is unacceptable. The refactor moved the mechanism out
from under the prose describing it.

## Walls that should have caught it (and why they didn't)

- **TDD**: `stateArmsLoadTimeout` is a pure function with a full transition-table
  test, and `loadingOverlayState` has all 16 cells enumerated. Every one passed.
  The rule was right; it was never *asked*. Nothing in the suite touches the
  wiring between the rule and the view lifecycle, and 36 green tests reported a
  refactor that had removed a failure path.
- **implementer**: the diff deleted an `.onAppear` and added an `.onChange`, which
  reads as a move. The behavioural difference between the two is a SwiftUI
  semantic, not a visible property of the diff.
- **mutation**: a hook that does not exist has no line to mutate.
- **device**: the fix was exercised by tapping chapters on a working book. The
  defect only shows on a cold open that STALLS, which is precisely the case a
  manual pass does not reproduce on demand.

## Proposed permanent fix

1. **Landed with this entry.** One `applyLoadTimeoutArming(for:)` called from BOTH
   `.onAppear` and `.onChange`, so birth and transition cannot drift apart. The
   pairing is the fix; a single call site was the defect.

2. **Checklist question**, audiobook `verification-checklist.md` §7 trap 12: when a
   refactor centralises a lifecycle side effect, name every hook the old code ran
   from and say what fires the new one at BIRTH. `.onChange`, `.onReceive` and
   `.task(id:)` all answer "no" for the initial value; `.onAppear` and `.task`
   answer "yes".

3. **The generalisation:** a pure rule plus a lifecycle hook is two things, and a
   test of the rule is evidence about one of them. When a changeset moves WHERE a
   rule is consulted, the rule's tests do not re-verify anything.

## No detector — justification

See the `no-detector:` field. In short: nearly every `.onChange` in the codebase
correctly has no birth fire, so a check that flags the pattern would be annotated
into silence, and one narrow enough to avoid that would be keyed to this instance.
The design change makes the pairing local and visible; the checklist question is
what a reviewer runs.

## Application log

- 2026-09-22 — caught by an independent qa_test review before merge, not in
  production. Fix applied in the PP-5205 PR.

## Related entries

- `2026-09-22-cache-written-only-by-the-signal-it-outruns.md` — the other half of
  PP-5205, and the same shape: state that only one signal writes, and an
  assumption about when that signal arrives.
