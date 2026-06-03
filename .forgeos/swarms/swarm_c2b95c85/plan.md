# Swarm swarm_c2b95c85 — PP-4161 streaming HTML reader

## Goal

Add full in-app WKWebView streaming reader for LibrarySimplified `streaming-media`
(text/html) OPDS publications. Reverses the PR #847 filter so these titles
surface in the catalog; plumbs the MIME through the acquisition / content-type
layers; adds a new `Palace/ReaderStreaming/` module (UIKit shell + WKWebView +
UserDefaults-backed per-book scroll position); and wires Book Detail's "Read"
action so a borrowed streaming-HTML title opens the new reader. Verify
end-to-end against repro book `urn:uuid:84dac408-77ce-4afc-8393-9e0ced7ea3ef`
on lyrasis-reads staging via a new simdrive journey. Ship pass on
`scripts/verify-pr.sh --quick` + `/forge-review`.

## Modules + parallelism

| Letter | Module | Risk | Wave | Depends on |
|---|---|---|---|---|
| A | Format-Recognition (OPDS + ContentType + Filter) | standard | 1 | — |
| B | StreamingReader (new in-app reader engine) | standard | 1 | — |
| C | BookButton + Presenter Wiring (Book + MyBooks) | critical_path | 2 | A, B |
| D | Simdrive Journey + Baselines | standard | 3 | C |

- **Wave 1 (parallel):** A and B are fully disjoint. A touches OPDS / Catalog
  SPM / content-type / filter; B touches only the new `Palace/ReaderStreaming/`
  directory plus shared Strings + AccessibilityIdentifiers files. B can
  consume the new `ContentTypeStreamingHTML` constant from the `PalaceCatalog`
  SPM once A lands; no compile-time coupling.
- **Wave 2 (after A and B):** C threads the new `BookButtonType.readStreaming`
  case through 8 exhaustive switches and extends the 6 `TPPBookContentType`
  switches to handle `.streamingHTML`. Also wires `BookDetailViewModel.didSelectReadStreaming`
  → `NavigationCoordinator` → `StreamingReaderView` presentation.
- **Wave 3 (after C):** D records the simdrive journey against the merged
  branch. Journey + baselines only — no production code.

## Risks (deviations from intent file)

1. **BookButtonType location.** Intent listed `Palace/Book/UI/BookDetail/BookButtonMapper.swift`
   as the home of `BookButtonType`. Actual location is
   `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift`. Adding
   the new case is a MyBooks edit, not a Book edit. Module C owns it.

2. **Exhaustive-switch count is 8, not 5.** Intent listed 5 switch sites; reality
   includes 4 internal switches in `BookButtonType.swift` itself (`displaysIndicator`,
   `isDisabled`, `title`, `title(for:)`), plus `HalfSheetview.swift` has TWO
   (full-size + compact), plus 3 in `BookCellModel.swift`, plus
   `BookButtonsView.swift` (accessibility ID). Module C's contract enumerates all 8.

3. **BorrowReducer does NOT have an exhaustive switch over BookButtonType cases.**
   Intent claimed BorrowReducer would fail to compile when a case is added.
   Reality: BorrowReducer switches over `BorrowAction` and only stores
   `Set<BookButtonType>`. Adding `.readStreaming` will NOT force a compile
   error there. The `downloadRelatedButtons` static set should be reviewed
   for whether `.readStreaming` belongs (it doesn't — streaming-HTML titles
   don't download). No BorrowReducer change is expected; if the implementer
   touches it, the contract calls that out as out-of-scope.

4. **TPPBookContentType, not TPPContentType.** The actual enum name is
   `TPPBookContentType`. Use the existing name.

5. **TPPBookContentTypeConverter has a `default:` clause.** Adding `.streamingHTML`
   won't force a compile error there. The converter must add an explicit case
   AND drop the `default:` for F-011 exhaustiveness (so the next case-addition
   does flag).

6. **Two OPDS2 filter sites.** Intent only mentioned `OPDS2PublicationExtended.swift:264-282`.
   The parallel filter at `:384-398` (in `OPDS2FullPublication.toBook()`) must
   also pass streaming-media through. Module A owns both.

7. **Palace/OPDS/ is effectively empty.** Only `TPPOPDSFeed+Networking.swift`
   remains. OPDS1 entry parsing is now in `Palace/Packages/PalaceCatalog/`.
   Intent's OPDS1 mention applies to the SPM, not the Palace/OPDS/ dir.

8. **MyBooks registry semantics for streaming-borrowed state.** Intent said
   "TPPBookRegistry recognizes streaming as borrowed; no download required."
   Minimal-surface approach: after a successful borrow for a streaming-HTML
   title, set the registry directly to `.downloadSuccessful` (matching what
   an already-downloaded asset would yield). `BookButtonState.buttonTypes`'s
   `.downloadSuccessful` branch then adds `.readStreaming` for streaming-HTML
   titles via its existing `defaultBookContentType` switch. No new `TPPBookState`
   case. This is the change that makes Module C `critical_path`.

9. **Module B can be authored speculatively in parallel to A.** The
   `StreamingReaderViewModel` API surface (init takes a `URL` + a
   `StreamingReaderProgressStoring` protocol + a `bookID: String`) doesn't
   depend on A; only the *consumer* in Module C does. So B and A truly run in
   parallel.

## Acceptance criteria

1. `scripts/verify-pr.sh --quick` PASS on the merged branch.
2. The repro book (`urn:uuid:84dac408-77ce-4afc-8393-9e0ced7ea3ef`) is visible
   in the lyrasis-reads (staging) catalog after launch — the OPDS2 filter no
   longer drops it.
3. The simdrive journey `PP-4161-streaming-html-reader.yaml` replays
   end-to-end: catalog → sign-in → search → book detail → tap Read → reader
   renders → scroll → Close → reopen → reader returns to saved position.
4. `/forge-review` returns APPROVED on both architect and qa_test gates
   (critical-path because Module C touches MyBooks registry semantics).
5. Mutation kill-rate ≥80% diff-scoped on Module C production files.
6. No anti-scope edits (per `dont_touch` list).
7. Single bundled PR off `feat/PP-4161-streaming-html-reader`.

## Out of scope (anti-claims from intent)

- No Reader2 / Reader3 changes.
- No `BookButtonType.readInBrowser` SFSafariViewController action.
- No new long-lived reader engine — WKWebView shell only, no JS bridge / TOC /
  font / theme / annotation / print / share.
- No borrow flow changes — streaming titles use the existing CM-mediated loan.
- No DRM handling.
- No offline support — show `Strings.StreamingReader.connectionRequired` when
  offline.
- No feature flag — ships unconditionally for all upgraded users.
- No HoldsReducer / BorrowReducer auth-error / TPPNetworkResponder edits.
- No new SPM package — `Palace/ReaderStreaming/` lives in the app target.
