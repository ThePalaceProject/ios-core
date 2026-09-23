---
date: 2026-06-29
pr: "fix/fe741015-alert-cacommit-race (develop)"
source: escaped-to-production
reviewer_ids: []
changeset_id: ""
wall: TDD
walls: [TDD, verify-pr]
severity: high
wall_status: applied
applied_in: "fix/fe741015-alert-cacommit-race"
detector_script: "PalaceTests/RegressionGuards/UIAlertCACommitGuardTests.swift + simdrive forced-401 cold-launch repro"
detector_status: built
no-detector: ""
name: fe741015-guard-tested-wrong-surface
type: evolving
status: active
created: 2026-06-29
last_refresh: 2026-06-29
freshness_window: 365d
owners: [general]
description: A crash fix shipped WITH a green regression-guard test, yet the crash GREW 55→122 because the guard only exercised alert construction/nil — never the present-during-transition failure mode the crash actually is.
adr_ref: adr_3e2c6a3c

---

# A green regression guard that never drove the failure mode (#1 prod crash grew under it)

## Finding

A crash fix shipped WITH a green regression-guard test, yet the crash GREW
55→122 events because the guard only exercised alert *construction* / nil
short-circuits — never the present-during-active-transition failure mode the
crash actually is. A green suite "proved" a fix to a failure mode it never
reproduced; the guard logic itself (sample-`transitionCoordinator`-then-present,
wrapped in an `NS_NOESCAPE` catcher) also could not work against a *deferred*
CA-commit throw.

## What actually happened

Crashlytics `fe741015` — `NSInternalInconsistencyException: "A view controller
not containing an alert controller was asked for its contained alert
controller"` — is the **#1 crash on 3.1.0 (478): 122 events / 36 users / 14d.**
A prior fix (`e185f3f8b`, "UIKit safe-present guard (fe741015 family A)")
shipped a `transitionCoordinator` guard in `TPPAlertUtils` **and** a regression
test file (`UIAlertCACommitGuardTests`). Both were green. The crash then
**grew from ~55 to 122 events.** Two compounding misses:

1. **The guard tested the wrong surface.** Every test in
   `UIAlertCACommitGuardTests` exercised alert *construction* and *nil
   short-circuits* (`alert(title:message:)`, `setProblemDocument(nil…)`). **None
   drove a present while a `transitionCoordinator` was active** — which *is* the
   crash. A green suite "proved" a fix to a failure mode it never reproduced.
2. **The guard logic itself could not work.** It *sampled* `transitionCoordinator
   == nil` once, then presented synchronously — but the throw is *deferred* into
   the next `_UIAfterCACommitBlock`, and the `NS_NOESCAPE`
   `TPPObjCExceptionCatcher` wrapping `present()` returns before that block runs,
   so it can't trap it either. Sample-and-drop + a catcher that can't catch =
   no actual protection.

## Walls that should have caught it

- **TDD / verify-pr:** a crash fix's regression guard must drive the **actual
  crashing code path** (here: present-during-active-`transitionCoordinator`) and,
  for a UIKit deferred-CA-commit throw that a unit test cannot reliably
  reproduce, be backed by an **in-action repro** (simdrive). A test that only
  builds the alert object is not a guard for a *presentation-timing* crash — it
  is the same "green gate that detects nothing" class as
  `[[ws0-inert-quiescence-gate]]`, and the same "verify against the real failure
  artifact, not the assumed shape" lesson as the EPUB-webview premature-collapse
  wall.

## Proposed permanent fix

1. **Mechanism fix:** `TPPAlertUtils.presentFromViewControllerOrNil` now
   coordinator-*waits* (present from `coordinator.animate(alongsideTransition:)`'s
   completion, re-walking to the settled hierarchy) instead of sample-and-drop —
   mirroring the proven `TPPPresentationUtils.safelyPresent`. Announcement
   self-chain deferred past dismiss; launch-time sync-position prompt made
   coordinator-aware.
2. **Guard fix:** the regression test now drives the real present path and the
   intent mandates a **simdrive forced-401-at-cold-launch** in-action repro
   before merge (a deferred CA-commit throw is verification-in-action, not
   unit-reproducible). Recorded in
   `.forgeos/intent/fe741015-alert-presented-during-active-transition.md`
   (`type: bugfix`, Reproduction/Root cause/Verification).

## Application log

- 2026-06-29: detected during the 3.1.0 production crash-backlog triage swarm;
  fix branch `fix/fe741015-alert-cacommit-race` (develop). Unit guard green
  (9/9); coordinator-wait fix applied to TPPAlertUtils + announcement self-chain
  + sync-position prompt.

## Derived improvement (proposed for the catalog)

For any **crash** regression guard, require evidence that the test drives the
crashing operation itself (here: `present()` during an active transition), not a
precondition of it. "The alert object is well-formed" is not a guard for a
"presented at the wrong time" crash. If the failure mode is a deferred-runloop /
CA-commit throw that a unit test cannot deterministically reproduce, the guard
is incomplete without a recorded in-action (simdrive) repro. Cross-refs:
`[[ws0-inert-quiescence-gate]]` (green-but-inert gates),
verify-bugfix-against-real-artifact.
