---
name: pp4788-advanced-settings-menu
created: 2026-07-13
author: Maurice Carrier
branch: feat/pp4788-advanced-settings-menu
priority: PP-4788 (Sprint 79) — Settings UI; CRITICAL-PATH-ADJACENT (moves reset/sign-out entry points) → SoD review + simdrive AC-verify (DoD #12)
---

# Intent: migrate the Developer/Testing settings screen from UIKit to SwiftUI (feature-for-feature, pixel-for-pixel) + surface the patron functions in an always-visible Advanced menu (PP-4788, scope-widened)

> SCOPE WIDENED 2026-07-13 (agreed w/ Maurice): this is now a full UIKit→SwiftUI
> migration of `TPPDeveloperSettingsTableViewController` (~1100 LOC, 11 sections),
> with the PP-4788 Advanced-menu split folded in. Method: snapshot (done — 4 pixel
> baselines) → rebuild as SwiftUI `DeveloperSettingsView` + view model, replacing
> the `UIViewControllerWrapper` in `TPPSettingsView`. `.support`-audience rows
> (Send Error Logs + Data & Reset) → always-visible Advanced menu; `.engineering`
> rows stay in the gesture-gated Testing menu. Preserve EXACTLY: `RemoteFeatureFlags`
> local overrides + reset/sign-out flows. Gate: tests + architect/QA SoD + simdrive
> pixel-diff vs the 4 baselines. Original Advanced-only intent below.

## Original (Advanced-menu-only) intent

## Context

The Testing menu (`TPPDeveloperSettingsTableViewController`, UIKit) is revealed by a
long-press on the version number in the SwiftUI `TPPSettingsView` (the code uses
`minimumDuration: 5.0`, though the ticket says "7 seconds" — the gesture is OUT OF
SCOPE and unchanged; noting the doc drift only). Its sections are already tagged
by `audience`: `.dataManagement` ("Data & Reset": Clear Cached Data, Reset This
Library, Full Reset) is `.support`; "Send Error Logs" (`.developerTools` row 0)
is also patron-facing. Everything else is `.engineering`. All of it is gated
behind the long-press today, so support must walk patrons through a hidden
gesture to reach these functions.

The reset actions call `TPPSignInBusinessLogic.performScopedReset` /
`performForceReset` (sign-out + credential deletion + DRM deactivation) → this is
**critical-path-adjacent**; approach preserves behavior byte-for-byte rather than
reimplementing the destructive-reset presentation.

## Claims

- Adds an always-visible **"Advanced"** entry to the main SwiftUI `TPPSettingsView`
  (its own section near SUPPORT; a11y id reuses the existing
  `AccessibilityID.Settings.advancedButton`), presented as a `NavigationLink`, with
  NO gesture required — visible to all users.
- The Advanced menu hosts the patron-facing functions by REUSING the exact
  existing UIKit action code (not reimplemented): **Send Error Logs**
  (`ErrorLogExporter.shared.sendErrorLogs(from:)`) and the three **Data & Reset**
  rows (Clear Cached Data, Reset This Library → `confirmResetThisLibrary`, Full
  Reset → `confirmFullReset`). Behavior — confirmation alerts, mail composer,
  completion alerts — is identical to the Testing menu today.
- Those rows are **MOVED, not duplicated**: removed from
  `TPPDeveloperSettingsTableViewController` so they no longer appear in the Testing
  menu.
- The Testing menu retains all `.engineering` sections (feature flags, triage bot,
  registry debugging, notification/badge/error-simulation, etc.) and its existing
  long-press access; no feature-flag/internal option appears in Advanced.
- New/moved rows are VoiceOver-labeled to the Settings accessibility standard.

## Anti-claims

- Does NOT change the behavior of the moved functions (reset logic, log export,
  confirmation copy all unchanged).
- Does NOT change the Testing-menu access mechanism (long-press stays as-is,
  including its current 5.0s duration).
- Does NOT add an Android equivalent (separate ticket if desired).
- Does NOT touch `TPPSignInBusinessLogic` reset internals.

## Open items (surfaced for design/refinement, not blocking the diff)

- "Advanced" label + exact placement within Settings — using the ticket's
  "Advanced" label + a dedicated section near SUPPORT; flag in PR for design.
- Completeness of the moved set — moving the `.support`-audience set (Send Error
  Logs + the 3 Data & Reset rows); flag if refinement wants others.

## Verification plan

- Unit tests: Advanced-menu visibility (always shown, no gesture); the moved
  rows are present in Advanced and ABSENT from the Testing menu's visible set;
  Testing still surfaces its engineering sections.
- **simdrive AC-verification (DoD #12)** — this UI story IS sim-reachable:
  Settings → Advanced shows the functions with no gesture; the Testing menu
  (post long-press) no longer lists them; light + dark; VoiceOver labels.
- SoD review (critical-path-adjacent): architect + qa.

## Files in scope

- `Palace/Settings/NewSettings/TPPSettingsView.swift` (add Advanced entry)
- `Palace/Settings/DeveloperSettings/TPPDeveloperSettingsTableViewController.swift` (remove the moved rows)
- new Advanced menu component (SwiftUI wrapper + reused UIKit rows) under `Palace/Settings/`
- `Palace/Utilities/Testing/AccessibilityIdentifiers.swift` (any new row ids)
- `PalaceTests/Settings/…` (tests)
