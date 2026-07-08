# Module C — BookButton + Presenter Wiring transcript

**Status:** READY (Wave 2; critical_path)
**Implementer:** subagent
**Contract:** `.forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md` (v2.1)

## Summary

- Added `BookButtonType.readStreaming` case + arm in 5 internal `BookButtonType.swift` switches (`displaysIndicator`, `isDisabled`, `title`, `title(for:)`, `buttonStyle`) plus 4 external consumer switches (BookButtonsView accessibility, BookCellModel callDelegate 3-switch chain, NormalBookCell, BookDetailView handleButtonAction, BookDetailViewModel handleAction, HalfSheetView × 2). 9 switch sites total.
- Adopted v2 Option (c) presentation-layer mapping: `BookButtonState.downloadNeeded` over `defaultBookContentType` returns `[.readStreaming, .return]` for `.streamingHTML` (and `.downloadSuccessful, .used` appends `.readStreaming`). No registry-state shortcut, no Borrow/Download/BookReturn/Background edits.
- Extended 7 `TPPBookContentType` switches across BookCellModel (didSelectRead + callDelegate chain), BookButtonState (introduced new inner switch in `.downloadNeeded`), LocalBookContentService (no-op `break`), BookService.dispatchOpen, BookDetailViewModel.openBook, TPPBook+Extensions (`format` + `sample`), CatalogView.resumeReading (defensive skip with `Log.warn`).
- Added `BookDetailViewModel.didSelectReadStreaming(for:completion:)` + `presentStreamingReader(_:)` private helper that route via `NavigationCoordinatorHub` → `NavigationCoordinator.push(.streamingHTML(BookRoute(id:)))`.
- Added `AppRoute.streamingHTML(BookRoute)` to `NavigationCoordinator` + render branch in `NavigationHostView` that resolves the book payload and presents `StreamingReaderView` (Module B's SwiftUI surface). NavigationStack push (mirrors Reader2/Reader3), not sheet presentation.
- One-line guard at `BorrowOperation.swift:461` (v2.1 advisory F): `&& !borrowedBook.isStreamingHTML` appended to the F-014 auto-download condition. Prevents the borrow → MBDC.startDownload → fulfillment-failed → .downloadFailed → user-locked-out chain for streaming-HTML titles. `git diff --stat` shows 2 insertions / 1 deletion.
- Added `Strings.BookButton.readStreaming` ("Read") + `Strings.TPPBook.streamingHTMLContentType` ("Web Article") + `AccessibilityID.BookDetail.readStreamingButton` ("bookDetail.readStreamingButton").
- 6 test files (1 modified canonical, 1 modified BookDetailViewModelTests, 4 new). All 118 selected tests pass.

## Files (modified)

### Production (18 files, including AppInfrastructure/route render branch)

**BookButtonType propagation (9 switch sites):**
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift` — added `case readStreaming` + arm in 5 internal switches.
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonsView.swift` — added `.readStreaming` arm in accessibility ID switch.
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` — added `.readStreaming` to 3 exhaustive switches (callDelegate reachability gate + isLoading gate + dispatch) + extended `didSelectRead` content-type switch with `.streamingHTML` case routing to coordinator push.
- `Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift` — added `.readStreaming` to the `model.callDelegate(for: type)` arm.
- `Palace/Book/UI/BookDetail/BookDetailView.swift` — added `.readStreaming` to `handleButtonAction` switch (no half-sheet detour; routes straight to `viewModel.handleAction`).
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` — added `.readStreaming` to `handleAction` switch (calls new `didSelectReadStreaming(for:)` method); extended `openBook` content-type switch with `.streamingHTML` case; NEW method `didSelectReadStreaming(for:completion:)`; NEW private helper `presentStreamingReader(_:)`.
- `Palace/Book/UI/BookDetail/HalfSheetview.swift` — added `.readStreaming` to BOTH switch arms (full-size + compact half-sheet variants).

**TPPBookContentType propagation (7 switch sites):**
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` — `didSelectRead` switch (above) routes streamingHTML to `coordinator.push(.streamingHTML(...))`.
- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift` — INTRODUCED a new switch over `defaultBookContentType` inside `.downloadNeeded` arm (v2 Option (c) per architect advisory E); extended existing `.downloadSuccessful, .used` switch with `.streamingHTML` case appending `.readStreaming`.
- `Palace/MyBooks/LocalBookContentService.swift` — added `case .streamingHTML: break` with comment "streaming-HTML has no local on-device asset to delete".
- `Palace/Book/UI/BookDetail/BookService.swift` — added `.streamingHTML` arm to `dispatchOpen` switch that pushes the streamingHTML route via the coordinator.
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` — `openBook` switch extended (above).
- `Palace/Book/Models/TPPBook+Extensions.swift` — `format` switch: `.streamingHTML` returns `DisplayStrings.streamingHTMLContentType`. `sample` switch: `.streamingHTML` returns `nil` (no preview samples; replaced legacy `default:` arm with explicit `.streamingHTML` + `.unsupported` cases).
- `Palace/CatalogUI/Views/CatalogView.swift` — `resumeReading` switch: `.streamingHTML` joins `.audiobook` + `.unsupported` in the defensive-skip branch (RecentlyReadingService is expected to filter, but the `Log.warn` keeps drift observable).

**v2.1 controlled scope exception:**
- `Palace/MyBooks/BorrowOperation.swift` — ONE-LINE guard at `:461`: appended `&& !borrowedBook.isStreamingHTML` to the F-014 auto-download condition. `git diff --stat` = 2 insertions / 1 deletion.

**New API surface:**
- `Palace/AppInfrastructure/NavigationCoordinator.swift` — added `case streamingHTML(BookRoute)` to `AppRoute`.
- `Palace/AppInfrastructure/NavigationHostView.swift` — added `.streamingHTML(let bookRoute)` render branch that resolves the book payload via `coordinator.resolveBook(for:)` and presents `StreamingReaderView(book:)`.
- `Palace/Utilities/Localization/Strings.swift` — added `Strings.BookButton.readStreaming` (= "Read") + `Strings.TPPBook.streamingHTMLContentType` (= "Web Article").
- `Palace/Utilities/Testing/AccessibilityIdentifiers.swift` — added `AccessibilityID.BookDetail.readStreamingButton`.

### Tests (6 files)

Modified:
- `PalaceTests/BookStateManagement/BookButtonMapperTests.swift` — added 3 streaming-HTML cases: `testBookButtonState_buttonTypes_streamingHTMLDownloadNeeded_yieldsReadStreamingAndReturn`, `testBookButtonState_buttonTypes_streamingHTMLDownloadSuccessful_yieldsReadStreaming`, `testBookButtonState_buttonTypes_streamingHTMLUnregistered_yieldsGet`.
- `PalaceTests/Book/BookDetailViewModelTests.swift` — added `testBookDetailViewModel_handleAction_readStreaming_callsDidSelectReadStreaming` + `testBookDetailViewModel_didSelectGet_streamingHTMLBook_thenButtonsAreReadStreaming` (round-trip production-seam wiring).
- `PalaceTests/Book/TPPBookLocationTests.swift` — extended legacy `TPPBookContentTypeConverterTests.testStringValue_unsupported` to include `.streamingHTML` in the all-cases-unique assertion (grew from 4 to 5 cases). **Module A scope drift fix**: also renamed the new file's class to avoid collision (see "Gaps" below).

New:
- `PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift` — `testBookCellModel_didSelectRead_streamingHTMLBook_presentsStreamingReaderView_viaCoordinator` + negative control `testBookCellModel_didSelectRead_epubBook_doesNotPushStreamingRoute`.
- `PalaceTests/Contract/StreamingReaderPresentationContractTests.swift` — `testStreamingReaderPresentation_handleActionReadStreaming_callSequence` (uses `CallLog` + `ContractSnapshot.assert` against the snapshot at `PalaceTests/Contract/__Snapshots__/StreamingReaderPresentationContractTests/streamingHTMLReadAction_thenPresent.json`). NavigationCoordinator is `final` so the spy observes the production coordinator's path/bookById state post-call rather than subclassing.
- `PalaceTests/Book/BookButtonTypeMetaTests.swift` — `testBookButtonType_exhaustiveSwitch_coverage_includesReadStreaming` + 3 per-property pins (`buttonStyle == .primary`, `displaysIndicator == true`, `title == Strings.BookButton.readStreaming`).
- `PalaceTests/MyBooks/BorrowOperationStreamingHTMLTests.swift` — `testBorrowOperation_borrowSucceeded_streamingHTMLBook_doesNotCallStartDownload` + companion `testBorrowOperation_borrowSucceeded_epubBook_callsStartDownloadOnce` + edge case `testBorrowOperation_borrowSucceeded_streamingHTMLBook_attemptDownloadFalse_doesNotCallStartDownload`.

### Project file
- `Palace.xcodeproj/project.pbxproj` — registered 4 new test files for the `PalaceTests` target via `scripts/pbxproj_add_swift.rb`. Wave 1's pbxproj entries (5 ReaderStreaming production files + Module A's test files) are also present and untouched.

## Gaps for the integrator

1. **Module A scope drift — TPPBookContentTypeConverterTests class collision.** Module A wrote a NEW `PalaceTests/Book/TPPBookContentTypeConverterTests.swift` that defines `final class TPPBookContentTypeConverterTests`. A class of the SAME name already lived inline in `PalaceTests/Book/TPPBookLocationTests.swift:145`. This causes a "invalid redeclaration" compile error that blocked the Module C test build. Fix applied: renamed Module A's new class to `TPPBookContentTypeConverterStreamingHTMLTests` (file name unchanged for pbxproj alignment). The legacy class in `TPPBookLocationTests.swift` was also extended to include `.streamingHTML` in its `testStringValue_unsupported` all-cases assertion (it iterated `[.epub, .audiobook, .pdf, .unsupported]` and would have produced an incomplete all-cases-unique check after Module A's enum addition). **Integrator may want to consolidate the two classes into a single file post-merge** — they cover overlapping content-type-converter assertions and could live together; the inline-in-TPPBookLocationTests location is structural debt from before content-type tests had their own file.

2. **Mutation `--diff-only` does not see uncommitted changes.** The mutation script diffs `base..HEAD`; my changes are staged but not committed (per the orchestrator instruction "Do NOT commit"). I cannot pin the kill rate to my added lines via the diff-only mode. Workaround used: ran whole-file mutation for the most behaviorally rich seam (BorrowOperation.swift), inspected line numbers, and confirmed both line-461 mutants (`==` → `!=` and `&&` → `||` on my exact guard) are KILLED. Other surviving mutants are on pre-existing lines (e.g., 643 `isBrowserBased` branch, 588 SAML/OIDC paths) untouched by Module C. See "Definition-of-done evidence" #5 below for the per-file breakdown.

3. **Module A's `TPPContentTypeTests.swift` is at `PalaceTests/OPDS2/`** instead of `PalaceTests/Book/` per the original contract — already flagged in Module A's transcript. No action needed by Module C.

4. **`TPPCirculationAnalytics.postEvent` is called inside `didSelectReadStreaming`** mirroring the equivalent call in `openBook(_:completion:)`. The Cell-side route push (BookCellModel) does NOT fire analytics — consistent with the existing didSelectRead behavior (analytics fires only from the DetailView path, not the My-Books cell path). Integrator may want to add a `didSelectReadStreaming` analytics call site in the cell as a follow-up if instrumentation parity is desired.

## Definition-of-done evidence (10/10 paste pattern)

### #1 SUT instantiation check

```
BookButtonMapperTests / BookButtonState.: 5
BookCellModelStreamingHTMLTests / BookCellModel(: 1
BookDetailViewModelTests / BookDetailViewModel(: 13
StreamingReaderPresentationContractTests / BookDetailViewModel(: 1
BookButtonTypeMetaTests / BookButtonType.: 8
BorrowOperationStreamingHTMLTests / BorrowOperation(: 1
```

All ≥ 1.

Method-level name-vs-body check:
```
$ python3 scripts/check-test-name-vs-body.py \
    PalaceTests/BookStateManagement/BookButtonMapperTests.swift \
    PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift \
    PalaceTests/Book/BookDetailViewModelTests.swift \
    PalaceTests/Contract/StreamingReaderPresentationContractTests.swift \
    PalaceTests/Book/BookButtonTypeMetaTests.swift \
    PalaceTests/MyBooks/BorrowOperationStreamingHTMLTests.swift
OK: 6 file(s) checked, 0 fake-wiring tests found.
```

### #2 Function-result usage check

`didSelectReadStreaming(for:completion:)` returns `Void`. Result usage check is vacuous — no return value to bind. The completion closure IS used: `BookDetailViewModel.handleAction(.readStreaming)` passes `self.removeProcessingButton(button)` as the completion, exercised by `testBookDetailViewModel_handleAction_readStreaming_callsDidSelectReadStreaming` which asserts `!vm.isProcessing(for: .readStreaming)` post-call.

### #3 Multi-step test body check

Test names containing multi-step keywords:
- `testBookDetailViewModel_didSelectGet_streamingHTMLBook_thenButtonsAreReadStreaming` — name has "didSelectGet" + "thenButtonsAreReadStreaming". Body literally exercises BOTH steps: half 1 asserts the v2 Option (c) post-borrow state (`BookButtonState.downloadNeeded`), half 2 calls `postBorrowState.buttonTypes(book:)` through the production seam and asserts the result. Test body cited inline in the test docstring; the assertion is `XCTAssertEqual(buttons, [.readStreaming, .return], ...)`.
- `testBookCellModel_didSelectRead_streamingHTMLBook_presentsStreamingReaderView_viaCoordinator` — name has "viaCoordinator". Body asserts `coordinator.path.count == 1` AND `coordinator.resolveBook(for:) != nil` — both halves verified.

### #4 Scope coverage audit

Per contract `files_scope` (15 production files + 6 test files):
- All 9 BookButtonType switch sites updated — ✓ (verified via grep #2 below)
- All 7 TPPBookContentType switch sites updated — ✓ (verified via grep #3 below)
- BorrowOperation:461 guard — ✓ (2 insertions, 1 deletion, contains `isStreamingHTML`)
- New API surface (didSelectReadStreaming, AppRoute.streamingHTML, NavigationHostView render branch, Strings, AccessibilityIdentifiers) — ✓
- 6 test files exist — ✓

No scope reductions. The Module A test-class-collision fix (item #1 in Gaps) is the only scope-adjacent edit; documented for the integrator.

### #5 Mutation pass (critical-path threshold ≥80% diff-scoped, ideally 100% on touched lines)

**Limitation:** `palace_mutate.py --diff-only` uses `git diff <base>..HEAD`, which does not include uncommitted changes. Per orchestrator instructions ("Do NOT commit. Leave changes staged"), I cannot create the temporary commit the diff-only mode requires. Workaround: ran whole-file mutation, inspected per-line results for the lines I touched.

**Palace/MyBooks/BorrowOperation.swift (critical-path; BookButtonState's sibling auto-download chain):**
```
[2/8] line 461 cmp: '==' -> '!='        KILLED  (47.0s)
[7/8] line 461 bool: '&&' -> '||'       KILLED  (50.1s)
```
Both mutants on my exact guard line (`if attemptDownload && mapping.state == .downloadNeeded && !borrowedBook.isStreamingHTML`) are KILLED by `BorrowOperationStreamingHTMLTests`. Touched-line kill rate: **2/2 = 100%**.

Other survived mutants (lines 588, 614, 616, 643, 798, 838) are on pre-existing untouched code paths (browser-based reauth, error formatting, fetch-result branches) and not in scope for Module C — they reflect pre-existing coverage gaps in BorrowOperationTests, not Module C work.

**Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift:** No mutable operators on my added lines — all my changes are enum-pattern switch arms (case .streamingHTML: → buttons = ...). Whole-file mutation reports operate exclusively on pre-existing predicates in `stateForAvailability` (lines 195, 216) and `supportsDeletion` (lines 219-221), which are out of scope for Module C. Behavioral coverage is provided directly by BookButtonMapperTests' three streaming-HTML tests (each asserts `XCTAssertTrue(buttons.contains(.readStreaming))` / `XCTAssertFalse(buttons.contains(.download))` style explicit pins).

**Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift:** 4 total mutation points in the whole file, all in pre-existing `isPrimary` / `hasBorder` helper properties (lines 125, 129). My added arms are enum-pattern matches (immune to mutation). Behavioral coverage by BookButtonTypeMetaTests asserts each property directly.

**Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift:** Whole-file mutation cache key would invalidate on every BookCellModel test edit; not re-run for Module C. The behavioral coverage is BookCellModelStreamingHTMLTests' two production-seam tests (positive + negative) that drive `didSelectRead` and assert the coordinator side effect. The reachability pre-flight on `.readStreaming` is the only mutable line I added (`if !reachability.isConnectedToNetwork()`); it shares mutation semantics with the existing download/get/retry/reserve pre-flight which IS covered by BookCellModelOfflineTests.

### #6 Build + verify-pr

```
$ xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D' \
    -derivedDataPath /tmp/dd-modC-final-... build 2>&1 | tail -3
warning: 'ReadiumShared' is missing a dependency on 'SwiftSoup' ...
** BUILD SUCCEEDED **

$ xcodebuild -project Palace.xcodeproj -scheme Palace-noDRM \
    -destination 'platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D' \
    -derivedDataPath /tmp/dd-modC-build-noDRM build 2>&1 | tail -1
** BUILD SUCCEEDED **
```

Both targets compile. `scripts/verify-pr.sh --quick` deferred to orchestrator Phase 4.5 against the merged Wave 1 + Wave 2 + Wave 3 state.

### #7 Test xcresult bundle path

```
$ DD=/tmp/dd-modC-test-rerun-...; xcodebuild ... \
    -only-testing:PalaceTests/BookButtonMapperTests \
    -only-testing:PalaceTests/BookCellModelStreamingHTMLTests \
    -only-testing:PalaceTests/BookDetailViewModelTests \
    -only-testing:PalaceTests/StreamingReaderPresentationContractTests \
    -only-testing:PalaceTests/BookButtonTypeMetaTests \
    -only-testing:PalaceTests/BorrowOperationStreamingHTMLTests test ...
Test Suite 'Selected tests' passed at 2026-06-03 11:58:26.137.
     Executed 118 tests, with 0 failures (0 unexpected) in 1.431 (1.558) seconds

$ ls /tmp/dd-modC-test-rerun-2525/Logs/Test/*.xcresult
/tmp/dd-modC-test-rerun-2525/Logs/Test/Test-Palace-2026.06.03_11-57-14--0400.xcresult
```

118 tests, 0 failures. Contract snapshot file committed at `PalaceTests/Contract/__Snapshots__/StreamingReaderPresentationContractTests/streamingHTMLReadAction_thenPresent.json`.

### #7 (alt: multi-step / wiring-claim coverage)

`testBookDetailViewModel_handleAction_readStreaming_callsDidSelectReadStreaming` invokes `vm.handleAction(for: .readStreaming)` which dispatches into `handleAction`'s switch → `didSelectReadStreaming(for: book) { ... }` → `presentStreamingReader(book)` → `coordinator.store(book:)` → `coordinator.push(.streamingHTML(BookRoute(id:)))`. The assertion `coordinator.path.count == 1` is non-zero only if every step in that chain executed — proving wiring coverage. (Coverage tool not run separately because the test would have failed if any line was skipped.)

### #8 Contract reconciliation

Deferred to orchestrator Phase 4.5 — `check-contract-reconciliation.py --commit-msg <file>` runs against the final commit message. Module C does not commit per orchestrator instruction; the integrator will reconcile claims against the Wave 2 commit body.

### #9 Blast-radius check

```
$ python3 scripts/check-blast-radius.py --quiet
EXIT=0
```

New public API surface (`BookButtonType.readStreaming`, `BookDetailViewModel.didSelectReadStreaming`, `AppRoute.streamingHTML`, `Strings.BookButton.readStreaming`, `Strings.TPPBook.streamingHTMLContentType`, `AccessibilityID.BookDetail.readStreamingButton`) all declared internal (default) or part of existing public namespaces (NavigationCoordinator's `AppRoute` is module-internal). No new `#if DEBUG` on production paths, no test-only AppContainer init params, no discarded function results without justification. Module B's `StreamingReaderView` is the only consumer of `AppRoute.streamingHTML` and is public for the SwiftUI route render branch.

### #10 Adjacency staleness check

```
$ python3 scripts/check-adjacency-staleness.py --quiet
EXIT=0
```

No production types removed or renamed.

## Verification-grep evidence (Contract C section)

```
=== Verification #1: New case exists ===
1                                             # case readStreaming in BookButtonType.swift

=== Verification #2: All 9 BookButtonType switch sites ===
Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift: 5 hits         # +1 'case readStreaming' = 6 (matches contract ≥6)
Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonsView.swift: 1 hits
Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift: 4 hits                     # 3 switches + 1 didSelectRead route push
Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift: 1 hits
Palace/Book/UI/BookDetail/BookDetailView.swift: 1 hits
Palace/Book/UI/BookDetail/BookDetailViewModel.swift: 2 hits                     # handleAction switch + call site
Palace/Book/UI/BookDetail/HalfSheetview.swift: 4 hits                           # both switches × 2 (case+comment)

=== Verification #3: TPPBookContentType .streamingHTML in 7 sites ===
Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift: 2
Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift: 2
Palace/MyBooks/LocalBookContentService.swift: 1
Palace/Book/UI/BookDetail/BookService.swift: 2
Palace/Book/UI/BookDetail/BookDetailViewModel.swift: 3
Palace/Book/Models/TPPBook+Extensions.swift: 2
Palace/CatalogUI/Views/CatalogView.swift: 1

=== Verification #4: No new `default:` in switches ===
(grep returned only the comment in BookButtonState.swift that documents the absence of `default:`)

=== Verification #5: Anti-scope untouched ===
(empty: no edits to BorrowReducer.swift, Download*, BookReturn*, MyBooksDownloadCenter.swift, Background*, Reader2/, Reader3/, Audiobooks/, SignInLogic/, Network/TPP*Responder/Executor)

=== Verification #5 (alt): BorrowOperation.swift one-line guard ===
git diff --stat: 2 insertions, 1 deletion
isStreamingHTML occurrences in diff: 1

=== Verification #6: didSelectReadStreaming definition + call site ===
Palace/Book/UI/BookDetail/BookDetailViewModel.swift:649: didSelectReadStreaming(for: book) {  # call site (handleAction)
Palace/Book/UI/BookDetail/BookDetailViewModel.swift:920: func didSelectReadStreaming(for ...) # definition
```
