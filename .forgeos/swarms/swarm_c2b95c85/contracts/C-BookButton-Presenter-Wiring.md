# Module C — BookButton + Presenter Wiring (critical path)

**Critical-path module.** Touches `Palace/MyBooks/` display logic (BookButtonState
content-type switch + BookCellModel.didSelectRead routing) AND adds the new
`BookButtonType.readStreaming` case that propagates to 9 exhaustive switches.
Per CLAUDE.md "Risk-driven rigor bar", anything touching MyBooks user-access
decision points triggers architect post-review. Mutation kill-rate ≥80%
diff-scoped on touched MyBooks files.

**v2 changes from architect post-review (Phase 1a, 2026-06-03):**
- Adopts Option (c) for the linchpin question — Module C is now **purely
  presentation-layer**. No registry-state shortcut. `BookButtonState` maps
  streaming-HTML books from `.downloadNeeded` directly to `[.readStreaming, .return]`
  (skipping the normal Get → Download → Read flow). No edits to MyBooksDownloadCenter,
  borrow-completion files, or anything in `MyBooks/Borrow*` / `MyBooks/Download*`.
- Adds `Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift:218` to scope (F1).
- Adds `Palace/MyBooks/LocalBookContentService.swift:77` to scope (F2).
- Fixes 3 wrong test file paths (F4).
- Standardizes BookButtonType internal switch count to 5 (F5).

## Goal

1. Add `BookButtonType.readStreaming` and update ALL 9 exhaustive switch sites
   across the codebase (including 5 internal in `BookButtonType.swift`).
2. Extend the 7 `TPPBookContentType` switches across `Palace/Book/`,
   `Palace/MyBooks/`, and `Palace/CatalogUI/` to handle `.streamingHTML`.
   For routing switches (`didSelectRead`, `dispatchOpen`, `openBook`), the
   new branch presents the new `StreamingReaderView` via the navigation
   coordinator. For the no-op site (`LocalBookContentService.deleteLocalContent`),
   the branch is `break` with a `// streaming-HTML has no local asset` comment.
3. Update `BookButtonState.buttonTypes(book:)` so streaming-HTML books map
   `.downloadNeeded` → `[.readStreaming, .return]` (skipping Get → Download →
   Read normal flow). This is the entire "streaming = no download" semantic —
   no registry-state change, no borrow-completion edit.
4. Wire `BookDetailViewModel.handleAction(for: .readStreaming)` →
   `didSelectReadStreaming(for: book)` → navigation coordinator presentation
   of `StreamingReaderView`.

## What public types/protocols change

- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift`:
  - Enum gains `case readStreaming`
  - 5 internal exhaustive `switch self` over BookButtonType each gain a
    `.readStreaming` arm: `displaysIndicator`, `isDisabled`, `title`,
    `title(for:)`, `buttonStyle`
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift`:
  - `buttonTypes(book:)` `.downloadNeeded` branch's inner switch over
    `defaultBookContentType` gains `case .streamingHTML: return [.readStreaming, .return]`
  - `.downloadSuccessful` / `.used` branches' inner switch also gains
    `case .streamingHTML: buttons.append(.readStreaming)` (for the eventual
    case where a streaming-HTML title was already in `.downloadSuccessful` from
    a prior session — same display behavior)
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

1. **BookButtonState streaming-HTML unborrowed yields readStreaming + return (mandatory).**
   `testBookButtonState_buttonTypes_streamingHTMLDownloadNeeded_yieldsReadStreamingAndReturn`.
   Build a `TPPBook` whose `defaultBookContentType == .streamingHTML`,
   bookRegistry state `.downloadNeeded`, assert
   `BookButtonState.downloadNeeded.buttonTypes(book:)` returns `[.readStreaming, .return]`
   (NOT `[.download, .return]`). Pins the "streaming = no download" semantic
   at the presentation layer.

2. **BookButtonState streaming-HTML downloadSuccessful yields readStreaming (mandatory).**
   `testBookButtonState_buttonTypes_streamingHTMLDownloadSuccessful_yieldsReadStreaming`.
   Same book, registry state `.downloadSuccessful`, assert button list
   contains `.readStreaming` (NOT `.read` or `.listen`).

3. **BookButtonState streaming-HTML unregistered yields get (mandatory).**
   `testBookButtonState_buttonTypes_streamingHTMLUnregistered_yieldsGet`.
   Same book, registry state `.unregistered`, OPDS availability unlimited,
   assert `[.get]`. Confirms pre-borrow flow is unchanged.

4. **BookCellModel.didSelectRead routes streaming-HTML via coordinator (mandatory).**
   `testBookCellModel_didSelectRead_streamingHTMLBook_presentsStreamingReaderView_viaCoordinator`.
   Construct with a `MockNavigationCoordinator`, call `didSelectRead()` on a
   streaming-HTML book, assert the mock recorded a `push(.streamingHTML(...))`
   OR `presentStreamingReader(book:)` call (whichever route shape was chosen).

5. **BookDetailViewModel.handleAction(.readStreaming) (mandatory).**
   `testBookDetailViewModel_handleAction_readStreaming_callsDidSelectReadStreaming`.
   Inject a `MockNavigationCoordinator`. Call `handleAction(for: .readStreaming)`.
   Assert the mock recorded the presentation. Assert `processingButtons`
   contained `.readStreaming` during the call (regression net for the
   `processingButtons.insert(button)` line).

6. **Exhaustive switch META regression test.**
   `testBookButtonType_exhaustiveSwitch_coverage_includesReadStreaming`.
   Iterate over all `BookButtonType` cases (via reflection or hardcoded list)
   and assert each yields a non-empty `localizedTitle`, a non-nil
   accessibility ID at `BookButtonsView.accessibilityID(for:)`, and a
   defined `buttonStyle`. Catches the next case-addition that forgets a switch
   arm.

7. **Streaming-HTML borrow happy path (mandatory — production-seam wiring).**
   `testBookDetailViewModel_didSelectGet_streamingHTMLBook_thenButtonsAreReadStreaming`.
   Drive the borrow happy path for a streaming-HTML book through the
   production seam (`handleAction(for: .get)`), assert that after borrow
   completion the registry state IS `.downloadNeeded` (the NORMAL post-borrow
   state — Module C does NOT change this) AND `BookButtonState.downloadNeeded.buttonTypes(book:)`
   yields `[.readStreaming, .return]`. Pins the v2 Option-(c) semantic:
   presentation maps `.downloadNeeded` + streamingHTML → readStreaming, no
   state-machine change.

8. **Contract-snapshot for handleAction → present flow.**
   `PalaceTests/Contract/StreamingReaderPresentationContractTests.swift` NEW
   file. Use the existing `CallLog` + `ContractSnapshot` framework. Record
   the call order for `streamingHTMLReadAction_thenPresent` scenario:
   `viewModel.handleAction(for: .readStreaming)` →
   `processingButtons.insert(.readStreaming)` →
   `coordinator.presentStreamingReader(book:)` (or `.push(.streamingHTML(...))`).

## Files scoped to THIS implementer

Production (15 files):

**BookButtonType propagation (9 switch sites total):**
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift` (case + 5 internal switches: displaysIndicator, isDisabled, title, title(for:), buttonStyle)
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonsView.swift` (accessibility ID switch at `:71`)
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` (3 switches at `:478, :493, :501`)
- `Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift` (exhaustive switch at `:218` — add `.readStreaming` to the `model.callDelegate(for: type)` arm) **[ADDED v2 per F1]**
- `Palace/Book/UI/BookDetail/BookDetailView.swift` (switch at `:756`)
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` (switch at `:617`)
- `Palace/Book/UI/BookDetail/HalfSheetview.swift` (BOTH switches at `:94` and `:123`)

**TPPBookContentType propagation (7 switch sites total):**
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` (`:564` `didSelectRead` content-type switch — case `.streamingHTML` routes to coordinator presentation)
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift` (`.downloadNeeded` + `.downloadSuccessful` + `.used` inner switches over `defaultBookContentType`)
- `Palace/MyBooks/LocalBookContentService.swift` (`:77` switch — case `.streamingHTML: break` with comment "streaming-HTML has no local on-device asset") **[ADDED v2 per F2]**
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` (`openBook` switch at `:847` — case `.streamingHTML` presents StreamingReaderView)
- `Palace/Book/UI/BookDetail/BookService.swift` (`dispatchOpen` switch at `:49` — case `.streamingHTML` presents StreamingReaderView)
- `Palace/Book/Models/TPPBook+Extensions.swift` (`format` switch `:63` + `sample` switch `:79` — display strings)
- `Palace/CatalogUI/Views/CatalogView.swift` (`resumeReading` switch at `:337` — defensively skip with `Log.warn`, mirroring `.audiobook` handling)

**New API surface:**
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` (NEW `didSelectReadStreaming(for:)` method — counted as one of the BookButtonType + TPPBookContentType files above; no extra file)
- `Palace/AppInfrastructure/NavigationCoordinator.swift` (new route OR presentation API)
- `Palace/AppInfrastructure/NavigationHostView.swift` (route render branch IF route shape chosen)
- `Palace/Utilities/Localization/Strings.swift` (`Strings.BookButton.readStreaming` + `Strings.BookDetailView.streamingHTMLContentType`)
- `Palace/Utilities/Testing/AccessibilityIdentifiers.swift` (`AccessibilityID.BookDetail.readStreamingButton`)

Tests (5 files):
- `PalaceTests/BookStateManagement/BookButtonMapperTests.swift` (modify — canonical class; add streaming-HTML cases for `.downloadNeeded`, `.downloadSuccessful`, `.unregistered`) **[FIXED v2 per F4 — canonical class location, not the Extended file in PalaceTests/Book/]**
- `PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift` (NEW — `didSelectRead` streaming-HTML route assertions; sits alongside the existing `BookCellModelOfflineTests.swift`) **[FIXED v2 per F4 — new file name; the file `PalaceTests/MyBooks/BookCellModelTests.swift` does not exist]**
- `PalaceTests/Book/BookDetailViewModelTests.swift` (modify — handleAction + openBook + didSelectReadStreaming assertions) **[FIXED v2 per F4 — actual path is `PalaceTests/Book/`, not `PalaceTests/ViewModels/`]**
- `PalaceTests/Contract/StreamingReaderPresentationContractTests.swift` (NEW)
- `PalaceTests/Book/BookButtonTypeMetaTests.swift` (NEW — exhaustive case coverage META regression)

## Files explicitly OFF-LIMITS

- `Palace/Packages/PalaceCatalog/` — Module A
- `Palace/OPDS2/` — Module A
- `Palace/Book/Models/TPPContentType.swift`, `TPPBookContentTypeConverter.swift`, `TPPBook.swift` (additive scope) — Module A
- `Palace/ReaderStreaming/` — Module B (consume only — DO NOT modify B's files)
- `Palace/MyBooks/Borrow*.swift`, `Palace/MyBooks/Download*.swift`, `Palace/MyBooks/BookReturn*.swift`, `Palace/MyBooks/Background*.swift`, `Palace/MyBooks/MyBooksDownloadCenter.swift` — anti-claim (NO borrow / download / return changes; v2 Option (c) makes these untouchable)
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

2. **All 9 BookButtonType switch sites updated — grep `case .readStreaming` across the touched files:**
   ```bash
   sites=( \
     Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift \
     Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonsView.swift \
     Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift \
     Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift \
     Palace/Book/UI/BookDetail/BookDetailView.swift \
     Palace/Book/UI/BookDetail/BookDetailViewModel.swift \
     Palace/Book/UI/BookDetail/HalfSheetview.swift \
   )
   for f in "${sites[@]}"; do \
     count=$(grep -c '\.readStreaming\b' "$f"); \
     echo "$f: $count hits"; \
   done
   ```
   Expected:
   - BookButtonType.swift ≥ 6 (case + 5 internal switches)
   - BookButtonsView.swift ≥ 1
   - BookCellModel.swift ≥ 3
   - NormalBookCell.swift ≥ 1
   - BookDetailView.swift ≥ 1
   - BookDetailViewModel.swift ≥ 2 (handleAction + didSelectReadStreaming method body / call site)
   - HalfSheetview.swift ≥ 2 (both switches)

3. **TPPBookContentType `.streamingHTML` is handled in 7 production switch sites:**
   ```bash
   for f in Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift \
            Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift \
            Palace/MyBooks/LocalBookContentService.swift \
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
   git diff origin/feat/PP-4161-streaming-html-reader -- \
     Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift \
     Palace/MyBooks/LocalBookContentService.swift \
     Palace/CatalogUI/Views/CatalogView.swift \
     Palace/Book/Models/TPPBook+Extensions.swift \
     | grep -E '^\+.*default:'
   ```
   Should be empty (no new defaults).

5. **BorrowReducer untouched (anti-claim verification — v2 makes this extra-strict):**
   ```bash
   git diff origin/feat/PP-4161-streaming-html-reader --name-only -- \
     Palace/Book/UI/BookDetail/BorrowReducer.swift \
     Palace/MyBooks/Borrow*.swift \
     Palace/MyBooks/Download*.swift \
     Palace/MyBooks/BookReturn*.swift \
     Palace/MyBooks/MyBooksDownloadCenter.swift \
     Palace/MyBooks/Background*.swift
   ```
   Must return empty. (v2 Option (c) — purely presentation. No borrow/download/return edits.)

6. **didSelectReadStreaming exists and is called by handleAction:**
   ```bash
   grep -c 'didSelectReadStreaming' Palace/Book/UI/BookDetail/BookDetailViewModel.swift
   ```
   Must return ≥ 2 (definition + call site in handleAction switch).

7. **SUT instantiation in test files (paths corrected per F4):**
   ```bash
   grep -c 'BookButtonState\.' PalaceTests/BookStateManagement/BookButtonMapperTests.swift
   grep -c 'BookCellModel(' PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift
   grep -c 'BookDetailViewModel(' PalaceTests/Book/BookDetailViewModelTests.swift
   ```
   Each ≥ 1.

8. **Method-level name-vs-body check (paths corrected per F4):**
   ```bash
   python3 scripts/check-test-name-vs-body.py PalaceTests/BookStateManagement/BookButtonMapperTests.swift
   python3 scripts/check-test-name-vs-body.py PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift
   python3 scripts/check-test-name-vs-body.py PalaceTests/Book/BookDetailViewModelTests.swift
   python3 scripts/check-test-name-vs-body.py PalaceTests/Contract/StreamingReaderPresentationContractTests.swift
   python3 scripts/check-test-name-vs-body.py PalaceTests/Book/BookButtonTypeMetaTests.swift
   ```
   All exit 0.

9. **Multi-step test bodies actually drive the steps named:**
   The test `testBookDetailViewModel_didSelectGet_streamingHTMLBook_thenButtonsAreReadStreaming`
   contains BOTH a `handleAction(for: .get)` call AND a subsequent
   `BookButtonState.downloadNeeded.buttonTypes(book:)` call. Manual verification of
   the test body required.

10. **Mutation kill-rate ≥80% diff-scoped (critical path):**
    ```bash
    python3 scripts/palace_mutate.py \
      --file Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift \
      --tests PalaceTests/BookCellModelOfflineTests --diff-only --diff-base origin/feat/PP-4161-streaming-html-reader
    python3 scripts/palace_mutate.py \
      --file Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift \
      --tests PalaceTests/BookButtonTypeMetaTests --diff-only --diff-base origin/feat/PP-4161-streaming-html-reader
    python3 scripts/palace_mutate.py \
      --file Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift \
      --tests PalaceTests/BookButtonMapperTests --diff-only --diff-base origin/feat/PP-4161-streaming-html-reader
    ```
    Each ≥ 80% diff-scoped (100% ideal per CLAUDE.md critical-path). Note:
    `--tests PalaceTests/BookCellModelOfflineTests` is the existing class
    name in the canonical test file `BookCellModelOfflineTests.swift`; the
    new `BookCellModelStreamingHTMLTests` class is invoked separately:
    `--tests PalaceTests/BookCellModelStreamingHTMLTests`.

11. **Tests pass (corrected selectors):**
    ```bash
    xcodebuild ... -only-testing:PalaceTests/BookButtonMapperTests \
                   -only-testing:PalaceTests/BookCellModelStreamingHTMLTests \
                   -only-testing:PalaceTests/BookDetailViewModelTests \
                   -only-testing:PalaceTests/StreamingReaderPresentationContractTests \
                   -only-testing:PalaceTests/BookButtonTypeMetaTests test 2>&1 | grep -E "Test Suite '.*' passed"
    ```
    All five suites pass. (Note: `BookButtonMapperTests` matches the canonical
    `PalaceTests/BookStateManagement/BookButtonMapperTests.swift` class, not
    the `BookButtonMapperExtendedTests` class in `PalaceTests/Book/`.)

12. **`scripts/verify-pr.sh --quick`** PASS.

## Definition of Done evidence (critical path — paste ALL 10 self-checks per CLAUDE.md DoD)

1. SUT instantiation grep (per verification #7) — paste counts.
2. Function-result usage check on `didSelectReadStreaming(_:)` — `grep -E "= didSelectReadStreaming\(|let _ = didSelectReadStreaming" Palace/Book/UI/BookDetail/BookDetailViewModel.swift`. Document if the return is intentionally discarded.
3. Multi-step test body check (per verification #9) — paste verifying greps.
4. Scope coverage audit — every item in this contract (15 production files +
   5 test files) appears in the diff OR is escalated per scope-deferral
   protocol.
5. Mutation pass (critical path) — per verification #10. Paste kill rates.
6. Build + verify-pr — paste tails.
7. Wiring-claim coverage — for the test
   `testBookDetailViewModel_handleAction_readStreaming_callsDidSelectReadStreaming`,
   paste coverage on `Palace/Book/UI/BookDetail/BookDetailViewModel.swift:didSelectReadStreaming`
   showing non-zero hits.
8. Contract reconciliation — `python3 scripts/check-contract-reconciliation.py --commit-msg <commit>` exit 0.
9. Blast-radius — `python3 scripts/check-blast-radius.py --quiet` exit 0. The
   new public API (`BookButtonType.readStreaming`, `didSelectReadStreaming`,
   possibly new `AppRoute.streamingHTML`) must be enumerated in commit body.
10. Adjacency staleness — `python3 scripts/check-adjacency-staleness.py --quiet` paste output.

## Implementer prompt

You are Module C implementer for swarm_c2b95c85 (PP-4161). **Critical-path
module** — touches MyBooks display logic (BookButtonState mapping streaming-HTML
books from `.downloadNeeded` directly to `[.readStreaming, .return]`) and adds
a `BookButtonType.readStreaming` case that propagates to **9** exhaustive
switches across `Palace/MyBooks/` and `Palace/Book/UI/BookDetail/`. Plus
extends the **7** `TPPBookContentType` switches across Book/MyBooks/CatalogUI
to add the `.streamingHTML` branch (some routes presentation, some content-type
formatting, one no-op).

Read `.forgeos/intent/pp-4161-streaming-html-reader.md` Claims sections
"Book Detail / button layer" + "MyBooks / state layer". Modules A and B must
be merged before you start — you consume A's `TPPBookContentType.streamingHTML`
case and B's `StreamingReaderView`.

**v2 Option (c) — purely presentation, no registry shortcut.** After borrow,
the registry transitions to its NORMAL post-borrow state (`.downloadNeeded`).
Module C does NOT change the registry state machine. Instead,
`BookButtonState.buttonTypes(book:)` `.downloadNeeded` branch's inner switch
over `defaultBookContentType` adds `case .streamingHTML: return [.readStreaming, .return]`.
That's the entire "streaming = no download" semantic. **No edits to MyBooksDownloadCenter,
Borrow*, Download*, BookReturn*, Background* files. NO new TPPBookState case.**

**DO NOT touch BorrowReducer.swift** — adding the new BookButtonType case does
NOT force a compile error there (no exhaustive switch over cases). Mutation
kill-rate ≥80% diff-scoped on BookCellModel + BookButtonType + BookButtonState.
TDD per CLAUDE.md.

Anti-scope: PalaceCatalog/, OPDS2/, Reader2/, Reader3/, Audiobooks/,
SignInLogic/, MyBooks/Borrow*, MyBooks/Download*, MyBooks/BookReturn*,
MyBooks/Background*, MyBooks/MyBooksDownloadCenter.swift, Network/, plus all
dont_touch in manifest.yaml.
