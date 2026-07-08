---
name: pp-4161-streaming-html-reader
created: 2026-06-03
author: claude-opus-4-7
---

## Summary

PP-4161: Palace iOS currently drops OPDS2 publications whose only acquisition
leaf is `text/html;profile=http://librarysimplified.org/terms/profiles/streaming-media`
(see PR #847 filter at `Palace/OPDS2/Models/OPDS2PublicationExtended.swift:264-282`).
Palace web and Palace Android render those titles via a WKWebView-style streaming
reader; iOS has never supported it, so users miss content (e.g. Palace Bookshelf
medical journal articles, public-domain papers).

Add full in-app support: recognize the streaming-media MIME, plumb it through the
acquisition / content-type layers, surface a "Read" action on Book Detail that
borrows via the CM-mediated loan and opens a new WKWebView-based streaming reader
(`Palace/ReaderStreaming/`) with the standard reader chrome — Close, scroll, and
per-book progress persistence. Reuse the existing borrow path; do not invent a
new fulfillment flow. Verify end-to-end with a new simdrive journey covering
catalog → borrow → open → scroll → close → reopen-at-saved-position.

## Claims

### OPDS / acquisition layer (PalaceCatalog SPM module)
- adds content-type constant `ContentTypeStreamingHTML` =
  `"text/html;profile=http://librarysimplified.org/terms/profiles/streaming-media"`
  to `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSAcquisitionPath.swift`
- adds `ContentTypeStreamingHTML` to `TPPOPDSAcquisitionPath.supportedTypes()`
- adds `ContentTypeStreamingHTML` as a leaf in `TPPOPDSAcquisitionPath.supportedSubtypes(forType: ContentTypeOPDSPublication)`
- adds `ContentTypeStreamingHTML` to OPDS1 entry / OPDS2 publication parsing so
  the leaf MIME survives into TPPOPDSAcquisition

### Content-type / book model layer
- adds enum case `streamingHTML` to `Palace/Book/Models/TPPContentType.swift`
- adds `TPPContentType.from(mimeType:)` recognition for `ContentTypeStreamingHTML`
- adds computed property `TPPBook.isStreamingHTML: Bool` driven by the supported-
  acquisition-path scan
- updates `OPDS2PublicationExtended.toBook()` filter at line 264-282 so streaming-
  media-only publications pass through (drops the only-format-is-streaming-media
  case from the skip path)

### Book Detail / button layer
- adds `BookButtonType.readStreaming` case (exhaustive switches in
  `BookDetailView.swift`, `HalfSheetview.swift`, `BookDetailViewModel.swift`,
  `BorrowReducer.swift`, `BookButtonMapper.swift` will all flag — each updated)
- adds "Read" action handler in `BookDetailViewModel.handleAction(for:)` that
  presents the new streaming reader after the borrow URL fulfills
- localized button label `Strings.BookDetailView.readStreaming` (or reuses
  existing "Read" string with the streamingHTML codepath)

### Streaming reader (new module)
- adds new directory `Palace/ReaderStreaming/` with:
  - `StreamingReaderViewController.swift` — UIKit shell hosting WKWebView, Close
    bar button, swipe-down dismiss
  - `StreamingReaderViewModel.swift` — `@MainActor ObservableObject` owning the
    URL, navigation delegate state, and progress persistence call
  - `StreamingReaderProgressStore.swift` — `UserDefaults`-backed (key prefix
    `palace.streamingReader.progress.<bookID>`) per-book scroll-offset / fragment
    persistence; protocol-fronted so tests inject a fake
  - SwiftUI wrapper `StreamingReaderView` (`UIViewControllerRepresentable`) for
    presentation parity with the rest of Book Detail
- adds presenter call site from Book Detail (sheet presentation, matching the
  Reader2 / Reader3 pattern of route-driven presentation)

### MyBooks / state layer
- streaming-media titles register in `TPPBookRegistry` as borrowed; no download
  is required (streaming = no on-device asset). Adds `TPPBookRegistry` /
  `MyBooks` recognition so the "Read" button stays available after borrow and
  the title appears in the My Books shelf

### Tests
- adds OPDS2 parse test: a publication with only a streaming-media indirect
  acquisition is no longer dropped by `OPDS2PublicationExtended.toBook()`
- adds OPDS1 parse test: same coverage on the OPDS1 entry path if reachable
- adds `TPPContentType.from(mimeType:)` test for the new constant
- adds `TPPBook.isStreamingHTML` test for positive + negative cases
- adds `BookButtonMapper` test: streaming-HTML title yields a `[.readStreaming]`
  button set when borrowed; `[.get]` when not yet borrowed
- adds `StreamingReaderViewModel` tests: progress save on dismiss, progress
  restore on open, malformed-saved-state safe handling
- adds `StreamingReaderProgressStore` round-trip test (write → read)
- adds a contract-snapshot test for the borrow→present flow if 2+ dependencies
  fire in a known order (per CLAUDE.md contract-snapshot guidance)

### simdrive journey
- adds `.simdrive/journeys/PP-4161-streaming-html-reader.yaml` recording: launch
  Palace → sign in to Palace Bookshelf (staging) → search the repro title
  (urn:uuid:84dac408-77ce-4afc-8393-9e0ced7ea3ef) → Book Detail → tap Read →
  reader renders → scroll → Close → reopen → verify reader returns to saved
  position
- adds per-version SSIM baseline at `.simdrive/fixtures/baselines/<version>/PP-4161-streaming/`

## Anti-claims

- does NOT touch Reader2 (Readium 3.x EPUB) or Reader3 (PDF) — the streaming
  reader is a sibling, not a Reader2 mode
- does NOT modify the audiobook playback stack, the in-app-nav mini-player work
  from PR #1029, or any auth / sign-in / DRM code
- does NOT add a `BookButtonType.readInBrowser` SFSafariViewController action —
  the SafariVC approach was the explicitly-rejected "Approach 1" from the ticket
- does NOT introduce a fourth long-lived reader engine — the streaming reader is
  a thin WKWebView shell, no JS bridge, no annotation layer, no print/share, no
  EPUB navigation features
- does NOT change the borrow flow — streaming titles borrow via the existing
  CM-mediated loan path; the only new behavior is what happens AFTER fulfillment
- does NOT add new DRM handling — streaming-media is open access by definition
- does NOT add a TOC, font-size, or theme controls in v1 — Close + scroll only
- does NOT support offline reading — `text/html;profile=streaming-media` is
  inherently online; the reader shows a "Connection required" error state when
  offline and does not download the asset
- does NOT silently feature-flag — the format renders for all users who have
  upgraded to the version that ships this work; no Firebase Remote Config gate
  (the ticket asks for parity with web/Android, not an experiment)
- does NOT modify HoldsReducer, BorrowReducer auth-error paths, or
  TPPNetworkResponder
- does NOT introduce a new SPM package — the new reader lives in the app target
  under `Palace/ReaderStreaming/`; if a later extraction is warranted it can
  follow the Phase 6 recipe

## Files in scope

### Production
- `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSAcquisitionPath.swift`
- `Palace/OPDS2/Models/OPDS2PublicationExtended.swift`
- `Palace/OPDS/` (OPDS1 entry parsing if a streaming-media leaf needs explicit recognition)
- `Palace/Book/Models/TPPContentType.swift`
- `Palace/Book/Models/TPPBook.swift`
- `Palace/Book/UI/BookDetail/BookDetailView.swift`
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift`
- `Palace/Book/UI/BookDetail/BookButtonMapper.swift`
- `Palace/Book/UI/BookDetail/BorrowReducer.swift`
- `Palace/Book/UI/BookDetail/HalfSheetview.swift`
- `Palace/MyBooks/` (registry recognition for streaming-borrowed state — exact file TBD by architect)
- `Palace/ReaderStreaming/StreamingReaderViewController.swift` (new)
- `Palace/ReaderStreaming/StreamingReaderViewModel.swift` (new)
- `Palace/ReaderStreaming/StreamingReaderProgressStore.swift` (new)
- `Palace/ReaderStreaming/StreamingReaderView.swift` (new — SwiftUI wrapper)
- `Palace/Utilities/Localization/Strings.swift` (Read button + error strings)
- `Palace/Utilities/Testing/AccessibilityIdentifiers.swift` (reader chrome a11y IDs)

### Tests
- `PalaceTests/OPDS2/OPDS2PublicationExtendedTests.swift`
- `PalaceTests/OPDS/OPDSParsingTests.swift` (if OPDS1 path touched)
- `PalaceTests/Book/TPPBookTests.swift`
- `PalaceTests/Book/TPPContentTypeTests.swift` (if exists; new file otherwise)
- `PalaceTests/Book/BookButtonMapperTests.swift`
- `PalaceTests/ReaderStreaming/StreamingReaderViewModelTests.swift` (new)
- `PalaceTests/ReaderStreaming/StreamingReaderProgressStoreTests.swift` (new)
- `PalaceTests/Contract/StreamingReaderPresentationContractTests.swift` (new, optional per architect)

### Project + simdrive
- `Palace.xcodeproj/project.pbxproj` (new ReaderStreaming files added to both
  Palace + Palace-noDRM targets via `scripts/pbxproj_add_swift.rb`)
- `.simdrive/journeys/PP-4161-streaming-html-reader.yaml` (new)
- `.simdrive/fixtures/baselines/<version>/PP-4161-streaming/` (new)
