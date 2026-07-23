<!--
  Palace iOS PR body — the durable record + fleet telemetry surface.
  Contract: docs/architecture/pr-report-contract.md   Format: .github/COMMIT_AND_PR_FOR_JIRA.md
  Fill every section. Delete a section ONLY if it genuinely does not apply, and say why.
  The goal is that six months from now, git + this page alone reconstruct the whole change.
-->

## Summary
<!-- One or two sentences. What changes, in patron-visible terms where possible. -->

## Root cause
<!-- WHY this change is needed: the mechanism of the bug, or the gap being filled.
     Describe behavior and the call path — not a file list. -->

## Solution
<!-- WHAT this PR does: the behavior change, and the key technical decision. -->

## Evidence
<!-- Grounded-verifiability (contract §3). Every weight-bearing claim → where CI or an
     artifact reproduces it. A number with no pointer is a hypothesis, not a verification.
     Mark each as CI-reproduced or self-attested — do not hide the difference. -->
- <claim, e.g. "PalaceTests full suite green"> → <CI job / artifact / exact command + exit status>
- <claim, e.g. "TriageBotCore swift test 258/258"> → <CI job, or "self-attested — not yet CI-reproduced (Obligation below)">

## Repro
<!-- Durable reconstruction (contract §3). How the scenario was reproduced, so a future
     reader can re-run it. Link the simdrive replay / fixture in-repo, not a dead run URL. -->
- Scenario: <one sentence, patron-visible>   Jira: PP-XXXX
- Replay / fixture: <.simdrive path or in-repo test> | none — <why>

## Class
<!-- Fleet-legibility (contract §4). Is this a recurrence of a known failure class?
     Use an id from docs/regressions/recurrence-classes.md, or declare a NEW class there. -->
- Recurrence-of: <registry-id, e.g. unbounded-live-dependency | debounce-missing | none — new class: <slug> (added to registry)>

## Obligations
<!-- Anything promised-but-not-done becomes a tracked checkbox with an owner, so a
     roll-up can audit un-discharged promises. "will verify before merge" lives here. -->
- [ ] <deferred / promised follow-up> — owner: <@handle or workstream>

## Scope
<!-- What this PR touches, and what it deliberately does not. -->

## Not done / Deferred
<!-- Hook-enforced for changes ≥50 prod LOC. Honest boundaries of the change. -->

---
🤖 Generated with [Claude Code](https://claude.com/claude-code)
