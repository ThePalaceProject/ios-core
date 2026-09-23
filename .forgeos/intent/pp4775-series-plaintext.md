---
name: pp4775-series-plaintext
created: 2026-07-13
author: Maurice Carrier
branch: feat/pp4775-series-plaintext
priority: PP-4775 (Sprint 79) — Book Detail series display, non-critical-path UI
---

# Intent: show series name as plain text on Book Detail when no other series books are in the catalog

## Context

`BookDetailView.seriesRow(book:)` (PP-4463) renders the SERIES row ONLY when the
book carries BOTH `seriesName` and `seriesURL` — the name is a `NavigationLink`
to the series search lane. When the catalog has no other books in the series,
the OPDS feed carries the series NAME but no series-search URL, so today the row
is hidden entirely. PP-4775 brings iOS in line with the web catalog (CPW): show
the series name as PLAIN, non-tappable text in that case.

## Claims

- Adds a pure, `nonisolated static` decision function
  `BookDetailViewModel.seriesRowDisplay(name:url:) -> SeriesRowDisplay` returning
  a new nested `enum SeriesRowDisplay: Equatable { case hidden; case
  plainText(name:); case link(name:, url:) }`:
  - name empty/nil → `.hidden`
  - name present + url present → `.link` (unchanged PP-4463 linked behavior)
  - name present + url nil → `.plainText` (NEW)
- Refactors `BookDetailView.seriesRow(book:)` to `switch` on that decision:
  the `.link` case is the existing NavigationLink rendering verbatim; the
  `.plainText` case renders a non-underlined, non-tappable `Text` with NO
  `.isLink` accessibility trait (VoiceOver reads it as static text, AC #4);
  `.hidden` renders `EmptyView()`.
- Adds `AccessibilityID.BookDetail.seriesPlainText` so QA/simdrive can
  disambiguate the plain-text state from the linked state.
- Adds unit tests for all four `seriesRowDisplay` cases (hidden via nil name,
  hidden via empty name, link, plainText) in `BookDetailViewModelTests`.

## Anti-claims

- Does NOT change how series metadata is sourced/parsed (`TPPBook.seriesName` /
  `seriesURL` untouched) — out of scope per the ticket.
- Does NOT change the linked-state search-query behavior or destination
  (`CatalogLaneMoreView`) — no regression to AC #2.
- Does NOT show a row when there is no series name (AC #3 preserved).

## Files in scope

- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` (enum + pure func)
- `Palace/Book/UI/BookDetail/BookDetailView.swift` (seriesRow switch)
- `Palace/Utilities/Testing/AccessibilityIdentifiers.swift` (seriesPlainText id)
- `PalaceTests/Book/BookDetailViewModelTests.swift` (4 decision tests)
