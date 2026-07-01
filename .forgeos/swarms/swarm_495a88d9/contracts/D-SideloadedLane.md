# Module D — SideloadedLane (catalog)

**Swarm:** swarm_495a88d9 (side-loading)
**Risk:** standard
**Depends on:** A (`AppContainer.sideloadedBookRegistry.allBooks`), B (flag).
**Ticket:** PP-2679.

## Purpose
Surface a "Side Loaded" lane at the top of the catalog when the feature flag is on
and there is ≥1 sideloaded book. The lane must appear **even when the base feed is
ungrouped or empty** (locked requirement — the DRM test use-case has no OPDS feed).

## Design (confirmed seams)
- Lane model: `CatalogLaneModel(title:, books:, moreURL: nil)`
  (`CatalogViewModel.swift:417-430`). No `moreURL` → no "more" affordance.
- **Injection point:** `MappedCatalog.toCatalogContent()`
  (`CatalogState.swift:129-149`) — the single conversion every load / facet /
  entry-point path funnels through. Add a parameter:
  `func toCatalogContent(prepending extraLanes: [CatalogLaneModel] = []) -> CatalogContent`.
  When `extraLanes` is non-empty, force the `.grouped` case:
  - base `.grouped(lanes)` → `.grouped(extraLanes + lanes)`
  - base `.ungrouped(books)` → `.grouped(extraLanes + [wrap(books)])` (wrap the
    ungrouped books in one `CatalogLaneModel` so nothing is lost) OR keep them as
    a trailing ungrouped-equivalent lane — pick one and document; must not drop books.
  - base `.empty` → `.grouped(extraLanes)`.
- **Provider injection into CatalogViewModel:** add ONE init param
  `sideloadedLaneBooksProvider: @escaping () -> [TPPBook] = { [] }`
  (`CatalogViewModel.swift:53-66`, mirrors the existing `topLevelURLProvider`
  closure-injection style). Keep the flag OUT of CatalogViewModel — the provider
  returns `[]` when the flag is off (the gate lives at the construction site).
- **SINGLE CHOKE POINT (REQUIRED — do NOT patch call sites individually).** There
  are **FIVE** `toCatalogContent()` call sites, not four:

  | line | method | branch |
  |------|--------|--------|
  | 166 | `load()` | — |
  | **283** | `applyFacet()` | **cache-HIT synchronous fast path** (the common facet path) |
  | 308 | `applyFacet()` | cache-MISS network path |
  | 362 | `applyEntryPoint()` | repo-cache hit |
  | 381 | `applyEntryPoint()` | fetched |

  `:283` and `:308` are mutually exclusive; patching only `:308` drops the lane on
  every facet applied from cache — a silent AC5 regression. To make the site count
  stop being a landmine, factor the injection into ONE private helper and route
  **every** site through it:

  ```swift
  @MainActor
  private func withSideloadedLane(_ mapped: MappedCatalog) -> CatalogContent {
    let books = sideloadedLaneBooksProvider()
    let lanes = books.isEmpty ? [] : [CatalogLaneModel(title: <"Side Loaded">, books: books, moreURL: nil)]
    return mapped.toCatalogContent(prepending: lanes)
  }
  ```

  Replace all five: sites 166/283/308 → `withSideloadedLane(mapped)`; sites
  362/381 → `withSideloadedLane(Self.mapFeed(feed, bookRegistry: bookRegistry))`.
  After the refactor there must be **exactly one** `toCatalogContent(` call in
  `CatalogViewModel.swift` (inside the helper); zero bare
  `.toCatalogContent()` calls remain.
- **Construction site (the only caller):** `AppTabHostView.swift:74-79`. Pass:
  `sideloadedLaneBooksProvider: { RemoteFeatureFlags.shared.isSideLoadingEnabled ? appContainer.sideloadedBookRegistry.allBooks : [] }`.
- Renderer: **zero changes.** `CatalogContentView.swift:104-132` iterates any
  `.grouped` lane automatically.

## Files IN scope
- `Palace/CatalogUI/ViewModels/CatalogViewModel.swift` (modify — init param +
  build lane at the `toCatalogContent()` call sites)
- `Palace/CatalogUI/ViewModels/CatalogState.swift` (modify — `toCatalogContent(prepending:)`)
- `Palace/AppInfrastructure/AppTabHostView.swift` (modify — pass provider into
  CatalogViewModel init at :74-79 ONLY; do NOT touch the `.sync()` region at :260)
- `PalaceTests/CatalogUI/SideloadedLaneTests.swift` (NEW) — plus/or extend an
  existing `CatalogState`/`CatalogViewModel` test file (document which).
- Lane title string via `Strings`/`DisplayStrings` if that's the house style;
  otherwise a literal is acceptable for a test-only feature (document choice).

## Files OFF-LIMITS
- `Palace/MyBooks/Sideload/*` (A/C), `RemoteFeatureFlags.swift`/`FirebaseManager.swift` (B),
  `AppContainer.swift` (A/C + orchestrator), `TPPSettingsView.swift` (C).
- `CatalogContentView.swift` (no render change needed — if you think you need one,
  STOP and flag it).

## Test contract
Prefer testing `toCatalogContent(prepending:)` and the provider→lane logic
directly (pure, no network):
1. Flag/provider ON + non-empty registry → returned `CatalogContent.feed` is
   `.grouped` and its first lane is the Side Loaded lane with the expected books.
2. Provider returns `[]` → content is IDENTICAL to the no-injection baseline
   (lane ABSENT) — assert the `.grouped`/`.ungrouped`/`.empty` shape is unchanged.
3. **Ungrouped base feed + provider non-empty → result is `.grouped`, Side Loaded
   lane present, AND the original ungrouped books are still reachable** (not dropped).
4. **Empty base feed + provider non-empty → `.grouped([sideloadedLane])`** (lane
   shows with no base feed — the core DRM-test requirement).
5. **`applyFacet` cache-HIT still shows the Side Loaded lane** (finding 1). Drive
   `applyFacet(_:)` on a `CatalogViewModel` whose `repository.cachedFeed(for:)`
   returns a stub feed (forcing the synchronous `:283` path) with a non-empty
   provider; assert the resulting `state.content.feed` is `.grouped` with the Side
   Loaded lane present. This is the case a per-site patch would miss — it must
   exercise the VM path, not just `toCatalogContent(prepending:)` directly.

## Verification criteria (grep-able)
- SUT instantiation: the test constructs the SUT it names — for
  `CatalogViewModel`-named methods, `grep -c "CatalogViewModel(" PalaceTests/CatalogUI/SideloadedLaneTests.swift` ≥ 1; for `toCatalogContent`-level tests, the body calls `.toCatalogContent(`.
  Run `python3 scripts/check-test-name-vs-body.py PalaceTests/CatalogUI/SideloadedLaneTests.swift` → exit 0.
- Injection present: `grep -c "prepending" Palace/CatalogUI/ViewModels/CatalogState.swift` ≥ 1.
- **Choke-point enforced (finding 1 landmine guard):**
  `grep -c "toCatalogContent(" Palace/CatalogUI/ViewModels/CatalogViewModel.swift` == 1 (only inside the helper) AND `grep -c "\.toCatalogContent()" Palace/CatalogUI/ViewModels/CatalogViewModel.swift` == 0 (no un-injected bare calls remain) AND `grep -c "withSideloadedLane(" Palace/CatalogUI/ViewModels/CatalogViewModel.swift` ≥ 5 (helper called at every former site). This assertion fails loudly if any of the 5 sites is left un-injected.
- Provider wired at construction: `grep -c "sideloadedLaneBooksProvider" Palace/AppInfrastructure/AppTabHostView.swift` == 1 and `grep -c "isSideLoadingEnabled" Palace/AppInfrastructure/AppTabHostView.swift` == 1.
- The 5 cases each exist as a named test (multi-step body check #3):
  `grep -c "func test" PalaceTests/CatalogUI/SideloadedLaneTests.swift` ≥ 5, covering grouped / ungrouped / empty / absent / **facet-cache-hit**. The cache-hit test constructs `CatalogViewModel(` and drives `applyFacet` (not just `toCatalogContent`).
- Mutation: `python3 scripts/palace_mutate.py --file Palace/CatalogUI/ViewModels/CatalogState.swift --tests PalaceTests/SideloadedLaneTests --diff-only` ≥ 50% (kill the "force-grouped removed" and "extraLanes dropped" mutants).
- `check-superpartner-spectrum.py --quiet` exit 0.
- Build clean (both targets); `scripts/verify-pr.sh --quick` PASS.
