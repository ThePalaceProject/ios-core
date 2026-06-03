# Module C — BookButton + Presenter Wiring (critical path)

**Critical-path module.** Touches `Palace/MyBooks/` (registry semantics for
streaming-borrowed state through BookButtonState content-type switch +
BookCellModel.didSelectRead routing) AND adds the new `BookButtonType.readStreaming`
case that propagates to 8+ exhaustive switches. Per CLAUDE.md "Risk-driven
rigor bar", anything touching MyBooks state propagation triggers architect
post-review. Mutation kill-rate ≥80% diff-scoped on touched MyBooks files.

## Goal

1. Add `BookButtonType.readStreaming` and update ALL 8 exhaustive `switch self`
   sites (including the 4 in `BookButtonType.swift` itself).
2. Extend the 6 `TPPBookContentType` switches across `Palace/Book/`, `Palace/MyBooks/`,
   and `Palace/CatalogUI/` to handle `.streamingHTML` — for the routing
   switches (`didSelectRead`, `dispatchOpen`, `openBook`), the new branch
   presents the new `StreamingReaderView` via the navigation coordinator.
3. Update `BookButtonState.buttonTypes(book:)` so `.downloadSuccessful` /
   `.used` branches emit `.readStreaming` (instead of `.read`/`.listen`)
   when `book.defaultBookContentType == .streamingHTML`.
4. Wire `BookDetailViewModel.handleAction(for: .readStreaming)` →
   `didSelectReadStreaming(for: book)` → navigation coordinator presentation
   of `StreamingReaderView`.
5. After a successful streaming-HTML borrow, set the registry directly to
   `.downloadSuccessful` (so the button mapping flips to `.readStreaming`)
   — NO new `TPPBookState` case; reuse the existing terminal state.

## What public types/protocols change

- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift`:
  - Enum gains `case readStreaming`
  - `displaysIndicator`, `isDisabled`, `title`, `title(for:)`, `buttonStyle`
    each gain a `.readStreaming` arm
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift`:
  - `buttonTypes(book:)` `.downloadSuccessful` / `.used` inner switch gains
    `case .streamingHTML: buttons.append(.readStreaming)`
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift`:
  - NEW `func didSelectReadStreaming(for book: TPPBook)` method
  - `handleAction(for:)` switch gains `.readStreaming` → `didSelectReadStreaming(for:)`
  - `openBook(_:completion:)` switch gains `case .streamingHTML` → present `StreamingReaderView`
- `Palace/AppInfrastructure/NavigationCoordinator.swift`:
  - NEW route: either `case streamingHTML(BookRoute)` in `AppRoute` (if pushed)
    OR a sheet-presented `streamingReaderById` dictionary + `presentStreamingReader(book:)` / `dismissStreamingReader()` API.
    **Implementer decides** based on whether the streaming reader's "swipe-down dismiss"
    fits SwiftUI sheet presentation or NavigationStack push. Default: NavigationStack push (mirrors Reader2/3).
- `Palace/AppInfrastructure/NavigationHostView.swift`:
  - Add the `.streamingHTML` route render branch if the AppRoute case approach is chosen.

## What internal seams (DI) need updating

- `BookDetailViewModel.didSelectReadStreaming` calls
  `navigationCoordinatorHub.coordinator?.presentStreamingReader(book:)` (sheet)
  OR `.push(.streamingHTML(BookRoute(id:)))` (NavigationStack push).
- Tests inject a `MockNavigationCoordinator` (or use the existing test
  navigation coordinator from `PalaceTests/Mocks/`) to assert the
  presentation happened.

## Test contracts the module must satisfy

1. **BookButtonMapper streaming-borrowed yields readStreaming (mandatory).**
   `testBookButtonState_buttonTypes_streamingHTMLBorrowed_yieldsReadStreaming`.
   Build a `TPPBook` whose `defaultBookContentType == .streamingHTML`,
   bookRegistry state `.downloadSuccessful`, assert
   `BookButtonState.downloadSuccessful.buttonTypes(book:)` contains `.readStreaming`
   (NOT `.read` or `.listen`).

2. **BookButtonMapper streaming-not-borrowed yields get (mandatory).**
   `testBookButtonState_buttonTypes_streamingHTMLUnborrowed_yieldsGet`.
   Same book, registry state `.unregistered`, OPDS availability unlimited,
   assert `[.get]`.

3. **BookCellModel.didSelectRead routes streaming-HTML to StreamingReaderView (mandatory).**
   `testBookCellModel_didSelectRead_streamingHTMLBook_presentsStreamingReaderView_viaCoordinator`.
   Construct with a `MockNavigationCoordinator`, call `didSelectRead()` on a
   streaming-HTML book, assert the mock recorded a `push(.streamingHTML(...))`
   OR `presentStreamingReader(book:)` call (whichever route shape was chosen).

4. **BookDetailViewModel.handleAction(.readStreaming) (mandatory).**
   `testBookDetailViewModel_handleAction_readStreaming_callsDidSelectReadStreaming`.
   Inject a `MockNavigationCoordinator`. Call `handleAction(for: .readStreaming)`.
   Assert the mock recorded the presentation. Assert `processingButtons`
   contained `.readStreaming` during the call (regression net for the
   `processingButtons.insert(button)` line).

5. **Exhaustive switch META regression test (per Module B Phase 7 pattern).**
   `testBookButtonType_exhaustiveSwitch_coverage_includesReadStreaming`.
   Iterate over all `BookButtonType` cases (via reflection or hardcoded list)
   and assert each yields a non-empty `localizedTitle`, a non-nil
   accessibility ID at `BookButtonsView.accessibilityID(for:)`, and a
   defined `buttonStyle`. Catches the next case-addition that forgets a switch
   arm.

6. **Streaming-borrowed registry state transition (mandatory — critical path round-trip).**
   `testBookDetailViewModel_didSelectGet_streamingHTMLBook_setsRegistryToDownloadSuccessful_thenButtonsAreReadStreaming`.
   Drive the borrow happy path for a streaming-HTML book through the
   production seam (`handleAction(for: .get)`), assert registry transitions
   to `.downloadSuccessful` (NOT `.downloadNeeded`), assert subsequent
   `buttonTypes` returns `[.readStreaming, .return]`. Pins the "streaming =
   no download" semantic.

7. **Contract-snapshot for borrow → present flow.**
   `PalaceTests/Contract/StreamingReaderPresentationContractTests.swift` NEW
   file. Use the existing `CallLog` + `ContractSnapshot` framework. Record
   the call order for `streamingHTMLBorrow_thenPresent` scenario:
   `borrowOp.borrow` → `registry.setState(.downloadSuccessful)` →
   `coordinator.presentStreamingReader(book:)` (or `.push(.streamingHTML(...))`).

## Files scoped to THIS implementer

Production:
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift` (case + 5 internal switches)
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift` (`.downloadSuccessful` / `.used` inner switch)
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonsView.swift` (accessibility ID switch at `:71`)
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` (3 switches at `:478, :493, :501` + `:564` `didSelectRead` content-type switch)
- `Palace/Book/UI/BookDetail/BookDetailView.swift` (switch at `:756`)
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` (switch at `:617` + `openBook` switch at `:847` + NEW `didSelectReadStreaming` method)
- `Palace/Book/UI/BookDetail/HalfSheetview.swift` (BOTH switches at `:94` and `:123`)
- `Palace/Book/UI/BookDetail/BookService.swift` (switch at `:49`)
- `Palace/Book/Models/TPPBook+Extensions.swift` (`format` switch `:63` + `sample` switch `:79`)
- `Palace/CatalogUI/Views/CatalogView.swift` (`resumeReading` switch at `:337`)
- `Palace/AppInfrastructure/NavigationCoordinator.swift` (new route OR presentation API)
- `Palace/AppInfrastructure/NavigationHostView.swift` (route render branch IF route shape chosen)
- `Palace/Utilities/Localization/Strings.swift` (`Strings.BookButton.readStreaming` + `Strings.BookDetailView.streamingHTMLContentType`)
- `Palace/Utilities/Testing/AccessibilityIdentifiers.swift` (`AccessibilityID.BookDetail.readStreamingButton`)

Tests:
- `PalaceTests/Book/BookButtonMapperTests.swift` (modify — streaming-HTML cases)
- `PalaceTests/MyBooks/BookCellModelTests.swift` (modify or NEW — didSelectRead streaming-HTML route)
- `PalaceTests/ViewModels/BookDetailViewModelTests.swift` (modify — handleAction + openBook + didSelectReadStreaming)
- `PalaceTests/Contract/StreamingReaderPresentationContractTests.swift` (NEW)
- `PalaceTests/Book/BookButtonTypeMetaTests.swift` (NEW — exhaustive case coverage META regression)

## Files explicitly OFF-LIMITS

- `Palace/Packages/PalaceCatalog/` — Module A
- `Palace/OPDS2/` — Module A
- `Palace/Book/Models/TPPContentType.swift`, `TPPBookContentTypeConverter.swift`, `TPPBook.swift` (additive scope) — Module A
- `Palace/ReaderStreaming/` — Module B (consume only — DO NOT modify B's files)
- `Palace/MyBooks/Borrow*.swift`, `Palace/MyBooks/Download*.swift`, `Palace/MyBooks/BookReturn*.swift` — anti-claim (no borrow/download/return changes)
- `Palace/Reader2/`, `Palace/Reader3/`, `Palace/Audiobooks/` — anti-claim
- `Palace/SignInLogic/`, `Palace/Packages/PalaceAuth/`, `Palace/Network/` — anti-claim
- ios-audiobooktoolkit submodule — anti-claim
- `Palace/Book/UI/BookDetail/BorrowReducer.swift` — DO NOT TOUCH. Adding `BookButtonType.readStreaming` does NOT force a compile error here (no exhaustive switch over cases). The `downloadRelatedButtons` static set explicitly excludes `.readStreaming` (streaming = no download). Verify by grep no edits.

## Verification criteria (MANDATORY — grep-able assertions)

1. **New case exists:**
   ```bash
   grep -c 'case readStreaming' Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift
   ```
   Must return 1.

2. **All 8 switch sites updated — grep `case .readStreaming` across the touched files:**
   ```bash
   sites=( \
     Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift \
     Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonsView.swift \
     Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift \
     Palace/Book/UI/BookDetail/BookDetailView.swift \
     Palace/Book/UI/BookDetail/BookDetailViewModel.swift \
     Palace/Book/UI/BookDetail/HalfSheetview.swift \
   )
   for f in "${sites[@]}"; do \
     count=$(grep -c '\.readStreaming\b' "$f"); \
     echo "$f: $count hits"; \
   done
   ```
   BookButtonType.swift ≥ 5 (case + 4 internal switches), BookButtonsView.swift ≥ 1,
   BookCellModel.swift ≥ 3, BookDetailView.swift ≥ 1, BookDetailViewModel.swift ≥ 2 (handleAction + didSelectReadStreaming),
   HalfSheetview.swift ≥ 2 (both switches).

3. **TPPBookContentType `.streamingHTML` is handled in 6 production switch sites:**
   ```bash
   for f in Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift \
            Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift \
            Palace/Book/UI/BookDetail/BookService.swift \
            Palace/Book/UI/BookDetail/BookDetailViewModel.swift \
            Palace/Book/Models/TPPBook+Extensions.swift \
            Palace/CatalogUI/Views/CatalogView.swift; do \
     count=$(grep -c '\.streamingHTML' "$f"); \
     echo "$f: $count"; \
   done
   ```
   Each file ≥ 1.

4. **No `default:` introduced where previously absent (F-011 guard):**
   ```bash
   # If a switch previously had no `default:`, it must remain so after the case
   # is added. Manual diff review for each of the 6+ switches.
   git diff origin/feat/PP-4161-streaming-html-reader -- \
     Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift \
     Palace/CatalogUI/Views/CatalogView.swift \
     | grep -E '^\+.*default:'
   ```
   Should be empty (no new defaults).

5. **didSelectReadStreaming exists and is called by handleAction:**
   ```bash
   grep -c 'didSelectReadStreaming' Palace/Book/UI/BookDetail/BookDetailViewModel.swift
   ```
   Must return ≥ 2 (definition + call site).

6. **SUT instantiation in test files:**
   ```bash
   grep -c 'BookButtonState\.' PalaceTests/Book/BookButtonMapperTests.swift
   grep -c 'BookCellModel(' PalaceTests/MyBooks/BookCellModelTests.swift
   grep -c 'BookDetailViewModel(' PalaceTests/ViewModels/BookDetailViewModelTests.swift
   ```
   Each ≥ 1.

7. **Method-level name-vs-body check:**
   ```bash
   python3 scripts/check-test-name-vs-body.py PalaceTests/Book/BookButtonMapperTests.swift
   python3 scripts/check-test-name-vs-body.py PalaceTests/MyBooks/BookCellModelTests.swift
   python3 scripts/check-test-name-vs-body.py PalaceTests/ViewModels/BookDetailViewModelTests.swift
   python3 scripts/check-test-name-vs-body.py PalaceTests/Contract/StreamingReaderPresentationContractTests.swift
   ```
   All exit 0.

8. **Multi-step test bodies actually drive the steps named:**
   The test `testBookDetailViewModel_didSelectGet_streamingHTMLBook_setsRegistryToDownloadSuccessful_thenButtonsAreReadStreaming`
   contains BOTH a `handleAction(for: .get)` call AND a subsequent
   `BookButtonState(...).buttonTypes(book:)` call. Manual verification of
   the test body required.

9. **BorrowReducer untouched (anti-claim verification):**
   ```bash
   git diff origin/feat/PP-4161-streaming-html-reader --name-only -- Palace/Book/UI/BookDetail/BorrowReducer.swift
   ```
   Must return empty.

10. **Mutation kill-rate ≥80% diff-scoped (critical path):**
    ```bash
    python3 scripts/palace_mutate.py \
      --file Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift \
      --tests PalaceTests/BookCellModelTests --diff-only --diff-base origin/feat/PP-4161-streaming-html-reader
    python3 scripts/palace_mutate.py \
      --file Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift \
      --tests PalaceTests/BookButtonTypeMetaTests --diff-only --diff-base origin/feat/PP-4161-streaming-html-reader
    python3 scripts/palace_mutate.py \
      --file Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift \
      --tests PalaceTests/BookButtonMapperTests --diff-only --diff-base origin/feat/PP-4161-streaming-html-reader
    ```
    Each ≥ 80% diff-scoped (100% ideal per CLAUDE.md critical-path).

11. **Tests pass:**
    ```bash
    xcodebuild ... -only-testing:PalaceTests/BookButtonMapperTests \
                   -only-testing:PalaceTests/BookCellModelTests \
                   -only-testing:PalaceTests/BookDetailViewModelTests \
                   -only-testing:PalaceTests/StreamingReaderPresentationContractTests \
                   -only-testing:PalaceTests/BookButtonTypeMetaTests test 2>&1 | grep -E "Test Suite '.*' passed"
    ```
    All five suites pass.

12. **`scripts/verify-pr.sh --quick`** PASS.

## Definition of Done evidence (critical path — paste ALL 10 self-checks per CLAUDE.md DoD)

1. SUT instantiation grep (per verification #6) — paste counts.
2. Function-result usage check on `didSelectReadStreaming(_:)` — `grep -E "= didSelectReadStreaming\(|let _ = didSelectReadStreaming" Palace/Book/UI/BookDetail/BookDetailViewModel.swift`. Document if the return is intentionally discarded.
3. Multi-step test body check (per verification #8) — paste verifying greps.
4. Scope coverage audit — every item in this contract appears in the diff OR is escalated per scope-deferral protocol.
5. Mutation pass (critical path) — per verification #10. Paste kill rates.
6. Build + verify-pr — paste tails.
7. Wiring-claim coverage — for the test `testBookDetailViewModel_handleAction_readStreaming_callsDidSelectReadStreaming`, paste coverage on `Palace/Book/UI/BookDetail/BookDetailViewModel.swift:didSelectReadStreaming` showing non-zero hits.
8. Contract reconciliation — `python3 scripts/check-contract-reconciliation.py --commit-msg <commit>` exit 0.
9. Blast-radius — `python3 scripts/check-blast-radius.py --quiet` exit 0. The new public API (`BookButtonType.readStreaming`, `didSelectReadStreaming`, possibly new `AppRoute.streamingHTML`) must be enumerated in commit body.
10. Adjacency staleness — `python3 scripts/check-adjacency-staleness.py --quiet` paste output.

## Implementer prompt

You are Module C implementer for swarm_c2b95c85 (PP-4161). **Critical-path
module** — touches MyBooks registry semantics (streaming-borrowed state) and
adds a `BookButtonType.readStreaming` case that propagates to 8 exhaustive
switches across `Palace/MyBooks/` and `Palace/Book/UI/BookDetail/`. Plus
extends the 6 `TPPBookContentType` switches across Book/MyBooks/CatalogUI to
add the `.streamingHTML` branch (some routes presentation, some content-type
formatting). Read `.forgeos/intent/pp-4161-streaming-html-reader.md` Claims
sections "Book Detail / button layer" + "MyBooks / state layer". Modules A
and B must be merged before you start — you consume A's
`TPPBookContentType.streamingHTML` case and B's `StreamingReaderView`. **No
new TPPBookState case** — after borrow, set the registry directly to
`.downloadSuccessful` and let the existing button mapping pick up the new
`.readStreaming` case via the `defaultBookContentType` switch. **DO NOT
touch BorrowReducer.swift** — adding the new BookButtonType case does NOT
force a compile error there (no exhaustive switch over cases). Mutation
kill-rate ≥80% diff-scoped on BookCellModel + BookButtonType + BookButtonState.
TDD per CLAUDE.md. Anti-scope: PalaceCatalog/, OPDS2/, Reader2/, Reader3/,
Audiobooks/, SignInLogic/, MyBooks/Borrow*, MyBooks/Download*, MyBooks/BookReturn*,
Network/, plus all dont_touch in manifest.yaml.
