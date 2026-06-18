---
name: pp4529-print-page-navigation
created: 2026-06-18
author: Maurice Carrier
branch: fleet/palace-feature
initiative: init_e44afcac
changeset: cs_f2a2fbd8
priority: PP-4529 / Sprint 77 / Epic PP-833 EPUB Accessibility (DAISY nav-110)
---

# Intent: print-page navigation (page list + "Go to Page") in the iOS reader

## Context

Palace iOS fails DAISY nav-110 ("Navigate content by pages"): the Reader2
(Readium 3.9.0) reader offers no way to navigate by a title's hard-coded print
page breaks. Readium already parses the EPUB `page-list` into
`publication.pageList` (`[Link]`, each `Link.title` = a print page label,
`Link.href` = its position). This story surfaces that data for navigation,
distinct from reflowed reading position.

This is also the FOUNDATION for PP-4527 (nav-310 "Where am I?"), which reuses the
same page-list mapping layer to report the current print page.

Existing surface (grounded): nav panel is `TPPReaderPositionsVC` (storyboard,
Contents/Bookmarks segmented tabs) → `TPPReaderPositionsDelegate` →
`TPPBaseReaderViewController` calls `navigator.go(to:)`. TOC business logic is
`TPPReaderTOCBusinessLogic`. There is NO existing page-list usage (greenfield).

## Claims

- Adds a new pure business-logic layer `TPPReaderPageListBusinessLogic`
  (`Palace/Reader2/BusinessLogic/`) that:
  - loads `publication.pageList` into `[(label, link)]` entries, dropping
    entries with empty/whitespace labels;
  - exposes `hasPageList` (false ⇒ feature hidden, no error — AC),
    `pageCount`, `label(at:)`, and async `locator(at:)` (delegates to
    `publication.locate(link)`, bounds-checked → nil out of range);
  - resolves a requested page via `indexForPage(labeled:)`: exact
    (case-insensitive) label match first; if the request is numeric and no exact
    entry exists, falls back to the nearest **preceding** numeric page (largest
    numeric label ≤ request); non-numeric labels (e.g. roman numerals) match only
    exactly; returns nil when nothing matches.
- Wires a conditional "Pages" tab into `TPPReaderPositionsVC`, inserted as a
  third segmented-control segment ONLY when `hasPageList` is true; selecting a
  page entry navigates via the delegate. The tab reuses the TOC cell to render
  each print-page label as a flat list.
- Adds a "Go to Page" entry point as the Pages-tab table-header button (works in
  both pushed and popover presentation, no nav-bar dependency) that resolves the
  entered label through `indexForPage(labeled:)` and navigates, or reports
  not-found via a non-error alert.
- Adds `positionsVC(_:didSelectPageLocation:pageLabel:)` to
  `TPPReaderPositionsDelegate`; `TPPBaseReaderViewController` handles it by
  `navigator.go(to:)` and posts a VoiceOver `.announcement` ("Page <label>") on
  arrival.
- Page-list tab/controls carry accessibility labels.

## Anti-claims

- Does NOT change how the print page-list is generated or sourced from the EPUB
  (consumes `publication.pageList` as-is).
- Does NOT add reflowed-page navigation or reflowed page counts.
- Does NOT show the page list / "Go to Page" for titles with no page-list.
- Does NOT alter resume/last-read-position behavior (navigation uses the same
  `navigator.go(to:)` seam as TOC/bookmark selection).
- Does NOT modify the TOC or Bookmarks tabs' existing behavior.
- Does NOT add Dynamic-Type/contrast work (not in this story).

## Files in scope

- `Palace/Reader2/BusinessLogic/TPPReaderPageListBusinessLogic.swift` (new)
- `Palace/Reader2/UI/TPPReaderPositionsVC.swift` (Pages tab + Go-to-Page)
- `Palace/Reader2/UI/TPPBaseReaderViewController.swift` (delegate handler +
  page-list wiring into `presentPositionsVC`)
- `Palace/Utilities/Localization/Strings.swift` (Pages / Go to Page strings)
- `PalaceTests/Reader2/TPPReaderPageListBusinessLogicTests.swift` (new)
- `Palace.xcodeproj/project.pbxproj` (new file membership, both targets)

## Verification posture

- `TPPReaderPageListBusinessLogic` is fully unit + diff-scoped-mutation tested
  (pure logic, strong mutant surface on the resolution comparisons).
- VoiceOver arrival announcement + on-screen page-list rendering live partly in
  UIKit/VoiceOver runtime; the announcement firing is asserted at the unit seam
  where possible, and the end-to-end VoiceOver behavior is tagged UNVERIFIED
  pending a simdrive + real-device VoiceOver pass.
