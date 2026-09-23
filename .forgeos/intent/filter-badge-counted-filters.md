---
name: filter-badge-counted-filters
created: 2026-08-25
author: Maurice Carrier
branch: fix/lane-filter-applied-state
type: bugfix
priority: correctness (catalog lane filtering — user-visible state lies)
---

# Intent: the filter badge must count filters that reached the server

## Context

OPDS facets are links, not query parameters. Applying N filter groups therefore
means N dependent requests: fetch the base feed, find the chosen facet among its
links, follow it, then find the next chosen facet among the *resulting* feed's
links, and so on. `CatalogLaneMoreViewModel.applySingleFilters` implements that
walk. (Android does the same walk for the same reason —
`FeedFacetOPDS12Composite` / `runCompositeFacet` in `android-core`.)

A filter can drop out mid-walk: the feed just loaded may not advertise the group
the user picked from, so there is no link to follow. That is a legitimate
outcome, not an error — but the app has to tell the truth about it.

Found while assessing PP-401 (faceted filters for search results), which would
reuse this exact code path. Fixing it here is a prerequisite for reusing it there.

## Reproduction

Deterministic, via `CatalogLaneFilterApplicationTests`:

1. Serve a lane feed advertising only a `Format` facet group.
2. Select both `Format/Ebook` and `Language/English`.
3. Apply.

`Language` has no link in the feed, so it is never requested. Before this change
`appliedSelections` was `["Format|Ebook", "Language|English"]` and
`activeFiltersCount` was `2` — the toolbar read "Filter (2)" and the sheet ticked
Language over results that had only ever been narrowed by Format.

## Root cause

The walk skipped unreachable filters correctly, but `appliedSelections` was
assigned *after* the loop from `specificFilters` — the filters the user
**requested** — unconditionally. Two paths skip silently (`findFilterInCurrentFacets`
returning nil; `fetchFeed` returning nil), and neither was reflected in the
recorded state. The failure is silent by construction: no error, no log, and
`applySingleFilters` had no test at all, so nothing could have surfaced it.

## Claims

- `appliedSelections` is derived from the filters that actually completed a
  fetch, not from the filters the user selected.
- A filter that cannot be found among the current feed's facet links is skipped
  and logged with its group and title, and is not reported as applied.
- A filter whose feed request returns nothing is skipped and logged likewise.
- Behaviour is unchanged when every selected filter is reachable: the same
  requests are made, in the same priority order, and every filter is reported.
- Clearing all filters still reloads the unfiltered feed and empties the badge.

## Anti-claims

- Does **not** change which requests are made, their order, or the priority
  ordering in `getGroupPriority`.
- Does **not** change the OPDS 1 / OPDS 2 branch behaviour, book extraction, or
  facet re-extraction rules.
- Does **not** touch the throw path. A filter that throws mid-walk still aborts
  the loop, leaves `appliedSelections` at its previous value, and surfaces
  `error` (which replaces the results view). Unchanged, still wrong, recorded.
- Does **not** stop intermediate feeds being published to `ungroupedBooks`, so
  results still flicker through partial filter states during the walk.
- Does **not** fix the stale-facets path: the OPDS 1 branch only re-reads facets
  when the response is an ungrouped acquisition feed, so a grouped intermediate
  response would leave `currentFacetGroups` stale and the next filter would
  resolve against the previous feed's links. I could not produce that response
  shape from a lane feed, so it is recorded rather than fixed.
- Adds no new user-facing copy, no new UI, and no server contract.

## Files in scope

- `Palace/CatalogUI/ViewModels/CatalogLaneMoreViewModel.swift` — applied-state
  bookkeeping inside `applySingleFilters` only.
- `PalaceTests/ViewModels/CatalogLaneFilterApplicationTests.swift` — new.
- `Palace.xcodeproj/project.pbxproj` — test file registration.

## Verification

- Two regression tests fail on the pre-fix tree with the exact wrong values
  (`["Language|English", "Format|Ebook"]` where only Format applied; count 2 vs 1)
  and pass after. This is the primary evidence.
- Two guard tests (`ChainsRequestsAndReportsBoth`, `WhenSelectionIsCleared`) pass
  both before and after, pinning that the walk itself is unchanged.
- 89 tests green across every suite touching the changed code:
  `CatalogLaneFilterApplication`, `CatalogLaneMoreViewModel`,
  `CatalogLaneMoreFilterState`, `CatalogLaneSorting`, `CatalogFilterService`,
  `ViewModelComputedProperty`.
- Diff-scoped mutation: 1/1 killed with a passing baseline first (a real kill,
  not a build error). Recorded honestly: only 1 of 16 mutation points falls on
  changed lines, and it is not on the changed logic — the operators do not target
  `guard let … else { continue }` or an array append. The before/after test
  behaviour is the load-bearing evidence, not the kill rate.
