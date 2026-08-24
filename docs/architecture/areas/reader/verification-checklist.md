---
name: reader-verification-checklist
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 180d
owners: [reader]
description: Per-area verification reference; refresh before next swarm/rigorous-fix
---

<!-- audit-verified: file paths in Section 1 (Palace/Reader2/UI/TPPEPUBViewController.swift, Palace/Reader2/UI/ReaderEditingActions.swift, Palace/PDF/Views/PalacePDFView.swift, Palace/PDF/Views/TPPPDFView.swift, Palace/PDF/LCP/LCPPDFs.swift, Palace/PDF/ReadiumPDF/ReadiumPDFViewController.swift, Palace/AppInfrastructure/ReaderService.swift, Palace/AppInfrastructure/NavigationHostView.swift, Palace/Reader2/BusinessLogic/*) were all confirmed to exist via ls/grep on 2026-05-28. PR #1012 (PP-4297) and PR #1008 (PP-4454) verified in `git log --oneline origin/develop -- Palace/Reader2/ Palace/Reader3/`. `TPPBook.isDRMProtected` definition confirmed at Palace/Packages/PalaceBookModel/Sources/PalaceBookModel/TPPBook.swift:652. simdrive journeys enumerated from `.simdrive/journeys/reader2-*.yaml`. Regression matrix rows E1, E1-LCP, E1-Adobe, E2, E2-Hang verified in docs/Testing/REGRESSION_TEST_MATRIX.md. Reader3/ confirmed empty except for .DS_Store + an empty ReaderStackConfiguration/ subdirectory — there is no live "Reader3" code; PDF lives under Palace/PDF/. -->

# Reader area — verification checklist

**Owner area:** `Palace/Reader2/` (EPUB via Readium 3.x WKWebView, SwiftUI nav), `Palace/PDF/` (PDFKit + Readium-PDF), and the reader open-path / DRM-gating seams in `Palace/AppInfrastructure/ReaderService.swift`, `Palace/AppInfrastructure/NavigationHostView.swift`.

**Note on `Palace/Reader3/`:** the directory exists but is empty (only `.DS_Store` + an empty `ReaderStackConfiguration/` subdirectory). PDF rendering lives under `Palace/PDF/`, not `Reader3/`. Treat `Reader3/` as a reserved namespace pending a future move; do not add code there without an explicit ADR.

**Purpose:** the architect's first deliverable on ANY swarm or /rigorous-fix in this area is *update this file*. Verify what's still true, add what's changed, mark what's UNKNOWN. Without it, every new initiative re-discovers the same surface (reader copy/paste gating PP-4297 and the Marketplace LCP-PDF open-hang PP-4454 both produced recon docs that should have started from a baseline like this).

**Last refresh:** 2026-05-28 (post PR #1012 PP-4297 + PR #1008 PP-4454 — see commits `d7f115ade` and `16fc46900` on `origin/develop`).
**Refreshing architect:** sign and date the next-refresh row at the bottom of this file.

---

## 1. Call-site map (sites that mount a reader surface, gate copy/paste, or walk the acquisition chain for format/DRM)

| File | Lines | What it does | Status |
|------|-------|-------------|--------|
| `Palace/AppInfrastructure/ReaderService.swift` | 74 (`openEPUB`), 113 (`openPDF`), 185 (`libraryService.openBook` callback), 269, 407 (`openEPUBInternal`), 428 (`openSample`), 560 | Reader open-path router. Routes by format → EPUB vs PDF path. Owns generation-counter staleness guard for in-flight openBook completions. | **LIVE.** Only entry point for new reader mounts — do not bypass. |
| `Palace/AppInfrastructure/NavigationHostView.swift` | 85 | SwiftUI host that instantiates `TPPPDFReaderView(document:)` for the PDFKit PDF path. | **LIVE.** |
| `Palace/Reader2/UI/TPPEPUBViewController.swift` | 53–55 | Builds the EPUB `EditingAction` list; routes through `ReaderEditingActions.resolve(for:isSample:appending:)`. | **MIGRATED** in PR #1012 (PP-4297). DRM → `[]`. Non-DRM → `EditingAction.defaultActions + custom (Highlight)`. |
| `Palace/Reader2/UI/ReaderEditingActions.swift` | 15 (enum), 32 (`resolve`), 34 (`isDRMProtected && !isSample`) | Single source of truth for EPUB editing-action gating. Samples treated as non-DRM regardless of book DRM (sample = open-access preview). | **LIVE.** |
| `Palace/PDF/Views/PalacePDFView.swift` | 20 (`allowsCopy`), 22 (`canPerformAction`), 29 (`buildMenu`), 55–56+ (blocked-selector list incl. `_share:`, `_lookup:`, `_define:`, `_translate:`) | PDFKit subclass for forward-looking PDFKit-rendered DRM-PDF path. `buildMenu` order is **super-then-strip** so PDFKit late-inserts can't leak through. | **LIVE.** Gating in place; currently not the active PDF-render path for DRM (see Section 7). |
| `Palace/PDF/Views/TPPPDFView.swift` | 83 (`pdfView.allowsCopy = !metadata.book.isDRMProtected`) | Today's PDFKit-rendered PDF path; wires `allowsCopy` from the DRM predicate. | **LIVE.** |
| `Palace/PDF/ReadiumPDF/ReadiumPDFViewController.swift` | 21 (class), 59 (`installNavigator`), 106 (`restoreInitialPageIfNeeded`), 140–148 (Navigator delegate: `locationDidChange`, `presentError`, `didFailToLoadResourceAt`) | Readium-PDF navigator wrapper. PP-4454 wired DRM gating into this path post-merge (see commit `29156e0f7` on current branch). | **LIVE on `fix/PP-4297-reader-copy-paste-gating` branch.** Verify on develop after this PR lands. |
| `Palace/PDF/LCP/LCPPDFs.swift` | 35 (`canOpenBook`), 63 (`hasLCPAcquisition`) | Recursive predicate walking the WHOLE acquisition chain (top-level + nested `indirectAcquisitions[*]`). Mirror of `LCPAudiobooks.hasLCPAcquisition` from PP-4407. | **MIGRATED** in PR #1008 (PP-4454). |
| `Palace/Packages/PalaceBookModel/Sources/PalaceBookModel/TPPBook.swift` | 652 (`@objc var isDRMProtected: Bool`) | Single source of truth for "is this book DRM-protected?" — walks the nested acquisition chain via `TPPOPDSAcquisitionPath.supportedAcquisitionPaths(...)` for Adobe Adept, Readium LCP, Audiobook LCP. | **LIVE.** Adding a new DRM scheme = one line here. |
| `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` | (full file) | Posts reading-position updates to the annotation sync server. | **LIVE.** Cross-device sync surface. |
| `Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift` | (full file) | Pulls latest server position on reader mount. | **LIVE.** |
| `Palace/Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift` | (full file) | Per-book bookmark CRUD + sync. | **LIVE.** |
| `Palace/Reader2/BusinessLogic/EPUBPositionAdapter.swift` | (full file) | Maps Readium `Locator` ↔ Palace `TPPBookLocation`. | **LIVE.** |
| `Palace/Reader2/UI/TPPBaseReaderViewController.swift` | (full file) | Common reader UIVC base (nav bar, settings, TOC, bookmarks chrome). | **LIVE.** Unreachable from XCTest (see Section 7). |
| `Palace/Reader2/UI/KeyboardNavigationHandler.swift` | (full file) | Hardware keyboard / FKA support; iPad-on-Mac escape (PP-4289). | **LIVE.** |
| `Palace/Reader2/Bookmarks/TPPAnnotations.swift` | (full file) | Server-side annotation CRUD. | **LIVE.** |

**STILL UNVERIFIED on develop** (next-sprint candidates):
- `ReadiumPDFViewController` DRM gating wired on `fix/PP-4297-reader-copy-paste-gating` only — must be re-confirmed on develop after PR merge.
- Reader-open-hang HelpSpot 17966 root cause (non-Marketplace EPUB / non-LCP-PDF) — open investigation; PP-4454 only fixed Marketplace LCP-wrapped PDFs.

---

## 2. Module ownership

| Module | Owner | Public surface (what changes here is a contract break) |
|--------|-------|---------------------------------------------------------|
| `Palace/Reader2/` | Main target — EPUB reading surface | `TPPEPUBViewController`, `TPPBaseReaderViewController`, `EPUBReaderView` (SwiftUI host), `ReaderEditingActions.resolve(...)`, `TPPLastReadPositionPoster`, `TPPLastReadPositionSynchronizer`, `TPPReaderBookmarksBusinessLogic`, `EPUBPositionAdapter`, `TPPAnnotations` |
| `Palace/PDF/` | Main target — PDF rendering surface | `TPPPDFReaderView`, `TPPPDFView`, `PalacePDFView` (PDFKit subclass), `ReadiumPDFReaderView` / `ReadiumPDFViewController` (Readium-PDF), `LCPPDFs.canOpenBook` + `hasLCPAcquisition`, `TPPPDFDocument`, `TPPPDFDocumentMetadata`, `TPPPDFLocation` |
| `Palace/AppInfrastructure/ReaderService.swift` | Main target — open-path router | `openEPUB(_:)`, `openPDF(_:onFinish:)`, `openSample(_:url:)`. Generation-counter staleness pattern is load-bearing — do not remove. |
| `Palace/Reader2/ReaderStackConfiguration/` | Main target — Readium R3 dependency wiring | `TPPR3Owner`, `LibraryService`, `DRMLibraryService` (Adobe + LCP subdirs), `LibraryServiceError` |
| `PalaceReadingPosition` (SPM) | SPM trunk | Unified read-position write contract (extracted in PR #980); consumed by audiobook + EPUB + PDF. Changes here ripple across all three readers. |
| Readium 3.x (`swift-toolkit`) | External SPM | `EditingAction`, `Navigator`, `Locator`, `PDFNavigatorViewController`, `EPUBNavigatorViewController`. Upgrades may shift `defaultActions` set — see Section 7. |

---

## 3. Format × DRM matrix (verify before changing the open-path or gating logic)

Rows = format/DRM combo; columns = capability. `Y` = supported, `N` = blocked by design, `—` = N/A, `?` = UNKNOWN/unverified.

| Combo | Open | Read | Search | Bookmark | Copy/paste | Position sync | Offline read |
|---|---|---|---|---|---|---|---|
| EPUB / DRM-free (Palace Bookshelf) | Y | Y | Y | Y | Y (default actions + Highlight) | Y | Y |
| EPUB / LCP (Marketplace) | Y | Y | Y | Y | **N** (gated by `isDRMProtected`) | Y | Y |
| EPUB / Adobe RMSDK | Y | Y | Y | Y | **N** (gated by `isDRMProtected`) | Y | Y |
| EPUB / sample (any source) | Y | Y | Y | Y | Y (samples treated as non-DRM) | — | Y |
| PDF / DRM-free | Y | Y | Y | Y | Y (`allowsCopy = true`) | Y | Y |
| PDF / LCP (Marketplace) | Y (post PR #1008 PP-4454) | Y | Y | Y | **N** (TPPEncryptedPDFView bitmap-tile path — non-selectable by construction; PalacePDFView gating is forward-looking) | Y | Y |
| PDF / Adobe | ? UNVERIFIED — Adobe PDF is rare in our catalog | ? | ? | ? | **N** expected | ? | ? |
| Open-access (any format) | Y | Y | Y | Y | Y | Y | Y |
| Audiobook / LCP | — (covered by audiobook area) | — | — | — | — | — | — |

`?` cells need a fixture + a recorded simdrive journey before the next release-cut. File those as gaps in `.simdrive/journeys/`.

---

## 4. Reader-open dispatch (the actual decision tree at `ReaderService`)

```
ReaderService.openBook(book)
  ├── isEPUB → openEPUB(book)
  │             └── openEPUBInternal(book, isRetry:)
  │                   └── r3Owner.libraryService.openBook(book) callback
  │                         └── present TPPEPUBViewController (Readium WKWebView)
  │                               └── ReaderEditingActions.resolve(for: book, isSample: ...)
  │                                     └── DRM ? [] : defaultActions + [Highlight]
  └── isPDF
        ├── canRenderViaReadium(book) → ReadiumPDFContainer (Readium-PDF + PDFNavigatorViewController)
        └── else → TPPPDFReaderView(document:) (PDFKit, via NavigationHostView:85)
                    └── TPPPDFView.allowsCopy = !book.isDRMProtected
```

Sample path is separate: `openSample(_:url:)`. Samples bypass DRM gating (isSample=true → editing actions enabled).

---

## 5. Telemetry surface points

| Surface point | File | Event | Payload extras |
|---------------|------|-------|----------------|
| EPUB open start | `ReaderService.openEPUB` | (instrumented via `Log.info` `[PERF]`) | `book.identifier` |
| LCP-PDF open T2 publication-opened | `ReaderService.openPDF` callback (line ~196) | `[PERF] [LCP-PDF] T2 publication opened` | `+ libraryOpenElapsedMs, totalMs` |
| Stale openBook completion ignored | `ReaderService.openPDF` callback (line ~193) | `[PERF] [LCP-PDF] stale openBook completion ignored` | `+ generation, currentGeneration` |
| Position post | `TPPLastReadPositionPoster` | server PUT to annotation endpoint | book.identifier + locator |
| Position pull | `TPPLastReadPositionSynchronizer` | server GET | book.identifier |
| Bookmark CRUD | `TPPAnnotations` + `TPPReaderBookmarksBusinessLogic` | server PUT/DELETE | book + bookmark id |
| Reader-mount failure | `ReadiumPDFViewController.presentFailure` (line 126) | UI alert + log | error |
| Navigator error | `ReadiumPDFViewController.navigator(_:presentError:)` | log | NavigatorError |
| Resource load failure | `ReadiumPDFViewController.navigator(_:didFailToLoadResourceAt:withError:)` | log | href + ReadError |

The reader area does **not** currently emit a unified `readerOpenOutcome` telemetry event — every regression that hits "blank screen / infinite spinner" (HelpSpot 17966 = E2-Hang) has to be diagnosed from the `[PERF]` log line trail. Adding a unified open-outcome event is a backlog candidate.

---

## 6. Test surface

**XCTest reachability is fundamentally limited here.** The Readium 3.x EPUB navigator renders inside a `WKWebView`; the accessibility tree exposed to XCTest does not include the rendered EPUB content, the nav bar, the settings sheet, or the TOC. XCTest can mount the host controller and assert on UIKit chrome that lives *outside* the WKWebView, but it cannot exercise the actual reading surface.

**simdrive is the canonical driver** for the EPUB reading surface. It uses real CoreSimulator HID + vision-first OCR — it sees pixels, not the accessibility tree.

**Existing simdrive journeys** (`.simdrive/journeys/`):
- `reader2-bookmark-toggle.yaml` — add/remove a bookmark via the nav bar bookmark button
- `reader2-settings-sheet.yaml` — open the typography/brightness settings sheet
- `reader2-page-forward.yaml` — turn pages forward
- `reader2-back-button.yaml` — exit the reader via the nav bar back button
- `reader2-toc-navigate.yaml` — open TOC, tap chapter, land on chapter

**No PDF journeys exist yet** — `reader3-*.yaml` / `pdf-*.yaml` are gaps to fill before the next release-cut. Both the PDFKit path (`TPPPDFView`) and the Readium-PDF path (`ReadiumPDFContainer`) need at least one open-and-navigate journey.

**Existing XCTest test files** (cover business logic + UIKit chrome, NOT WKWebView content):
- `PalaceTests/Reader/ReaderEditingActionsTests.swift` — PP-4297 gating predicate
- `PalaceTests/Reader/EPUBKeyCommandsPP4289Tests.swift` — hardware keyboard / iPad-on-Mac escape
- `PalaceTests/Reader/EPUBToolbarToggleTests.swift` — F-036 nav bar toggle
- `PalaceTests/Reader/EPUBPositionTests.swift`
- `PalaceTests/Reader/ReaderNavBarVoiceOverTests.swift` — VoiceOver passthrough
- `PalaceTests/Reader/KeyboardNavigationHandlerTests.swift`
- `PalaceTests/Reader/KeyboardVoiceOverTests.swift`
- `PalaceTests/Reader/KeyboardNavigationFKATests.swift`
- `PalaceTests/Reader2/EPUBSearchViewModelTests.swift`
- `PalaceTests/Reader2/TPPBaseReaderViewControllerInitialLocationTests.swift`
- `PalaceTests/Reader2/TPPReaderTOCBusinessLogicTests.swift`
- `PalaceTests/Reader2/BookmarkBusinessLogicTests.swift`
- `PalaceTests/Reader2/TPPReadiumBookmarkTests.swift`
- `PalaceTests/Reader2/TPPBookmarkR3LocationTests.swift`
- `PalaceTests/TPPReaderBookmarksBusinessLogicTests.swift`
- `PalaceTests/PDF/PalacePDFViewTests.swift` — PP-4297 PDFKit gating + buildMenu super-then-strip
- `PalaceTests/PDF/LCPPDFOpenProgressTests.swift`
- `PalaceTests/PDF/LCPPDFDiskExtractTests.swift`
- `PalaceTests/PDF/TPPPDFDocumentMetadataTests.swift`
- `PalaceTests/PDF/TPPPDFModelTests.swift`
- `PalaceTests/PDF/TPPPDFLocationTests.swift`
- `PalaceTests/PDF/PDFReaderTests.swift`
- `PalaceTests/PDF/PDFExtensionsTests.swift`
- `PalaceTests/LCP/LCPPDFAcquisitionPredicateTests.swift` — PP-4454 recursive predicate
- `PalaceTests/Bookmarks/TPPBookmarkSpecTests.swift`
- `PalaceTests/Bookmarks/TPPBookmarkDeletionLogTests.swift`
- `PalaceTests/Bookmarks/TPPAnnotationsTests.swift`
- `PalaceTests/Book/BookmarkManagerTests.swift`
- `PalaceTests/Crawl/CrossDeviceBookmarkSyncTests.swift`
- `PalaceTests/Accessibility/ReaderAccessibilityTests.swift`
- `PalaceTests/Accessibility/PDFAccessibilityToolbarTests.swift`
- `PalaceTests/EPUBModuleTests.swift`
- `PalaceTests/Contract/Reader2PositionResumeContractTests.swift`
- `PalaceTests/Contract/Reader2BookmarkContractTests.swift`
- `PalaceTests/Contract/Reader2PositionAdapterContractTests.swift`

**Tests that test BEHAVIOR (must-survive any refactor):**
- `ReaderEditingActionsTests` — DRM gating contract (any regression here = copy/paste leak)
- `PalacePDFViewTests` — buildMenu super-then-strip order (PDFKit late-inserts must not leak)
- `LCPPDFAcquisitionPredicateTests` — PP-4454 recursive walker
- `CrossDeviceBookmarkSyncTests`, `TPPBookmarkSpecTests` — sync contract
- `Reader2PositionResumeContractTests`, `Reader2PositionAdapterContractTests` — locator round-trip

**Tests that test IMPLEMENTATION (can be rewritten when underlying changes):**
- Tests asserting on specific `TPPBaseReaderViewController` chrome layout
- Tests asserting on `TPPReadiumBookmark` ObjC-bridged fields (legacy bookmark format)

---

## 7. Known traps / anti-patterns (lessons from prior work)

- **Reader2 nav (back, settings, TOC) is invisible to XCTest.** The Readium 3.x EPUB navigator renders in a `WKWebView` whose tree XCTest cannot see. Any regression in the reading surface MUST be exercised via simdrive (`.simdrive/journeys/reader2-*.yaml`). If you write an XCTest expecting to tap a reader nav-bar button via accessibility id, it will not work. (Memory: `feedback_simdrive_validated.md`.)
- **`TPPBook.isDRMProtected` is the single gate for copy/paste — keep the predicate recursive.** EPUB gating happens in `ReaderEditingActions.resolve` (DRM → `[]`); PDF gating happens in `PalacePDFView` (`allowsCopy = !isDRMProtected`) and `TPPPDFView` (line 83). `isDRMProtected` walks the full nested acquisition chain via `TPPOPDSAcquisitionPath.supportedAcquisitionPaths(...)`. A flat `defaultAcquisition.type` check WILL miss DRM nested two levels deep — same root cause as PP-4407 (Marketplace audiobook MIME nesting) and PP-4454 (Marketplace LCP-PDF). Recipe memory: `reference_reader_copy_paste_gating.md`. Lesson memory: `reference_marketplace_lcp_mime_nesting.md`.
- **VoiceOver passthrough is required for copy/paste gating.** Accessibility selectors (`accessibilityActivate`, `_accessibility*`) must NOT be in the blocked-selector list. The pattern is **super-then-strip** (`buildMenu` calls `super` first, then removes the blocked entries) — this preserves VoiceOver's path. Tested via parity-against-baseline assertion (`viaSubclass == viaBaseline` with `allowsCopy` flipped). Do NOT switch to a strip-then-super pattern.
- **PDFKit late-inserts.** PDFKit (and iOS itself) may add menu entries during `buildMenu` AFTER your override runs in older patterns. The super-then-strip order in `PalacePDFView.buildMenu` defends against this. Future PDFKit upgrades that change the timing of inserts could re-introduce leaks — re-run `PalacePDFViewTests` against every Xcode upgrade.
- **Apple-private selectors in the blocked list need individual test pins.** `_share:`, `_lookup:`, `_define:`, `_translate:` are private; each must have its own test or a mutation/Apple-rename will silently degrade the suppression (Share/Lookup might resurface). Failure mode is leak, not crash.
- **Marketplace LCP MIME-nesting in PDF acquisition chain (PP-4454).** `LCPPDFs.canOpenBook` previously inspected only the top-level acquisition type, missing the LCP MIME nested two levels deep. Fix: `LCPPDFs.hasLCPAcquisition` recursive walker. Any new "is this acquisition / book / format X?" predicate in the reader area MUST be recursive from the start.
- **Generic reader open-hang (HelpSpot 17966, regression matrix E2-Hang).** Symptom: blank screen + infinite spinner on book open, survives reinstall + relogin. **PP-4454 only fixed Marketplace LCP-wrapped PDFs.** Non-Marketplace EPUB and non-LCP-PDF open paths are still unexplained. Regression rows E2-Hang and E1/E1-Adobe must be exercised on every release-cut.
- **Generation-counter staleness guard in `ReaderService.openPDF`.** The async `r3Owner.libraryService.openBook` callback captures a generation counter; if the user bumps the generation (e.g. cancels and re-opens, or switches books) before the callback fires, the stale completion is dropped. Do NOT remove this guard — without it, a stale completion can mount the wrong reader or cross-pollinate state. (See `ReaderService.swift` lines 22, 57, 193.)
- **F-036 nav bar toggle, F-037 brightness slider, F-039 search order** are historical Reader2 regression fixes. Each has a corresponding test (`EPUBToolbarToggleTests`, etc.); rerun them on every Reader2 refactor.
- **F-038 stale-loan DRM error on LCP.** Re-opening a returned/expired LCP book can surface a misleading DRM error instead of a clean "loan expired" message. Pin via E1-LCP regression row.
- **F-011 audiobook first-open hang (PR #990 toolkit overhaul regression)** is in the audiobook area, not reader — but its surface (UI mounted but engine doesn't start; nav-away-and-back fixes it) is a useful prior-art pattern when triaging a similar reader-side hang. Memory: `audiobook_first_open_hang_3_2_0.md`.
- **`Palace/Reader3/` is empty** — do not assume PDF lives there. PDF lives under `Palace/PDF/`. The `Reader3/` namespace is reserved for a future move; touching it without an ADR will leave stale empty scaffolding.

---

## 8. Architect's pre-swarm checklist (what to verify before writing a new contract)

Before any new swarm or /rigorous-fix in this area, the architect should:

1. **Refresh this file's sections 1–3** — confirm the call-site map, module ownership, and format × DRM matrix are still accurate. Add new sites or mark removed ones.
2. **For Reader2 (EPUB) changes:** confirm there's a `.simdrive/journeys/reader2-*.yaml` covering the changed surface, OR plan to record one in the same PR. XCTest cannot exercise the WKWebView; if you ship without a simdrive journey, the change is untested at the surface that matters.
3. **For PDF changes:** verify `PalacePDFView.buildMenu` super-then-strip order is preserved and the blocked-selector list still contains `_share:`, `_lookup:`, `_define:`, `_translate:`. Re-run `PalacePDFViewTests` + `ReaderEditingActionsTests` + `LCPPDFAcquisitionPredicateTests` before and after.
4. **For copy/paste / selection changes:** VoiceOver passthrough parity test (`viaSubclass == viaBaseline` with `allowsCopy` flipped) is mandatory. Manually verify with VoiceOver on device for at least one DRM and one non-DRM book.
5. **For any "is this acquisition / book / format X?" predicate added or modified:** make it recursive over `indirectAcquisitions[*]` from the start. Re-grep `grep -rn "defaultAcquisition.type" Palace/` after the change — any new flat-walk hits need triage.
6. **For reader-open path changes (`ReaderService`):** preserve the generation-counter staleness guard. Test cancel-then-reopen across format boundaries (EPUB→PDF, PDF→EPUB).
7. **Re-run reader test inventory** — `find PalaceTests -path '*Reader*' -o -path '*PDF*' -o -path '*Bookmark*' | wc -l` — confirm count and update Section 6.
8. **Re-run critical-path tests on develop** BEFORE the swarm starts so post-swarm regressions are attributable.
9. **Update Section 9 (refresh history)** with date + your initials.

---

## 9. Refresh history

| Date | Refreshed by | Notes |
|------|-------------|-------|
| 2026-05-28 | swarm rigor meta-improvement (this PR) | Initial baseline. Derived from PR #1012 (PP-4297 copy/paste gating), PR #1008 (PP-4454 Marketplace LCP-PDF), and the in-flight `fix/PP-4297-reader-copy-paste-gating` branch wiring `ReadiumPDFViewController`. Reader3/ confirmed empty — PDF lives under `Palace/PDF/`. |

---

**This file is owned by the reader area.** If you change anything in the modules listed in Section 2, update the relevant section here before you commit. The Definition of Done (CLAUDE.md) treats out-of-date area checklists as scope debt.
