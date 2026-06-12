---
name: pp4553-single-title-lane-renders-cover
created: 2026-06-11
author: Maurice Carrier
changeset: cs_27f719be
branch: fleet/w-lane
---

# Intent: PP-4553 — single-/two-title catalog lanes render their covers, not a perpetual skeleton

## Context

PP-4553: a single-title catalog lane renders EMPTY on iOS — the lane header and
"More…" link show, but the one cover never appears. Android (no equivalent
guard) shows the single cover fine.

Root cause: `CatalogLaneModel` was initialized with `isLoading: books.count < 3`
at every lane-build site. The lane row view
(`CatalogLaneRowView.swift:19`, `if isLoading || books.isEmpty`) renders the
gray skeleton scroller whenever `isLoading` is true, so any FULLY-BUILT lane
with 1 or 2 titles was stuck showing placeholders forever. A genuinely-small
lane never gains more books, so its covers never render.

Genuine streaming/transition loading is a SEPARATE signal —
`isOptimisticLoading` (wired to `viewModel.state.isApplyingFacet`,
`CatalogView.swift:162`) — which is OR'd in at `CatalogContentView.swift:115`.
That is the only production reader of `lane.isLoading`, so the per-lane
`count < 3` derivation was simply wrong.

Non-critical path (catalog rendering), non-structural (no new types/abstractions).

## Claims

- Stops deriving `isLoading` from `books.count < 3` at all three lane-build
  sites — the argument is dropped so a fully-built lane is never flagged
  loading (default `isLoading: false`):
  - `CatalogViewModel.buildOPDS2GroupedContent` (OPDS 2 grouped) — `:428`
  - `CatalogViewModel.buildGroupedContent` (OPDS 1 grouped) — `:508`
  - `CatalogLaneMoreViewModel.processOPDS2GroupedFeed` (More view, OPDS 2) — `:245`
- Adds regression tests asserting `XCTAssertFalse(lane.isLoading)` for a
  1-title lane on every affected path (OPDS 2 main, OPDS 1 main, OPDS 2 More),
  plus 2-title / 4-title / 0-title coverage on the OPDS 2 main path.

## Anti-claims

- Does NOT change the genuine streaming/loading behavior: `isOptimisticLoading`
  (the real "lane is loading" signal) is untouched, so real catalog loads and
  facet-applies still show skeletons.
- Does NOT change lane RETENTION: 0-title groups are still dropped
  (`guard !books.isEmpty`), multi-title lanes (≥3) are unchanged.
- Does NOT add any new public API, type, or user-facing copy.

## Files in scope

- `Palace/CatalogUI/ViewModels/CatalogViewModel.swift`
- `Palace/CatalogUI/ViewModels/CatalogLaneMoreViewModel.swift`
- `PalaceTests/OPDS2/OPDS2CatalogWiringTests.swift`
- `PalaceTests/CatalogDomain/CatalogLaneSortingTests.swift`
- `PalaceTests/ViewModels/CatalogLaneMoreViewModelTests.swift`
