---
name: run-the-drm-tests-that-were-silently-skipped
created: 2026-08-26
author: claude-opus-5
type: bugfix
tracking: Follow-up to PP-5025 / PR #1418. Both items raised by the architect and blast-radius reviewers on that PR and deliberately deferred out of it as wider than a DRM bug fix.
related_prs: [1418]
---

# Intent: run the DRM tests that were silently skipped, and stop the contract gate crying wolf

## Claims

- Adds `FEATURE_DRM_CONNECTOR` to the `PalaceTests` target's
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (Debug and Release), set via the
  `xcodeproj` gem, not by hand-editing the pbxproj.
- Repairs `DRMAdversarialTests.testAdobe_didIgnoreFulfillment_*`, which had
  rotted invisibly: it called `didIgnoreFulfillmentWithNoAuthorizationPresent()`
  on `MyBooksDownloadCenter`, but the method moved to `AdobeDRMHandler` in the
  Phase 7 decomposition (#890). It now drives the real owner and asserts the
  actual PP-3649 contract — zero delegate interactions — instead of its previous
  "if we got here without a crash, the test passes".
- Teaches `check-contract-reconciliation.py` to skip the `## Anti-claims`
  section, ending the strip at the next heading. Adds two pytests: one
  reproducing the false positive, one control proving a genuine claim in a
  LATER section is still gated.

## Anti-claims

- Does not change any production Swift. The only production-side edit is a
  build setting on the test target.
- Does not relax `check-contract-reconciliation`'s other strip regions (code
  fences, blockquotes, quoted spans, wall-failure references) — the new region
  is additive.
- Does not fix the two pre-existing crashes seen in a full local suite run
  (`DownloadAuthRetryHandlerAuthCoordinatorTests`,
  `TPPBookRegistryLargeCorpusTests`). See Not done.

## Files in scope

- Palace.xcodeproj/project.pbxproj
- PalaceTests/Security/DRMAdversarialTests.swift
- scripts/check-contract-reconciliation.py
- scripts/tests/test_check_contract_reconciliation.py

## Reproduction

**Skipped tests.** `PalaceTests` built with `DEBUG LCP FEATURE_OVERDRIVE` — no
`FEATURE_DRM_CONNECTOR` — while the app target had it. 27 `#if
FEATURE_DRM_CONNECTOR` blocks across 16 test files therefore compiled to their
`#else`, which is usually `throw XCTSkip(...)`. A skipped test reports as a
pass, so the loss was invisible. Measured before: `DRMAdversarialTests` ran 4
tests with 3 skipped in 0.288s.

**Contract gate.** `Does **NOT** remove the licensor guard` under
`## Anti-claims` parsed as `claim=REM args=('the',)`, false-blocking PR #1418 on
five consecutive review rounds.

## Root cause

**Skipped tests.** `#if` in *test source* is evaluated against the TEST target's
compilation conditions, not the app module's. Linking against a DRM-enabled
`Palace` module makes the symbols resolve — which is why nobody noticed — but it
does not define the flag for the test file itself. A comment in
`RightsManagementDispatcherTests.swift` asserts the opposite ("Test runs
unconditionally (PalaceTests link against the DRM-on Palace module)"): true for
symbols, false for `#if`.

**Contract gate.** `_strip_non_claim_regions` already skipped code fences,
blockquotes and quoted spans, but had no notion of a section whose entire
purpose is to state what the change does NOT do. Parsing it inverts the meaning.

## Verification

- The newly-live DRM tests run and pass: 25 executed, 0 failures, **0 skips**,
  0 relaunches, across `DRMAdversarialTests`, `AdobeActivationTests`,
  `AdobeActivationDedupTests`, `TPPDeferredAdobeActivationTests`,
  `iPadOnMacRMSDKGuardTests`.
- Enabling the flag immediately exposed the rotted call site as a compile
  error — the change paying for itself on first run.
- Parser: 7/7 pytests pass, including the control that a claim after the
  anti-claims section still fails the gate (so the strip did not weaken it).

## Not done

- A full local suite run showed two relaunches, after
  `DownloadAuthRetryHandlerAuthCoordinatorTests.testForeignHost_401_SAML_withNilProvider_fallsBackToLegacyDispatch`
  and `TPPBookRegistryLargeCorpusTests.testRoundTrip_5000Books_AllFieldsPreserved`.
  Neither is a DRM test and the DRM-only run is clean, so these are most likely
  pre-existing pollution newly EXPOSED by the changed test ordering — 27 blocks
  that previously skipped now execute, so every later test sees different state.
  Per CLAUDE.md that is "newly exposed, not newly broken", and a different fix.
  Not diagnosed here.
- The `RightsManagementDispatcherTests` comment asserting the opposite of this
  finding is left in place; correcting stale comments across 16 files is a
  separate sweep.
