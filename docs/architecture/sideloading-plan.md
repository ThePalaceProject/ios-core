<!-- audit-verified: PP-2677/2678/2679/2581/2580 fetched via jira_get_issue on 2026-07-01 -->
# Side Loading — Architecture & Implementation Plan

Covers **PP-2677** (side-load manager + settings), **PP-2678** (side-load registry),
**PP-2679** (side-loaded catalog lane). Parent investigation: **PP-2581**
("investigate side loading … most likely a test feature only exposed via the
Testing settings menu"), motivated by **PP-2580** (test LCP 2.x profiles by
loading an encrypted EPUB without a real OPDS feed).

## Goal

A **test-only** capability: import a local EPUB / PDF / audiobook file and have it
appear in a dedicated catalog lane and open in the real reader + DRM stack, with no
OPDS feed involved. Primary purpose is exercising DRM profiles (e.g. LCP 2.x)
end-to-end in the shipping reader.

## Locked decisions (2026-07-01)

1. **Registry model:** reuse the main `TPPBookRegistry` (register sideloaded books
   as `.downloadSuccessful`) **+ sync exemption**, rather than a fully independent
   open path. Reuses the entire mature reader/file/DRM/LCP stack unchanged.
   Accepted side effect: sideloaded books also appear on the My Books shelf.
2. **Gating:** a `RemoteFeatureFlags` flag with a dev-menu local override
   (mirrors `inAppPlaybackNavEnabled`) — Firebase remote default + local override,
   DEBUG-on. This is the "test mode" in PP-2679.
3. **Content types:** EPUB + PDF + audiobook from the start (infra handles all
   three uniformly via `TPPBookContentType`).

## Load-bearing constraint

The main registry's server `sync()` **evicts any book not in the loans feed and
deletes its on-disk file** — `BookRegistrySync.swift:406` seeds
`recordsToDelete = Set(registry.keys)`, removes feed entries, then at `:480-497`
un-registers the remainder and calls `deleteLocalContent` for `.downloadSuccessful`
ones. Therefore sideloaded books **must** be exempted from reconciliation, or the
next sync silently destroys them. This is the reason for decision #1's exemption set.

## Components

### PP-2678 — `SideloadedBookRegistry` (dedicated persistence, local-only)
- Own JSON manifest, separate from `registry.json`; holds sideloaded `TPPBook`s
  (via `dictionaryRepresentation()` round-trip) + original filenames. No server sync.
- API: `add(book:fileURL:)`, `remove(identifier:)`, `rename(identifier:to:)`,
  `update(book:)`, `allBooks`, `identifiers` (drives the sync-exemption set).
- Source of truth for "what is sideloaded" → feeds both the exemption set and the lane.

### PP-2677 — `SideloadedBookManager` (orchestration + settings)
- **Import:** file URL (from `UIDocumentPicker` in Settings) → classify via
  MIME/extension → `TPPBookContentType.from(...)` → mint synthetic **open-access**
  `TPPBook` (generated id, one `TPPOPDSAcquisition` with correct MIME,
  `imageCache: ImageCache.shared`, DRM-free) → copy file to
  `BookFileManager.fileUrl(for: book, account:)` → register into
  `SideloadedBookRegistry` **and** `TPPBookRegistry.addBook(.downloadSuccessful)` →
  `syncExemption.insert(id)`.
- **Remove:** reverse (file + both registries + exemption).
- **Launch rehydration:** read manifest, re-register each into main registry +
  exemption set (main registry does not persist sideloaded-ness).
- **Settings UI:** "Side Loading" entry (picker + manage list) via the
  `TPPSettings` key + `@AppStorage` pattern (`TPPSettingsView.downloadsSection` template),
  gated by the feature flag.

### Sync exemption (surgical, CRITICAL PATH)
- In `BookRegistrySync` reconciliation: `recordsToDelete.subtract(sideloadedIDs)`.
- Inject the id set from `SideloadedBookRegistry` via `AppContainer`.
- Highest-risk change → architect + SoD review required.

### PP-2679 — `SideloadedLane`
- Inject `CatalogLaneModel(title:, books: sideloadedRegistry.allBooks, moreURL: nil)`
  into the catalog lanes, gated by the feature flag.
- Seam: `CatalogViewModel.load()` / `MappedCatalog.toCatalogContent()`
  (`CatalogUI/ViewModels/CatalogState.swift:129`).
- Handle `.grouped` / `.ungrouped` / `.empty` so the lane shows even when the base
  feed isn't grouped.

## Data flow

```
Settings "Side Loading" → UIDocumentPicker → file URL
  → SideloadedBookManager.import(fileURL)
      → classify (MIME/ext → TPPBookContentType)
      → mint open-access TPPBook (sha256(id) drives file path)
      → copy file → BookFileManager content dir
      → SideloadedBookRegistry.add          (dedicated manifest — truth)
      → TPPBookRegistry.addBook(.downloadSuccessful)  (so reader works)
      → syncExemption.insert(id)
  → CatalogViewModel injects SideloadedLane (flag-gated)
  → tap book → BookDetailViewModel sees .downloadSuccessful → "Read"
  → reader resolves file via downloadCenter.fileUrl(id) → opens (LCP handled by existing stack)
```

## Key files
- New: `Palace/MyBooks/Sideload/SideloadedBookRegistry.swift`, `SideloadedBookManager.swift`
- `Palace/Packages/PalaceBookRegistry/Sources/PalaceBookRegistry/BookRegistrySync.swift` — sync exemption (critical)
- `Palace/Packages/PalacePreferences/Sources/PalacePreferences/TPPSettings.swift` + `Settings/NewSettings/TPPSettingsView.swift`
- `Palace/CatalogUI/ViewModels/CatalogViewModel.swift` / `CatalogState.swift`
- `Palace/FeatureFlags/RemoteFeatureFlags.swift` — new flag + local override
- `Palace/AppInfrastructure/AppContainer.swift` — wire services + inject exemption set

## Reference seams (from architecture map)
- `TPPBook` designated init: `Palace/Packages/PalaceBookModel/Sources/PalaceBookModel/TPPBook.swift:122`; content type via
  `defaultBookContentType` (`:669`), MIME→type `TPPBookContentType.from(mimeType:)`
  (`Palace/Packages/PalaceBookModel/Sources/PalaceBookModel/TPPContentType.swift:20`).
- `TPPBookRegistry.addBook(...)` `:387`; `setState` `:464`.
- File path resolver `BookFileManager.fileUrl(for:account:)`
  (`Palace/MyBooks/BookFileManager.swift:69`); content dir `:82`; extension `:123`.
- Registry persistence `BookRegistrySync.swift` (registry.json under Application Support).
- Lane model `CatalogLaneModel` (`CatalogUI/ViewModels/CatalogViewModel.swift:417`);
  feed→lanes `mapFeed` `:444`; render `CatalogContentView.swift:104`.
- Settings toggle pattern `TPPSettingsView.swift:244`; keys `TPPSettings.swift:62-73`.
- Feature-flag template `RemoteFeatureFlags.inAppPlaybackNavEnabled` `:54` +
  local-override switch `:462`.

## Verification

1. **Unit (TDD, mandated by all three tickets):**
   - `SideloadedBookRegistry`: manifest round-trip (persist→reload→identical),
     add/remove/rename/update, edge cases (duplicate import, missing file, corrupt/
     empty manifest, unsupported type).
   - `SideloadedBookManager`: classification per type (EPUB/PDF/audiobook MIME →
     correct `defaultBookContentType`), open-access minting, dedup, error paths,
     exemption-set maintenance, launch rehydration.
   - **Sync-exemption regression (critical):** drive `sync()` with a loans feed
     lacking the sideloaded id → assert book + file survive.
   - Lane injection: flag on + non-empty registry → lane present; flag off → absent;
     empty/ungrouped base feed → lane still present.
2. **Contract-snapshot** for the import pipeline (ordered calls: classify → copyFile →
   registry.addBook → sideloadRegistry.add → exemption.insert).
3. **Mutation** (`palace_mutate.py --diff-only`) on manager + registry, ≥50%
   (critical-path files → 100% on touched lines).
4. **Build + `scripts/verify-pr.sh --quick`** (full-suite parity).
5. **simdrive E2E:** enable in Settings → import the LCP 2.x test EPUB (PP-2580) →
   see lane → open in reader → renders. Record a replay for the chaos-replay corpus.
6. **DoD 11-check battery** before READY.

## Orchestration
Spans ≥2 modules (Book/registry, MyBooks, Settings, CatalogUI) **and** touches a
critical path (registry sync + DRM) → implement via **`/swarm`** with architect +
SoD review focused on the sync-exemption change.

## Open items / risks
- **My Books visibility:** decision #1 makes sideloaded books appear on the My Books
  shelf. Acceptable for a test feature; revisit if noise is a problem (could filter
  by exemption-id membership).
- **Persistence location:** ticket says "Documents folder"; the app's registry lives
  under Application Support. Recommend Application Support (consistent, backup-excluded)
  and treat the ticket wording as illustrative — confirm during implementation.
- **Sync-exemption ordering:** rehydration must populate the exemption set *before*
  the first `sync()` after launch, or a race could still evict. Wire rehydration into
  `AppContainer` startup ahead of the sync trigger.
