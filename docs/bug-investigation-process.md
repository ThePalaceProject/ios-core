# Bug-investigation process

A dedicated, enforced process for investigating and fixing bugs. It exists
because a fix once shipped on an *unverified* root-cause hypothesis whose unit
tests only encoded the assumption (wall-failure
`2026-06-25-epub-webview-premature-collapse`). The discipline below is half
culture, half **enforced gate** — see "Enforcement".

## The process — SPREAD before COLLAPSE

1. **Reproduce against the REAL artifact first.** Before forming a fix, get
   ground truth: fetch the live feed/payload, pull the actual crash log, or
   reproduce on device/sim. Confirm the failing *shape* matches your
   hypothesis. Do NOT collapse to a fix off a plausible-sounding cause.
   If the moment has passed and all you have is a quoted log fragment, the
   simulator's own log store usually still holds the full window — see
   [`Testing/simulator-log-recovery.md`](./Testing/simulator-log-recovery.md).
   Recovering it beats re-driving: it is evidence about the ORIGINAL
   observation, not a new one.
2. **Enumerate ≥3 rival causes** and kill each by *evidence*, not plausibility.
   The first diagnosis is a hypothesis, not a conclusion. (The shape-preflight
   `hypothesis-ledger` nudge says the same thing.)
3. **Write the regression test against the VERIFIED shape** — not the assumed
   one. A green test that models a *wrong* mental model gives false confidence
   and sails through CI.
4. **Verify the fix IN ACTION** for any user-facing behaviour: build the sim app
   (`scripts/build-sim-for-simdrive.sh`) and drive the exact reported flow via
   simdrive, or otherwise confirm against the real artifact. A passing unit test
   is necessary, not sufficient.
5. **Record the wall.** If the bug shipped, was a near-miss, or escaped a gate,
   file a `.forgeos/wall-failures/` entry (see that README) and derive a
   permanent detector so it can't recur.

## Enforcement (the hook)

A bug-fix changeset's `.forgeos/intent/<slug>.md` must declare `type: bugfix`
in frontmatter, which makes the M1 commit gate
(`scripts/check-intent-recorded.py`, run from the `commit-msg` hook) REQUIRE
three additional body sections on top of the usual Claims / Anti-claims /
Files-in-scope:

- `## Reproduction` — how the bug was reproduced against the real artifact.
- `## Root cause` — the verified mechanism, with evidence.
- `## Verification` — the in-action confirmation the fix works (simdrive run,
  real-artifact recheck, etc.).

Missing any of these blocks the commit. The rule is opt-in via `type: bugfix`;
setting it on actual bug fixes is the author's + reviewer's responsibility (and
a follow-up may auto-flag bug-shaped commits that lack a bugfix intent). The
self-test `scripts/test_check_intent_recorded.py` plants a `type: bugfix` intent
missing `## Verification` and asserts the gate rejects it.

## Intent skeleton for a bug fix

```markdown
---
name: <slug>
created: YYYY-MM-DD
author: <you>
type: bugfix
---
## Claims
## Anti-claims
## Files in scope
## Reproduction
## Root cause
## Verification
```
