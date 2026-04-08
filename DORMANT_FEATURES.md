# Dormant Features — Wiring Instructions for Future Implementation

This document tracks features that have **production source code on disk** but are **not yet wired into any build target**. They were authored during the modernization sprint as the foundation of upcoming product work and are intentionally held dormant until the team is ready to ship them with the matching developer-settings toggles.

**Why dormant rather than deleted:** these are real product features tied to the Palace product vision (AI cross-library discovery, CarPlay/CarMode, Social collections). The code exists, the tests exist, and the design is in place — they just need pbxproj wiring and a developer-settings toggle when the team is ready.

**Why not wired now:** wiring them is a multi-step operation:
1. Add 33+ production `.swift` files to `Palace` and `Palace-noDRM` Sources build phases
2. Likely surface compile drift in the orphaned source files (they were written some time ago)
3. Triage and fix any drift
4. Add developer-settings toggles (3 new BOOL keys + plumbing)
5. Wire ~12 corresponding test files into PalaceTests
6. Run tests, fix any drift

This belongs in a focused sprint, not in the middle of a test-cleanup pass.

---

## Feature 1 — CarMode

**What it is:** Bluetooth-aware "in-car" UI mode for the audiobook player. When the phone connects to a car's Bluetooth and audio is playing, the audiobook UI flips to a large-button "car mode" with simplified controls (play/pause, chapter list, sleep timer, speed picker).

**Production source files (12, all currently dormant):**
```
Palace/Audiobooks/CarMode/BluetoothCarModeDetector.swift
Palace/Audiobooks/CarMode/CarModeChapterList.swift
Palace/Audiobooks/CarMode/CarModeEntryButton.swift
Palace/Audiobooks/CarMode/CarModeService.swift
Palace/Audiobooks/CarMode/CarModeServiceProtocol.swift
Palace/Audiobooks/CarMode/CarModeSleepTimerPicker.swift
Palace/Audiobooks/CarMode/CarModeSpeedPicker.swift
Palace/Audiobooks/CarMode/CarModeState.swift
Palace/Audiobooks/CarMode/CarModeView.swift
Palace/Audiobooks/CarMode/CarModeViewModel.swift
Palace/Audiobooks/CarMode/PlaybackSpeed.swift
Palace/Audiobooks/CarMode/SleepTimerOption.swift
```

**Test files (4, currently dormant; PBXFileReference exists, Sources phase entry doesn't):**
```
PalaceTests/Audiobooks/CarMode/BluetoothCarModeDetectorTests.swift
PalaceTests/Audiobooks/CarMode/CarModeServicePlaybackTests.swift
PalaceTests/Audiobooks/CarMode/CarModeServiceTests.swift
PalaceTests/Audiobooks/CarMode/CarModeViewModelTests.swift
PalaceTests/Audiobooks/CarMode/PlaybackSpeedConversionTests.swift  (orphaned in Sources only)
PalaceTests/Audiobooks/CarMode/SleepTimerTests.swift              (orphaned in Sources only)
```

**Test method count:** ~111 across the 6 test files.

**Wiring steps when ready:**
1. Add the 12 `.swift` files to `Palace` and `Palace-noDRM` Sources build phases. The existing helper `scripts/add_files_to_pbxproj.py` already lists these files in `MAIN_FILES` — verify the IDs in `PALACE_SOURCES_ID` and `NODERM_SOURCES_ID` constants are still correct, then run it.
2. `xcodebuild build` — surface and fix any compile drift.
3. Add the test files to `PalaceTests` Sources phase using `scripts/wire_orphan_tests.py` after writing the orphan basenames to `/tmp/orphans.txt`.
4. `xcodebuild test -only-testing:PalaceTests/CarModeServiceTests ...` — run the test classes by their actual class names (not file basenames; the file may contain multiple classes).
5. Add a developer-settings toggle: a new `BOOL` `enableCarMode` in `Palace/Settings/DeveloperSettings/`. Wire the toggle to `BluetoothCarModeDetector.isEnabled` or whatever feature-flag accessor the code expects.
6. Test on a physical device with a real car Bluetooth pairing.

---

## Feature 2 — Discovery (AI Cross-Library Search)

**What it is:** The competitive differentiator from the product vision — "AI-powered cross-library discovery" using the Claude API to search across all configured libraries simultaneously and prioritize titles available right now. See `~/Desktop/forgeos-private/ios-core/Palace-Product-Plan.md` for the full design.

**Production source files (17 unique, all currently dormant):**
```
Palace/Discovery/DiscoveryTab.swift
Palace/Discovery/Models/CrossLibrarySearchResponse.swift
Palace/Discovery/Models/DiscoveryPrompt.swift
Palace/Discovery/Models/DiscoveryRecommendation.swift
Palace/Discovery/Models/LibrarySearchResult.swift
Palace/Discovery/Services/ClaudeDiscoveryService.swift
Palace/Discovery/Services/CrossLibrarySearchService.swift
Palace/Discovery/Services/DiscoveryConfiguration.swift
Palace/Discovery/Services/DiscoveryServiceProtocol.swift
Palace/Discovery/Services/LocalDiscoveryFallback.swift
Palace/Discovery/ViewModels/DiscoveryViewModel.swift
Palace/Discovery/ViewModels/SearchResultsViewModel.swift
Palace/Discovery/Views/CrossLibraryAvailabilityView.swift
Palace/Discovery/Views/DiscoveryView.swift
Palace/Discovery/Views/RecommendationCard.swift
Palace/Discovery/Views/SearchResultsView.swift
```

**Test files (8, currently dormant — PBXFileReference exists for some):**
```
PalaceTests/Discovery/ClaudeDiscoveryServiceTests.swift
PalaceTests/Discovery/CrossLibrarySearchServiceTests.swift
PalaceTests/Discovery/DiscoveryConfigurationTests.swift
PalaceTests/Discovery/DiscoveryModelTests.swift
PalaceTests/Discovery/DiscoveryViewModelTests.swift
PalaceTests/Discovery/LocalDiscoveryFallbackTests.swift
PalaceTests/Discovery/SearchResultsViewModelTests.swift
```

**Test method count:** ~95 (DiscoveryModelTests alone has 30; ClaudeDiscoveryServiceTests has the bulk of the integration coverage).

**External dependencies:** This feature requires a Claude API key. The current code in `ClaudeDiscoveryService` uses `LocalDiscoveryFallback` when no key is configured, so the wiring path can ship even without a key (with reduced functionality).

**Wiring steps when ready:**
1. Decide on Claude API key storage strategy. Either:
   - Add a developer-settings field for a user-supplied key (best for staged rollout)
   - Or bake into `TPPSecrets` for a controlled launch
2. Add the 17 production `.swift` files to `Palace` and `Palace-noDRM` Sources phases via `scripts/add_files_to_pbxproj.py` (the file lists most of these already; verify and run).
3. Build, fix compile drift.
4. Wire the 8 test files via `scripts/wire_orphan_tests.py`.
5. Run tests with stubbed Claude responses (the existing `LocalDiscoveryFallbackTests` and `MockClaudeDiscoveryService` patterns are designed for this).
6. Add `enableAIDiscovery` BOOL to developer settings. Gate the `DiscoveryTab` registration in `MainTabBarController` (or wherever tabs are configured) on this flag.
7. Add the Discovery tab UI behind the flag.
8. Manual test against a sandbox library with the Claude key configured.
9. Telemetry: instrument `CrossLibrarySearchService` request/response timing for the Phase 1 release.

---

## Feature 3 — Collections (Social Sub-feature)

**What it is:** User-curated "collections" feature — letting users group books into themed shelves (e.g., "summer reading," "for the kids"), share them, and follow other users' collections. This is the smaller sibling of the larger Social feature (which IS already wired — activity feed, book reviews, sharing).

**Production source files (5, all dormant; the rest of `Palace/Social/` IS in the build):**
```
Palace/Social/ViewModels/CollectionsViewModel.swift
Palace/Social/Views/CollectionsTab.swift
Palace/Social/Views/CollectionsView.swift
Palace/Social/Views/AddToCollectionButton.swift
Palace/Social/Views/AddToCollectionSheet.swift
```

**Test files (1, dormant due to drift):**
```
PalaceTests/Social/CollectionsViewModelTests.swift
PalaceTests/Social/CollectionDetailViewModelTests.swift  (drift: missing MockBookCollectionService)
```

**Test method count:** ~18.

**Note:** `BookCollectionService.swift`, `BookCollectionServiceProtocol.swift`, `CollectionDetailViewModel.swift`, `CollectionDetailView.swift`, and the `BookCollection` model itself ARE already in the build. Only the *list* layer (CollectionsViewModel, CollectionsTab, CollectionsView, the add-to-collection UI) is dormant. The detail layer is half-shipped.

**Wiring steps when ready:**
1. Add the 5 source files to `Palace` and `Palace-noDRM` Sources phases.
2. Build, fix any drift (likely small — most of Social is already wired and stable).
3. Wire `CollectionsViewModelTests` and add the missing `MockBookCollectionService` (or use the existing `BookCollectionServiceMock` if one is available — there's a `MockCatalogRepository`-style pattern in `PalaceTests/Mocks/` to follow).
4. Add `enableCollections` BOOL to developer settings.
5. Wire the `CollectionsTab` into the tab bar behind the flag.
6. Done — this is the lowest-risk of the three dormant features.

---

## Why one big "feature wiring" sprint vs. piecemeal

The temptation is to wire one feature at a time. Don't:
- All three dormant features share the same scripts and patterns (`add_files_to_pbxproj.py`, `wire_orphan_tests.py`, developer-settings plumbing)
- Each one likely requires the same drift-fixing pass
- The pbxproj-edit risk is identical whether you wire 5 files or 33
- The dev-settings UI is one screen with three new toggles, not three separate UI passes

Plan for one focused 1-2 day sprint that ships all three behind feature flags. Then you can promote each independently in a follow-up release as the team validates them.

---

## Verification scripts in this repo

| Script | What it does |
|---|---|
| `scripts/add_files_to_pbxproj.py` | Original script with the CarMode + Discovery + Stats source file lists. Verify constants before running. |
| `scripts/wire_orphan_tests.py` | Idempotent wiring of orphan test files into PalaceTests Sources phase. Reads `/tmp/orphans.txt`. |
| `scripts/add_test_modules_to_pbxproj.py` | Adds new test directories to PalaceTests with PBXGroup creation. Use this pattern when adding the Discovery test directory if it doesn't have a group yet. |
| `scripts/test_coverage_classifier.py` | Reads `xcrun xccov` output and buckets uncovered files by `{unit, integration, snapshot, e2e, none}`. Use after wiring to identify which tests to write next. |
| `scripts/palace_mutate.py` | Focused Swift mutation tester. Use after wiring tests to verify they have real assertions, not just decoration. |

## Related git commits (this repo, on `modernize/whole-shot`)

| Commit | Subject |
|---|---|
| `ef65cd026` | Test infrastructure: chaos, security, property, fuzz, a11y, coverage gate (Round 1+2 — categorical-gap test infra + production seams) |
| `e08d0a15e` | Add palace-mutate: focused Swift mutation tester |
| `40b96fa0c` | Add test coverage classifier — turn xccov into a sprint plan |
| `8b9cd9b32` | Wave 1 unit-test coverage + resurrect 14 orphaned test files |
| `eaebff638` | Phase B drift fixes: NetworkClient + ReaderTheme |
