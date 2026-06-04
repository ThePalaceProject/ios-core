---
name: swarm_f4fbef9c-contract-C-Reader2Migration
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [reader]
description: Module C — Reader2 + PDF position-write migration
---

# Module C — Reader2 + PDF position-write migration

**Status:** refined by architect 2026-05-21. PDF locked IN; one-line TPPBaseReaderViewController edit confirmed.

## In-scope files (exclusive write)

- MOD `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` (96 LOC — delegate save throttle to PositionWriter; preserve `storeReadPosition(locator:)` signature)
- MOD `Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift` (158 LOC — delegate load to PositionWriter; preserve conflict-merge semantics in this layer)
- MOD `Palace/PDF/Model/TPPPDFDocumentMetadata.swift` (PDF position-write surface at line 95 — replace `TPPAnnotations.postReadingPosition(...)` with `positionWriter.save(...)`)
- MOD `Palace/Reader2/UI/TPPBaseReaderViewController.swift` — **ONE-LINE EDIT** at line 92 to add `positionWriter:` parameter to `TPPLastReadPositionPoster(...)` constructor
- MOD `PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift` (345 LOC — adapt to delegated path; spy `PositionWriter` replaces direct network observation)
- MOD `PalaceTests/Reader2/TPPLastReadPositionSynchronizerTests.swift` (1575 LOC — adapt to delegated load path; conflict-resolution scenarios preserved)

## Out-of-scope (read-only)

- `Palace/Audiobooks/*` (Module B's territory)
- `Palace/Reader2/Bookmarks/*` (audiobook business logic + annotations; Module B owns the audiobook side)
- `PalaceTests/Reader2/PositionSyncTests.swift` (452 LOC — cross-format sync tests; preserve unchanged)
- `PalaceTests/Reader/EPUBPositionTests.swift` (regression sentinel for `throttlingInterval == 15.0` — must continue passing)
- All files in swarm-wide don't-touch list

## TPPLastReadPositionPoster — behavior carve-out

Current responsibilities (96 LOC):

1. **`storeReadPosition(locator:)`** (line 48) — public entry point. Validates locator → local save → enqueue.
2. **`shouldStore(locator:)`** (line 60) — STAYS LOCAL (EPUB-specific: requires non-zero progression OR cssSelector)
3. **`postReadPosition(locator:)`** (line 68) — throttle bookkeeping + queue. DELEGATES throttle to PositionWriter.
4. **`postQueuedReadPosition()`** (line 80) — actual `TPPAnnotations.postReadingPosition(...)` call. REPLACED by `positionWriter.save(snapshot)`.
5. **`UIApplication.willResignActiveNotification`** observer (line 38) — STAYS in the writer (PositionWriter owns background-task lifetime).

Post-migration: this class becomes ~50 LOC. Throttle state (`lastReadPositionUploadDate`, `queuedReadPosition`, `serialQueue`) DISAPPEARS — PositionWriter owns it. The locator → JSON serialization stays (it's the EPUB payload encoding).

## TPPLastReadPositionSynchronizer — behavior carve-out

Current responsibilities (158 LOC):

1. **`sync(for:book:drmDeviceID:completion:)`** (line 41) + async variant — public entry point.
2. **`syncReadPosition(...)`** (line 67) — load + conflict-merge. The load (`await TPPAnnotations.syncReadingPosition(...)`) DELEGATES to `positionWriter.load(for: book.identifier)`. The conflict rule (lines 86-91) STAYS in this class:
   ```
   guard !(deviceID == drmDeviceID && localLocation != nil)
        && localLocation?.locationString != serverLocationString else { return nil }
   ```
3. **`presentNavigationAlert(...)`** (lines 101-157) — UNTOUCHED.

The `bookmark.device` (`TPPReadiumBookmark.device`) field comes back from the existing `TPPAnnotations.syncReadingPosition` API. With the migration to `positionWriter.load`, the device field is part of `PositionSnapshot.device`. The conflict-resolution rule consumes it directly.

## Public surface (LOCKED — call sites must compile unchanged)

```swift
final class TPPLastReadPositionPoster {
    static let throttlingInterval: TimeInterval = 15.0  // unchanged sentinel; tests at PalaceTests/Reader/EPUBPositionTests.swift:114 still pin this

    init(
        book: TPPBook,
        publication: Publication,
        bookRegistryProvider: TPPBookRegistryProvider,
        positionWriter: PositionWriter? = nil  // NEW — defaulted to preserve TPPBaseReaderViewController:92 call ergonomics
    )

    func storeReadPosition(locator: Locator)  // UNCHANGED signature; callers at TPPBaseReaderViewController:316, 581
}

final class TPPLastReadPositionSynchronizer {
    init(
        bookRegistry: TPPBookRegistryProvider,
        positionWriter: PositionWriter? = nil  // NEW — defaulted
    )

    func sync(for publication: Publication, book: TPPBook, drmDeviceID: String?, completion: @escaping () -> Void)
    func sync(for publication: Publication, book: TPPBook, drmDeviceID: String?) async
}
```

## TPPBaseReaderViewController — one-line edit (line 92)

Current (lines 92-95):
```swift
lastReadPositionPoster = TPPLastReadPositionPoster(
    book: book,
    publication: publication,
    bookRegistryProvider: bookRegistry)
```

Post-migration (line 92 becomes 92-96):
```swift
lastReadPositionPoster = TPPLastReadPositionPoster(
    book: book,
    publication: publication,
    bookRegistryProvider: bookRegistry,
    positionWriter: AppContainer.production().positionWriter)
```

If Module A wires `positionWriter` into AppContainer, this works. Otherwise the defaulted `nil` parameter resolves to a freshly-constructed `RemotePositionWriter` inside the Poster's init.

**Correction to original contract:** the line-numbers listed (49, 118, 353, 618) were wrong. Verified call sites are at:
- line 35 (field decl) — unchanged
- line 92 (constructor) — one-line edit (parameter added)
- line 316 (storeReadPosition call) — unchanged
- line 581 (storeReadPosition call) — unchanged

## PDF migration (LOCKED IN — was a question, now locked)

PDF position-write currently at `Palace/PDF/Model/TPPPDFDocumentMetadata.swift:85-97`. The save path is:

```swift
let page = TPPPDFPage(pageNumber: pageNumber)
// ... build locationString + bookmarkSelector + location ...
bookRegistry.setLocation(location, forIdentifier: self.bookIdentifier)
if canSync {
    TPPAnnotations.postReadingPosition(forBook: bookIdentifier,
                                       selectorValue: bookmarkSelector,
                                       motivation: .readingProgress)
}
```

Migration: replace the `TPPAnnotations.postReadingPosition(...)` call with `positionWriter.save(...)`. Inject `positionWriter` into `TPPPDFDocumentMetadata`'s init. **The `canSync` check stays.** The `bookRegistry.setLocation` stays. Format is `.pdfPage` with `payload` = JSON-encoded `bookmarkSelector` as `Data`.

**Behavior improvement:** PDF currently has no throttle on writes; PositionWriter's 15s window now applies. This is an improvement for fast-page-flip scenarios (e.g. searching).

Audit `git grep -nE "postReadingPosition" Palace/PDF` returns the single call site at line 95 of `TPPPDFDocumentMetadata.swift`. No other PDF position-write surface.

## Throttle window — LOCKED at 15.0s

`TPPLastReadPositionPoster.throttlingInterval = 15.0` (line 15) is the source of truth. `PalaceTests/Reader/EPUBPositionTests.swift:114` pins this value as a regression sentinel. Module A's `RemotePositionWriter` default matches.

## Tests owned

### TPPLastReadPositionPosterTests refactor
- `testStoreReadPosition_validLocator_callsWriterSave` — spy `PositionWriter` records save call
- `testStoreReadPosition_zeroProgression_noCSSSelector_skipsSave` — preserve `shouldStore` predicate
- `testStoreReadPosition_zeroProgression_withCSSSelector_callsWriterSave` — preserve predicate
- `testStoreReadPosition_throttled_writerReturnsNil_locallySaved` — local save unaffected
- `testStoreReadPosition_writerError_doesNotCrash`
- `testWillResignActive_flushesQueuedPosition` — preserve background-task semantics

### TPPLastReadPositionSynchronizerTests refactor
- `testSync_writerReturnsNil_noAlertPresented`
- `testSync_remoteFromSameDevice_andLocalExists_skipsAlert` — preserve conflict rule
- `testSync_remoteDiffersFromLocal_andDifferentDevice_presentsAlert` — preserve conflict rule
- `testSync_writerThrows_logsErrorAndReturnsNil` — error path
- All other existing sync tests adapted to spy `PositionWriter.load`

## Acceptance criteria

- `TPPLastReadPositionPoster.swift` net LOC: -25 (96 → ~70). Throttle state + dispatch queue removed.
- `TPPLastReadPositionSynchronizer.swift` net LOC: -10 (158 → ~148). Only the load helper line changes.
- `TPPBaseReaderViewController.swift:92` one-line edit (parameter added). No other changes.
- `Palace/PDF/Model/TPPPDFDocumentMetadata.swift` ~3 LOC change (replace post call with save).
- `TPPLastReadPositionPosterTests` + `TPPLastReadPositionSynchronizerTests` pass.
- `PalaceTests/Reader/EPUBPositionTests.swift` (throttlingInterval sentinel) passes.
- `PalaceTests/Reader2/PositionSyncTests.swift` passes (read-only regression gate).
- No new `Date()` arithmetic for throttling in Reader2 code — that lives in PositionWriter now.

## Implementer prompt

You are Module C implementer for `swarm_f4fbef9c`. You depend on Module A's `PositionWriter` protocol — read it BEFORE starting.

**Step order:**
1. Write `transcripts/C-Reader2Migration.md` skeleton FIRST.
2. Read `TPPLastReadPositionPoster.swift`, `TPPLastReadPositionSynchronizer.swift`, and `TPPPDFDocumentMetadata.swift:85-100` to memorize the current shape.
3. Refactor `TPPLastReadPositionPoster`: delete throttle state (`lastReadPositionUploadDate`, `queuedReadPosition`, `serialQueue`). Keep `shouldStore` predicate. Keep `storeReadPosition(locator:)` signature. Replace `postReadPosition` + `postQueuedReadPosition` bodies with a single `Task { try? await positionWriter.save(snapshot) }`. Preserve `willResignActiveNotification` observer but have it call `positionWriter.save(...)` (writer flushes pending on demand).
4. Refactor `TPPLastReadPositionSynchronizer`: in `syncReadPosition(...)`, replace `await TPPAnnotations.syncReadingPosition(...)` with `await positionWriter.load(for: book.identifier)`. The returned `PositionSnapshot` deserializes back to a `Locator` via the publication. Conflict-resolution at lines 86-91 STAYS.
5. Edit `TPPBaseReaderViewController.swift:92` — ONE LINE adding `positionWriter: AppContainer.production().positionWriter`. **No other changes to that file.**
6. Edit `TPPPDFDocumentMetadata.swift` — inject `positionWriter` (defaulted to AppContainer), replace `TPPAnnotations.postReadingPosition(...)` at line 95 with `Task { try? await positionWriter.save(...) }`.
7. Refactor the two test files for the new spy-injection shape. Preserve all conflict-resolution scenarios in synchronizer tests.
8. Run `xcodebuild ... build`.
9. Run `test -only-testing:PalaceTests/TPPLastReadPositionPosterTests` and `test -only-testing:PalaceTests/TPPLastReadPositionSynchronizerTests` — both green.
10. Fill the transcript with file edits, LOC deltas, the one-line TPPBaseReaderViewController edit, PDF status (IN, locked), and any open questions.

**Throttle window LOCKED at 15.0 seconds.** Do not change `TPPLastReadPositionPoster.throttlingInterval = 15.0` — `PalaceTests/Reader/EPUBPositionTests.swift:114` pins it as a regression sentinel.

**EPUB locator serialization stays in the Reader2 layer.** `PositionSnapshot.payload` is `Data`; for `.epubLocator` format the payload is `locator.jsonString!.data(using: .utf8)!`. For `.pdfPage` the payload is the bookmark selector JSON. Format-specific encoding is the writer-consumer's responsibility, not the writer's.

Validate: full build succeeds; both Reader2 test targets pass; PositionSyncTests + ReadingPositionTests + EPUBPositionTests continue to pass.

Do NOT commit. Do NOT push. Stage for the integrator.
