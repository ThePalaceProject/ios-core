---
name: pp4527-where-am-i-position-report
created: 2026-06-18
author: Maurice Carrier
branch: fleet/palace-feature-pp4527
initiative: init_e96cfcb8
changeset: cs_a3d934de
priority: PP-4527 / Sprint 77 / Epic PP-833 EPUB Accessibility (DAISY nav-310)
---

# Intent: "Where am I?" reading-position announcement in the iOS reader

## Context

Palace iOS fails DAISY nav-310 ("Read navigation information"): the Reader2
(Readium 3.x) reader has no on-demand way to report the patron's current position
to a VoiceOver user. A non-visual reader navigating by TTS/VoiceOver can lose
their place and needs a single command to re-orient. This story adds a
VoiceOver-only custom accessibility action that announces the current
section + print page + percentage, **without moving focus or reading position**.

This story REUSES the page-list mapping layer landed by PP-4529
(`TPPReaderPageListBusinessLogic`, nav-110). It does NOT duplicate page parsing.

Existing surface (grounded):
- `TPPReaderPageListBusinessLogic` (`Palace/Reader2/BusinessLogic/`) exposes
  `pageEntries`, `hasPageList`, `label(at:)`, async `locator(at:)`,
  `indexForPage(labeled:)`.
- Current reading position is the Readium `Locator` from
  `navigator.currentLocation` / `NavigatorDelegate.locationDidChange`.
  `locator.title` = section/chapter title; `locator.locations.totalProgression`
  = 0...1 book progress.
- Custom VoiceOver/FKA actions are configured in
  `TPPEPUBViewController.configureAccessibilityActions()`. Reader announcements
  are posted via `UIAccessibility.post(notification: .announcement, ...)`
  (see PP-4529 page-arrival announcement).

## Claims

- Extends `TPPReaderPageListBusinessLogic` (REUSE, no duplication) with
  `currentPageLabel(for locator: Locator) async -> String?`: resolves each page
  entry to its book progression, finds the nearest **preceding** print page
  (largest page-entry progression ≤ the locator's `totalProgression`), and
  returns its label via the existing `label(at:)`. The nearest-preceding
  selection is a pure, mutation-testable static helper
  `nearestPrecedingIndex(progressions:current:)`.
- Adds a pure composer `TPPReaderPositionReport`
  (`Palace/Reader2/BusinessLogic/`) that builds the spoken announcement string
  from (section, optional print-page label, optional percentage):
  - section from `locator.title` when present;
  - print page appended only when a page label is available (title has a
    page-list and a preceding boundary exists);
  - percentage appended when `totalProgression` is available, rounded to a whole
    percent;
  - when the title has NO page-list, the section (+ percentage) is still
    reported and the absence of a page number does NOT error (AC).
- Wires a "Where am I?" `UIAccessibilityCustomAction` in
  `TPPEPUBViewController` that is exposed when VoiceOver is running; activating it
  builds the report from `navigator.currentLocation` and posts a VoiceOver
  `.announcement`. It does NOT call `navigator.go(...)`, so focus and reading
  position are unchanged.
- Adds `whereAmI` action-name and position-report format strings to
  `Strings.TPPBaseReaderViewController`, phrased consistently with existing
  reader announcements.

## Anti-claims

- Does NOT change how page numbers / the page-list are generated or sourced from
  the EPUB (consumes `publication.pageList` via the existing layer).
- Does NOT navigate to a section or page — this reports position only; no
  `navigator.go(...)` call on the action path.
- Does NOT move VoiceOver focus or the reading position.
- Does NOT add any visible, non-screen-reader control.
- Does NOT change the PP-4529 page-list navigation UI (Pages tab / Go to Page).
- Does NOT alter resume/last-read-position behavior.

## Files in scope

- `Palace/Reader2/BusinessLogic/TPPReaderPageListBusinessLogic.swift`
  (add `currentPageLabel(for:)` + pure `nearestPrecedingIndex`)
- `Palace/Reader2/BusinessLogic/TPPReaderPositionReport.swift` (new composer)
- `Palace/Reader2/UI/TPPEPUBViewController.swift` ("Where am I?" custom action)
- `Palace/Utilities/Localization/Strings.swift` (whereAmI + report strings)
- `PalaceTests/Reader2/TPPReaderPageListBusinessLogicTests.swift`
  (current-page mapping + nearest-preceding helper)
- `PalaceTests/Reader2/TPPReaderPositionReportTests.swift` (new composer tests)
- `Palace.xcodeproj/project.pbxproj` (new files, both targets)

## Verification posture

- `TPPReaderPositionReport` and the `nearestPrecedingIndex` helper are fully
  unit + diff-scoped-mutation tested (pure logic, strong mutant surface on the
  comparison and string-assembly branches).
- The VoiceOver custom-action **discoverability**, announcement **audibility**,
  and the **focus/position-not-moved** guarantee live in the UIKit/VoiceOver
  runtime and are NOT in-process observable. They are tagged UNVERIFIED pending a
  real-device VoiceOver pass (Chairman). The implementation removes the
  `navigator.go` call on the action path so position-preservation is structurally
  guaranteed, but the VoiceOver focus semantics still require device confirmation.
