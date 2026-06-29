---
date: 2026-06-25
pr: "#1117"
source: near-miss
reviewer_ids: []
changeset_id: ""
wall: hook
walls: [contract, verify-pr, hook]
severity: high
wall_status: applied
applied_in: "fix/bug-investigation-gate (this entry's PR)"
detector_script: "scripts/check-intent-recorded.py"
detector_status: built
no-detector: ""
name: wall-epub-webview-premature-collapse
type: evolving
status: active
created: 2026-06-25
last_refresh: 2026-06-25
freshness_window: 365d
owners: [general]
description: EPUB-as-webview fix shipped on an unverified root-cause hypothesis; tests encoded the assumption
adr_ref: adr_e8c98b77

---

# EPUB-as-webview — fix shipped on an unverified root-cause hypothesis

## Finding (verbatim from bug report)

Tester (Maurice): "in Palace Bookshelf, some titles are opening as webviews, but
should be Epubs… check 'Multi-National Pulp Industries…'." After the first fix
merged (#1117): "i'm opening multi-national pulp industries… and i think it is
opening a webview still?" Then: "why are't you making assumptions? you collapsed
the field too soon."

## What actually happened

An Explore agent produced a *plausible* root cause — OPDS2 `indirectAcquisition`
ordering in `TPPBook.defaultBookContentType` — and I implemented it, wrote unit
tests that **encoded that same assumption** (OPDS2 single-acquisition-with-
indirects), and committed + merged (#1117) + opened forward-port PRs, all BEFORE
fetching the one ground truth that falsified it. The real book is OPDS **1.x**
with flat `open-access` links (streaming-media / PDF / EPUB as *separate*
acquisitions, streaming first); the actual lever is `defaultAcquisition`
("first supported" → streaming, after PP-4161 made streaming a supported type),
which `defaultBookContentType` only ever sees one of. The green unit tests
tested a *model* of the bug, not the bug. The real fix (#1120/#1121) preferences
downloadable acquisitions in `defaultAcquisition`, and was verified in action
via simdrive against the exact title (opens in the Readium EPUB reader). No
TestFlight build shipped the wrong fix — caught as a near-miss.

## Walls that should have caught it (and why they didn't)

- **contract / verify-pr**: green unit tests + green CI certified a fix whose
  premise was never checked against the real artifact. The tests encoded the
  assumed OPDS2 shape, so they were self-consistent and useless as a check.
- **hook (M1 intent)**: the intent gate verifies a claim is *recorded* and that
  *my* tests pass — it never required evidence that the bug was reproduced or
  that the fix was verified against the real failing case. A confidently-wrong
  diagnosis passes clean.
- **shape-preflight (advisory)**: it DID fire "hypothesis-ledger — run SPREAD
  before COLLAPSE; do not accept the first diagnosis," but it is an advisory
  nudge, not enforced, and was overridden.

## Proposed permanent fix

Applied in this entry's PR:

1. **Enforced gate** — `scripts/check-intent-recorded.py`: an intent declaring
   `type: bugfix` now REQUIRES `## Reproduction`, `## Root cause`, and
   `## Verification` body sections (on top of Claims / Anti-claims /
   Files-in-scope). Missing any blocks the commit via the `commit-msg` M1 hook.
   Self-test `scripts/test_check_intent_recorded.py` plants a `type: bugfix`
   intent missing `## Verification` and asserts rejection (KNOWN-BAD-3) plus a
   complete one passes (KNOWN-GOOD-2). Had this existed, the EPUB fix could not
   have been committed until I had written a real reproduction + in-action
   verification — which forces actually doing them, catching the wrong shape.
2. **Process doc** — `docs/bug-investigation-process.md`: the dedicated
   SPREAD→COLLAPSE bug process (reproduce against real artifact → ≥3 rival
   causes → test the verified shape → verify in action → record the wall).

## Follow-ups (queued, not in this PR)

- Auto-flag bug-shaped commits (regression / HelpSpot / Crashlytics / "opens as"
  signals) that change prod code but lack a `type: bugfix` intent — escalate
  from advisory to block once tuned to avoid false positives.
- A recorded, replayable simdrive journey ("open a multi-format open-access
  title → assert EPUB reader, not WKWebView") as a CI regression guard.
- Anchor the intent section check to line-start (`^## <Section>`) so prose
  mentioning a header can't satisfy a required-section check (pre-existing
  substring-match limitation, surfaced while building this gate's fixtures).
