---
name: pp-4463-series-row-book-detail
created: 2026-06-01
author: claude-opus-4-7
---

## Summary

PP-4463: add a tappable SERIES row in the Information block on the Book Detail
screen. When a title has series metadata, render `Series: <name>` as a link that
navigates to `CatalogLaneMoreView(url: book.seriesURL)` — the same destination
the existing "More" affordance on the bottom series carousel uses. Hide the row
entirely when series metadata is absent. VoiceOver labels the row as a link.

## Claims

- adds field `seriesName` to type `TPPBook`
- adds parsing of `seriesLink?.title` into `seriesName` in `TPPBook.init(entry:)` (OPDS1)
- adds parsing of `belongsTo?.series?.first?.name` into `seriesName` in `OPDS2FullPublication.toBook()` (OPDS2 full-publication path)
- adds parsing of `belongsTo?.series?.first?.links?.first` href into `seriesURL` in `OPDS2FullPublication.toBook()` (was hardcoded `nil`)
- adds dictionary serialization key `SeriesNameKey` to `TPPBook` so `seriesName` persists across the dictionary round-trip
- adds SERIES row in `informationView` of `BookDetailView` rendered only when `book.seriesName` and `book.seriesURL` are both non-nil
- adds localized string `Strings.BookDetailView.series`
- adds accessibility identifier `AccessibilityID.BookDetail.seriesLabel`
- adds unit test coverage for `TPPBook` OPDS1 series-name parsing
- adds unit test coverage for `TPPBook` dictionary round-trip preserving `seriesName`
- adds unit test coverage for `OPDS2PublicationExtended.toBook()` series-name + URL extraction
- adds unit test coverage for OPDS1 `TPPOPDSEntry` → `TPPBook(entry:)` series-name + URL plumbing (XML-driven, exercised at the registry-input boundary in lieu of a SwiftUI view-render test since the project carries no ViewInspector dependency)

## Anti-claims

- does NOT modify the existing bottom-of-screen related-books / series carousel (`relatedBooksView`) — it stays as-is, navigating via `CatalogLaneMoreView` exactly as today
- does NOT change `TPPBook`'s init signature parameter order — `seriesName` is added at the end of the relevant inits to avoid call-site breakage where it can be defaulted to `nil`
- does NOT modify the lightweight `OPDS2Publication.Metadata` (Codable surface in the PalaceCatalog SPM module) — series info on Book Detail comes through the full-publication path only
- does NOT change `TPPOPDSLink` or `TPPOPDSEntry` — `seriesLink.title` already parses; no SPM module change required
- does NOT touch any auth, borrow, return, download, DRM, or audiobook code
- does NOT hyperlink other Information block values (Publisher, Categories, Distributor, etc.) — out of scope per ticket
- does NOT introduce a new navigation paradigm — reuses `CatalogLaneMoreView` and `NavigationLink`

## Files in scope

- Palace/Book/Models/TPPBook.swift
- Palace/Book/UI/BookDetail/BookDetailView.swift
- Palace/Book/UI/BookDetail/BookDetailViewModel.swift
- Palace/OPDS2/Models/OPDS2PublicationExtended.swift
- Palace/Utilities/Localization/Strings.swift
- Palace/Utilities/Testing/AccessibilityIdentifiers.swift
- PalaceTests/Book/TPPBookTests.swift
- PalaceTests/OPDS/OPDSParsingTests.swift
- PalaceTests/OPDS2/OPDS2PublicationExtendedTests.swift
