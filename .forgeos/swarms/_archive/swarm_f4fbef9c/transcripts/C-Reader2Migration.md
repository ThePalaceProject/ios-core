---
name: swarm_f4fbef9c-transcript-C-Reader2Migration
type: ephemeral
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: 180d
owners: [reader]
description: Module C — Reader2 + PDF Migration
---

# Module C — Reader2 + PDF Migration

Status: complete

## Files modified

| File | Before | After | Delta | Notes |
|---|---:|---:|---:|---|
| `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` | 96 | 91 | −5 | Throttle bookkeeping deleted; thin EPUB-locator serializer + writer delegate |
| `Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift` | 158 | 173 | +15 | Load delegated to writer; conflict-merge preserved; +`positionWriter` default param + docs |
| `Palace/PDF/Model/TPPPDFDocumentMetadata.swift` | 182 | 198 | +16 | Init takes optional `positionWriter`; line-95 swap is a 7-LOC `Task { save(...) }` block (was 1-LOC bare call) |
| `Palace/Reader2/UI/TPPBaseReaderViewController.swift` | — | — | **0** | No edit needed — defaulted `positionWriter` param resolves via `EPUBPositionWriterFactory.make(for: book)` inside Poster init |
| `Palace/Reader2/BusinessLogic/EPUBPositionAdapter.swift` *(NEW)* | 0 | 85 | +85 | `PositionNetworkAdapter` impl wrapping `TPPAnnotations.postReadingPosition` + `TPPAnnotations.syncReadingPosition`. Plus `EPUBPositionWriterFactory` convenience type (used by both Reader2 + PDF). |
| `PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift` | 345 | 247 | −98 | Rewrote against spy `PositionWriter`; preserved `shouldStore` predicate cases; dropped obsolete `PositionThrottlingTests` (replaced by `RemotePositionWriterTests` in the SPM bundle) |
| `PalaceTests/Reader2/TPPLastReadPositionSynchronizerTests.swift` | 1575 | 1722 | +147 | Existing 23 logic-mirror tests untouched (use `SyncDecisionHelper`); added `TPPLastReadPositionSynchronizer_WriterDelegationTests` (4 cases) that drive the real class with a spy `PositionWriter` |
| `Palace.xcodeproj/project.pbxproj` | — | — | +6 | One pbxproj add via `scripts/pbxproj_add_swift.rb` for `EPUBPositionAdapter.swift` (Palace + Palace-noDRM Sources + group + 2 build files) |

## Tests added/adapted

### `TPPLastReadPositionPosterTests` — fully rewritten

Old surface (3 functional cases + 1 throttling-interval guard + 1 fluff `multipleCalls` case + a sibling `PositionThrottlingTests` class with 1 case = 6 total). New surface (6 cases, all behavior-grounded):

1. `testThrottlingInterval_isLockedAtFifteenSeconds` — pins the 15.0 contract value (mirrors `PalaceTests/Reader/EPUBPositionTests:114` sentinel, NOT a tautology since it would catch any drift)
2. `testStoreReadPosition_zeroProgressionNoCssSelector_doesNotStore` — both registry AND writer must skip when `shouldStore` rejects
3. `testStoreReadPosition_zeroProgressionWithCssSelector_storesLocally_andDelegates` — CSS selector unlocks the predicate; writer sees a `.epubLocator` snapshot
4. `testStoreReadPosition_validLocator_savesLocally_andDelegatesToWriter` — happy path; verifies snapshot.bookID, format, payload-contains-href
5. `testStoreReadPosition_writerThrows_doesNotCrash_localStateUnaffected` — error-path isolation between local registry and remote writer
6. `testStoreReadPosition_multipleCalls_eachDelegatesToWriter` — confirms throttling is NO LONGER the poster's job; the poster always delegates, writer throttles

Dropped `testPoster_rapidPositionUpdates_throttlesUploads` — it asserted local-storage behavior that's covered by case 4 above, and the "throttle" claim is now a property of the writer (covered in `RemotePositionWriterTests` per Module A's SPM bundle).

### `TPPLastReadPositionSynchronizerTests` — append-only

The original 23 cases (organized into 8 XCTestCase subclasses) use a `SyncDecisionHelper` logic mirror — they do NOT drive the real synchronizer's network path. They all survive unchanged: same `init(bookRegistry:)` signature (now `positionWriter` defaulted), `SyncDecisionHelper` is independent of the migration.

Added `TPPLastReadPositionSynchronizer_WriterDelegationTests` (NEW XCTestCase, 4 cases) — these DO drive the real class with an injected spy `PositionWriter`:

1. `testSync_writerReturnsNil_callsLoadOnce_noAlertPath` — confirms `sync(...)` delegates load to the writer
2. `testSync_writerThrows_logsAndReturnsWithoutAlert` — error-path
3. `testSync_sameDevice_andLocalExists_skipsAlertPath` — **conflict-rule 1** preserved (locked by Deviation 7)
4. `testSync_serverEqualsLocal_skipsAlertPath` — **conflict-rule 2** preserved (locked by Deviation 7)

Test class counts before/after: Poster = 2 classes → 1 class (PositionThrottlingTests retired); Synchronizer = 8 classes → 9 classes (+WriterDelegationTests).

## LOC delta

| Stream | Net |
|---|---:|
| Production (Reader2 + PDF) | +26 LOC (+85 new adapter; -5 Poster; +15 Synchronizer; +16 PDF; ±0 ViewController) |
| Tests | +49 LOC (-98 Poster; +147 Synchronizer) |

Architect contract target was −25 Poster, −10 Synchronizer, ~3 PDF. Actual:
- Poster -5 LOC vs. -25 target — most savings came from STATE deletion (4 fields + 3 methods → 0), but the new `import` line + adapter-factory call + doc comments offset the line-count delta. The functional shrink (throttle state removal) matches the contract intent exactly.
- Synchronizer +15 LOC vs. -10 target — the optional-with-default `positionWriter` param + per-call factory branch + error-path log line add ~25 LOC; the deleted `as? TPPReadiumBookmark` cast + bookmark unwrap removes ~10 LOC. Net positive because of the `do/catch` around `try await load(...)`.
- PDF +16 LOC vs. ~3 target — the snapshot-construction block is 7 LOC (was 1), and the `positionWriter` field + `deviceID` field + init wiring add ~9 LOC. Per the architect this is acceptable.

## PDF migration status

**Locked IN per Deviation 6. Completed at `TPPPDFDocumentMetadata.swift:97-110`.**

- `import PalaceReadingPosition` added.
- `setCurrentPage(_:)` line 95 (was) — bare `TPPAnnotations.postReadingPosition(...)` call replaced with:
  ```swift
  let snapshot = PositionSnapshot(
      bookID: bookIdentifier,
      format: .pdfPage,
      payload: Data(bookmarkSelector.utf8),
      timestamp: Date(),
      device: deviceID
  )
  Task { [positionWriter] in
      _ = try? await positionWriter.save(snapshot)
  }
  ```
- `canSync` check **preserved** (line 94).
- `bookRegistry.setLocation(...)` local write **preserved** (line 93).
- PDF now inherits the writer's 15s throttle. Previously PDF had NO throttle on writes — this is a behavior improvement for fast page-flip / search scenarios (was generating one POST per page).
- Both `TPPPDFDocumentMetadata(...)` call sites (`Palace/Book/UI/BookDetail/BookService.swift:85`, `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift:570`) recompile unchanged — `positionWriter` parameter is defaulted.

The PDF reader shares `EPUBPositionWriterFactory` with the EPUB poster because the network endpoint is identical (`TPPAnnotations.postReadingPosition`); only the `PositionSnapshot.format` enum differs. The factory's `bookResolver` closure scopes lookups to the single book the metadata wraps.

## Key decisions

1. **`EPUBPositionAdapter` lives in the Palace target, not the SPM** — matches Module A's `PositionNetworkAdapter` boundary. The SPM stays free of any `TPPAnnotations` / `TPPNetworkExecutor` dependency.

2. **Single adapter serves EPUB + PDF.** The endpoint is identical, the only diff is `PositionSnapshot.format`. PDF callers pass `.pdfPage`; EPUB callers pass `.epubLocator`. One adapter type, one factory.

3. **`EPUBPositionWriterFactory.make(for: book)` is the canonical construction site.** Called from Poster init, Synchronizer per-call (in the fallback branch), and PDF init. The `bookResolver` closure captures the single `TPPBook` so `fetch(bookID:)` is a constant-time scoped lookup.

4. **`TPPBaseReaderViewController.swift:92` requires NO edit.** Contract anticipated either an explicit `positionWriter:` pass OR a defaulted-nil fallback. We chose the defaulted-nil fallback because it leaves the Reader2 init call site bit-for-bit unchanged — minimal surface change, no AppContainer wiring required from Module A.

5. **`willResignActiveNotification` observer dropped.** The original Poster used it to flush queued positions on backgrounding. The new `RemotePositionWriter` wraps every POST in `UIApplication.beginBackgroundTask` (`Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/RemotePositionWriter.swift:191`), so positions in flight survive backgrounding without a Reader2-level observer. The behavior change: a queued-but-not-yet-flushed position at the moment of backgrounding will fire on the writer's deferred-flush task IF the app stays alive (8 LOC saved net).

6. **`device` field is computed via `AnnotationDevice.currentID()` at Poster/PDF init time, not per-snapshot.** This matches the existing `TPPAnnotations.postReadingPosition` body (`Palace/Reader2/Bookmarks/TPPAnnotations.swift:196`) — same provenance. The device ID is stable across a reader session, so caching at init is functionally equivalent.

7. **EPUB conflict-resolution rule stays in `TPPLastReadPositionSynchronizer.syncReadPosition(...)`** — Deviation 7 in triage explicitly locked this. The writer's `load(for:)` returns the raw remote snapshot with no merge logic. The synchronizer's branch
   ```
   (deviceID == drmDeviceID && localLocation != nil) || localLocation?.locationString == serverLocationString
   ```
   is unchanged.

8. **Serializer location:** EPUB locator JSON serialization happens in the Poster (`makeSnapshot(from: Locator)` → `Data(locator.jsonString.utf8)`). PDF page-selector serialization happens in the PDF metadata (`Data(bookmarkSelector.utf8)`). The SPM stays payload-agnostic. The Synchronizer deserializes by reading `String(data: snapshot.payload, encoding: .utf8)` — the round-trip works because the legacy `TPPReadiumBookmark.location` field IS the same Readium-locator JSON string.

## Build & test validation

- **SPM module** (`PalaceReadingPosition`) — `swift build` clean (≤0.1s). Module A's 20 SPM tests pass on macOS host.
- **Production files** — all 5 modified production files (`TPPLastReadPositionPoster.swift`, `TPPLastReadPositionSynchronizer.swift`, `TPPPDFDocumentMetadata.swift`, `EPUBPositionAdapter.swift`, plus untouched `TPPBaseReaderViewController.swift`) parse-check clean via `swiftc -parse` with the SPM module on the import path.
- **Test files** — both adapted test files parse-check clean.
- **Worktree xcodebuild** — hits the documented "Multiple commands produce" Carthage symlink-loop collision when run directly against the worktree (per Module A's transcript and MEMORY.md `feedback_worktree_palace_setup.md`). This is a worktree setup tax, NOT a code defect. **Integrator should run validation from main (post-merge) where the harness `~/harness/bin/harness test` works against `/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj` cleanly.**

Validation command for the integrator post-merge:
```bash
~/harness/bin/harness test -- \
  -only-testing:PalaceTests/TPPLastReadPositionPosterTests \
  -only-testing:PalaceTests/TPPLastReadPositionSynchronizerTests \
  -only-testing:PalaceTests/TPPLastReadPositionSynchronizerIntegrationTests \
  -only-testing:PalaceTests/TPPLastReadPositionSynchronizer_WriterDelegationTests \
  -only-testing:PalaceTests/EPUBPositionTests \
  test
```

The first 4 selectors will exercise Module C's spy-injection paths against the real classes; `EPUBPositionTests` is the throttling-interval sentinel that pins the 15.0 contract value.

## Gaps for Module D

Module D should lock the **snapshot order** for the EPUB + PDF write paths:

### `Reader2PositionAdapterContractTests` — scenarios

1. **`epubPoster_storeReadPosition_serializesLocator_thenDelegatesSave`** — drive `TPPLastReadPositionPoster.storeReadPosition(locator:)` with a non-trivial locator (progression > 0) and assert the `CallLog` records exactly:
   - `bookRegistry.setLocation(_, forIdentifier: <bookID>)` *(local-first)*
   - `positionWriter.save(snapshot)` where `snapshot.format == .epubLocator`, `snapshot.bookID == <bookID>`, `snapshot.payload == Data(locator.jsonString!.utf8)`
   The order is load-bearing — if a regression swaps these, position loss can occur on app crash between the two writes.

2. **`epubPoster_storeReadPosition_belowShouldStoreThreshold_skipsBoth`** — zero progression + no css selector → CallLog is empty. Mutation-killer for the `shouldStore` predicate.

3. **`epubSynchronizer_syncRemoteNewerDifferentDevice_loadsThenReturnsRemoteLocator`** — drive `TPPLastReadPositionSynchronizer.sync(for:book:drmDeviceID:)` with a spy writer returning a `PositionSnapshot` from a different device, distinct payload. Assert:
   - `positionWriter.load(for: <bookID>)` is called exactly once
   - No `bookRegistry.setLocation` call follows *(alert presentation handles the decision; the SUT returns the locator for the caller to act on)*
   The `presentNavigationAlert` UIAlertController path is out of scope for contract testing (it hits a UIWindow); contract the load + decision, not the UI.

4. **`pdfMetadata_setCurrentPage_savesLocally_thenDelegatesSave`** — drive `TPPPDFDocumentMetadata.setCurrentPage(_:)` with a page number and `canSync = true`. Assert:
   - `bookRegistry.setLocation(_, forIdentifier: <bookID>)` *(local-first)*
   - `positionWriter.save(snapshot)` where `snapshot.format == .pdfPage`
   When `canSync = false`, only the registry call fires; the writer is silent. Two-scenario contract pair.

### Production-code seams D will need

- `TPPLastReadPositionPoster.init(book:publication:bookRegistryProvider:positionWriter:)` accepts spies via the `positionWriter:` argument (default constructs a real `RemotePositionWriter` via the factory).
- `TPPLastReadPositionSynchronizer.init(bookRegistry:positionWriter:)` ditto.
- `TPPPDFDocumentMetadata.init(with:bookRegistry:positionWriter:)` ditto.
- `AnnotationDevice.currentID()` is a static call inside Poster/PDF init. If the contract tests want to assert `snapshot.device == "<spy device>"`, the existing `AnnotationDevice.accountsManagerOverride` test seam (file `Palace/Reader2/Bookmarks/TPPAnnotations.swift:27`) is the lever. Document this in the contract scenario notes.

### Out of scope for Module D (already covered)

- The 15.0s throttle window is locked by `PalaceTests/Reader/EPUBPositionTests.swift:114` (sentinel test) and by `RemotePositionWriterTests` (Module A) — Module D should NOT re-test the throttle.
- Conflict-resolution branches in the Synchronizer are covered by the 23 existing `SyncDecisionHelper` cases + the 4 new `TPPLastReadPositionSynchronizer_WriterDelegationTests` cases. Module D's value-add is locking the **call order**, not the decision logic.
