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
   file a wall-failure entry in the maintainer harness's catalog and derive a
   permanent detector so it can't recur.

## Enforcement (maintainer harness)

The repo's own hooks do not enforce this; the maintainer's local harness does.
A bug-fix intent there declares `type: bugfix` in frontmatter, and the harness's
intent gate (`~/harness/stacks/ios/forgeos/check-intent-recorded.py`) then
requires three body sections on top of the usual Claims / Anti-claims /
Files-in-scope:

- `## Reproduction` — how the bug was reproduced against the real artifact.
- `## Root cause` — the verified mechanism, with evidence.
- `## Verification` — the in-action confirmation the fix works (simdrive run,
  real-artifact recheck, etc.).

Missing any of these blocks the commit. The rule is opt-in via `type: bugfix`;
setting it on actual bug fixes is the author's + reviewer's responsibility.
Contributors without the harness follow the same process and put the three
sections in the PR description instead.

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
