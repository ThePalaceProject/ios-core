<!-- audit-verified: PP-2677/2678/2679/2581/2580 fetched via jira_get_issue on 2026-07-01 -->
# Side Loading — Architecture

Status: shipped in #1157 (PP-2677, PP-2678, PP-2679).

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
   (mirrors `inAppPlaybackNavEnabled`) — Firebase remote default + local override.
   This is the "test mode" in PP-2679. <!-- audit-verified -->
   The flag is OFF in every build: the registered Remote Config default is
   `false` and there is no DEBUG-on fallback, so the Testing-screen toggle is
   the only way to turn it on without a global Firebase change (it does not
   opt into the per-device override).
3. **Content types:** EPUB + PDF + audiobook from the start (infra handles all
   three uniformly via `TPPBookContentType`).

## Load-bearing constraint

The main registry's server `sync()` **evicts any book not in the loans feed and
deletes its on-disk file**. `BookRegistrySync.sync()` computes the delete set with
`LoansFeedReconciliation.identifiersToRemove` (local ids minus feed ids), then
un-registers each one and calls `deleteLocalContent` for `.downloadSuccessful` and
`.used` records. Sideloaded books therefore must be exempted from reconciliation, or
the next sync destroys them. This is the reason for decision #1's exemption set:
`identifiersToRemove` also subtracts `sideloadedIdentifiers`.

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
- In `BookRegistrySync` reconciliation, `LoansFeedReconciliation.identifiersToRemove`
  subtracts the sideloaded ids from the delete set.
- The id set comes from `SideloadedBookRegistry.identifiers` through
  `RegistryExternalDependencies.sideloadedIdentifiers`, wired in `AppContainer`.

### PP-2679 — `SideloadedLane`
- Inject `CatalogLaneModel(title:, books: sideloadedRegistry.allBooks, moreURL: nil)`
  into the catalog lanes, gated by the feature flag.
- Seam: `CatalogViewModel` passes its sideloaded lanes to
  `MappedCatalog.toCatalogContent(prepending:)` (`CatalogUI/ViewModels/CatalogState.swift`).
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
- `Palace/MyBooks/Sideload/SideloadedBookRegistry.swift`, `SideloadedBookManager.swift`
- `Palace/Packages/PalaceBookRegistry/Sources/PalaceBookRegistry/BookRegistrySync.swift`
  and `LoansFeedReconciliation.swift` — sync exemption (critical)
- `Palace/Packages/PalacePreferences/Sources/PalacePreferences/TPPSettings.swift`,
  `Palace/Settings/NewSettings/TPPSettingsView.swift`, `SideLoadingView.swift`
- `Palace/CatalogUI/ViewModels/CatalogViewModel.swift` / `CatalogState.swift`
- `Palace/FeatureFlags/RemoteFeatureFlags.swift` — flag + local override
- `Palace/AppInfrastructure/AppContainer.swift` — wires services + the exemption set

## Reference seams
- `TPPBook` designated init and `defaultBookContentType`
  (`Palace/Packages/PalaceBookModel/Sources/PalaceBookModel/TPPBook.swift`); MIME→type
  `TPPBookContentType.from(mimeType:)` (`TPPContentType.swift` in the same package).
- `TPPBookRegistry.addBook(...)` / `setState`
  (`Palace/Packages/PalaceBookRegistry/Sources/PalaceBookRegistry/TPPBookRegistry.swift`).
- File path resolver `BookFileManager.fileUrl(for:account:)`, `contentDirectoryURL`,
  `pathExtension(for:)` (`Palace/MyBooks/BookFileManager.swift`).
- Registry persistence `BookRegistrySync.swift` (registry.json under Application Support).
- Lane model `CatalogLaneModel` and feed→lanes `mapFeed`
  (`CatalogUI/ViewModels/CatalogViewModel.swift`); render `CatalogUI/Views/CatalogContentView.swift`.
- Feature-flag template `RemoteFeatureFlags.inAppPlaybackNavEnabled` and its local-override switch.

## Known limits and constraints
- **My Books visibility:** decision #1 makes sideloaded books appear on the My Books
  shelf. Accepted for a test feature; filtering by exemption-id membership is the
  option if it becomes noise.
- **Persistence location:** the manifest lives under Application Support, next to
  the main registry, not in Documents as the ticket wording suggests.
- **Exemption does not depend on rehydration:** sync reads
  `SideloadedBookRegistry.identifiers`, which the registry loads from its manifest
  when it is created, so a sync that runs before launch rehydration does not evict
  sideloaded books.
  Rehydration into the main registry runs in the `TPPBookRegistry.load(completion:)`
  callback (`TPPAppDelegate`), because a rehydrate before the disk snapshot lands is
  overwritten when the store becomes `.loaded`.
