# Bug-investigation process

A process for investigating and fixing bugs. It exists because a fix once
shipped on an *unverified* root-cause hypothesis whose unit tests only encoded
the assumption (an EPUB web view that collapsed early, 2026-06-25). See
"Recording it in the PR" for what review expects.

## The process — SPREAD before COLLAPSE

1. **Reproduce against the REAL artifact first.** Before forming a fix, get
   ground truth: fetch the live feed/payload, pull the actual crash log, or
   reproduce on device/sim. Confirm the failing *shape* matches your
   hypothesis. Do NOT collapse to a fix off a plausible-sounding cause.
2. **Enumerate ≥3 rival causes** and kill each by *evidence*, not plausibility.
   The first diagnosis is a hypothesis, not a conclusion.
3. **Write the regression test against the VERIFIED shape** — not the assumed
   one. A green test that models a *wrong* mental model gives false confidence
   and sails through CI.
4. **Verify the fix IN ACTION** for any user-facing behaviour: build the sim app
   and drive the exact reported flow, or otherwise confirm against the real
   artifact. A passing unit test is necessary, not sufficient.
5. **Record the lesson.** If the bug shipped, was a near-miss, or escaped a gate,
   add a numbered lesson to the area's `verification-checklist.md`, and add a
   detector if the class meets the bar in `CLAUDE.md` ("Adding a detector").

## Recording it in the PR

Nothing in the repo blocks a commit on this process; review does. A bug-fix PR
puts three short sections in its description, under How verified:

- **Reproduction**: how the bug was reproduced against the real artifact.
- **Root cause**: the verified mechanism, with evidence.
- **Verification**: the in-action confirmation that the fix works (a driven
  simulator or device run, a real-artifact recheck).
