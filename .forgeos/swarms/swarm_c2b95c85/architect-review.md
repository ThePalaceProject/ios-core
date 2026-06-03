# Architect post-review — swarm_c2b95c85

**Reviewer:** general-purpose (Phase 1a)
**At:** 2026-06-03T00:00:00Z
**Verdict:** BLOCKED

The architect's triage is mostly sound and the deviation list (plan.md §Risks 1-9) catches the big spec gaps from the intent file. But the scope counts and the `files_scope` enumeration miss enough real switch sites and have enough internal inconsistency that the implementer who tries to land Module C against this contract will hit unexpected compile errors AND will not know where to put the linchpin "set registry to .downloadSuccessful after streaming-HTML borrow" change. Fix the issues below, re-emit Module C contract, then re-review.

## Verifications run

### 1. BookButtonType.swift internal switch sites — architect claims 4 internal switches

```
$ grep -n 'switch self' Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift
36:        switch self {   ← displaysIndicator (exhaustive)
49:        switch self {   ← isDisabled (exhaustive)
64:        switch self {   ← title (exhaustive)
88:        switch self {   ← title(for:) (exhaustive)
98:        switch self {   ← buttonStyle (exhaustive)
```

The other 3 (lines 119, 128, 140) switch over `ButtonStyleType`, not `BookButtonType` — those will not flag.

**Verdict: PASS-with-inconsistency.** Five internal `switch self` over BookButtonType, not four. **plan.md §Risks #2 says "4 internal switches in BookButtonType.swift itself".** Contract C's `files_scope` says "add .readStreaming case + update 4 internal exhaustive switches: displaysIndicator, isDisabled, title, title(for:), buttonStyle" — that's 5 listed by name but called "4". Internal arithmetic inconsistency: list says 5, summary says 4, plan.md says 4. Pick one. The grep verification "BookButtonType.swift ≥ 5 (case + 4 internal switches)" should be ≥ 6 (case + 5 switches).

### 2. BookButtonType switch sites across the codebase

```
$ grep -rln 'BookButtonType\b' Palace/ --include='*.swift' | sort -u
Palace/Book/UI/BookDetail/BookDetailView.swift
Palace/Book/UI/BookDetail/BookDetailViewModel.swift
Palace/Book/UI/BookDetail/BorrowReducer.swift
Palace/Book/UI/BookDetail/HalfSheetview.swift
Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift
Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift
Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonsView.swift
Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift
Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift   ← NOT in Contract C files_scope, NOT in dont_touch
```

Inspected `Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift:218`:

```swift
// Exhaustive (no `default:`) — F-011 class-of-bug guard. Compiler
// flags this site if BookButtonType gains a case, so a button
// can't silently route to the callDelegate fallback.
switch type {
case .close: ...
case .get, .reserve, .download, .read, .listen, .retry, .cancel,
     .sample, .audiobookSample, .remove, .cancelHold,
     .manageHold, .return, .returning:
     model.callDelegate(for: type)
}
```

**Verdict: FAIL — missed scope site.** This is an EXHAUSTIVE switch over BookButtonType. Adding `.readStreaming` WILL cause a compile error here. The architect's "8 exhaustive switches" count is wrong — it's at least 9 (or 10 if you count BookButtonType.swift's 5 internal switches separately). **NormalBookCell.swift:218 must be added to Contract C's `files_scope`.**

### 3. TPPBookContentType switch sites — architect claims 6

```
$ grep -rln 'TPPBookContentType\b\|defaultBookContentType' Palace/ --include='*.swift'
```

Files with exhaustive `switch *defaultBookContentType` (compile-error class):

- `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift:67` ✓ in scope (exhaustive)
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift:847` ✓ in scope (HAS default — won't compile-error)
- `Palace/Book/UI/BookDetail/BookService.swift:49` ✓ in scope (HAS default — won't compile-error)
- `Palace/Book/Models/TPPBook+Extensions.swift:63 (format)` ✓ in scope (exhaustive)
- `Palace/Book/Models/TPPBook+Extensions.swift:79 (sample)` ✓ in scope (HAS default)
- `Palace/CatalogUI/Views/CatalogView.swift:337` ✓ in scope (exhaustive)
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift:564 (didSelectRead)` ✓ in scope (HAS default — won't compile-error)
- `Palace/MyBooks/LocalBookContentService.swift:77` ✗ **NOT IN SCOPE, EXHAUSTIVE (compile-error class)**

`LocalBookContentService.swift:77` inspected:
```swift
switch book.defaultBookContentType {
case .epub, .pdf: ...
case .audiobook: ...
case .unsupported: ...
}
```

No default. Adding `.streamingHTML` WILL compile-error here.

**Verdict: FAIL — missed scope site.** Architect cites 6 but there are 7 TPPBookContentType switch sites in production code; LocalBookContentService.swift:77 is also exhaustive and missing from Contract C. Note: of the 6 sites the architect lists, only 3 are actually compile-error-class exhaustive (BookButtonState:67, TPPBook+Extensions.swift:63, CatalogView:337). The others (`BookCellModel:564`, `BookService:49`, `BookDetailViewModel:847`, `TPPBook+Extensions:79`) all have `default:` clauses — so adding `.streamingHTML` will compile, but route through the default branch. Plan.md item 5 calls out the same pattern for the converter; the architect should have applied the same scrutiny to all 7 sites and noted which need explicit cases vs which have `default:` fallbacks.

### 4. Both OPDS2 toBook filter sites

```
$ grep -n 'hasOpenablePath' Palace/OPDS2/Models/OPDS2PublicationExtended.swift
271:        let hasOpenablePath = acquisitions.contains { ...
278:        guard hasOpenablePath else { ...
387:        let hasOpenablePath = acquisitions.contains { ...
394:        guard hasOpenablePath else { ...
```

**Verdict: PASS-with-caveat.** Both sites exist. BUT — the filter is GENERIC: it checks `TPPOPDSAcquisitionPath.supportedTypes()`. By adding `ContentTypeStreamingHTML` to `supportedTypes()` and `supportedSubtypes(forType: ContentTypeOPDSPublication)` in Module A's PalaceCatalog edit, streaming-media-only acquisitions will AUTOMATICALLY pass `hasOpenablePath`. **No production-code edit to `OPDS2PublicationExtended.swift` is actually required for the filter behavior.** The plan.md item 6 says "Module A owns both" and Contract A lists both sites in `files_scope` — this is misleading. The tests at both sites are mandatory (Contract A test contracts #1 and #2 are right to assert both `toBook()` paths). Production code at OPDS2PublicationExtended.swift only needs test coverage, not edits.

Contract A should be re-worded: "Modified test coverage at both `toBook()` sites; no production-code edit needed — the filter unblocks automatically once Module A's `supportedTypes()` includes `ContentTypeStreamingHTML`."

### 5. BorrowReducer assertion

```
$ grep -n 'BookButtonType\|switch' Palace/Book/UI/BookDetail/BorrowReducer.swift
19:    var processingButtons: Set<BookButtonType> = []
107:    static let downloadRelatedButtons: Set<BookButtonType> = [
115:        switch action {           ← over BorrowAction, not BookButtonType
125:            switch registryState { ← over TPPBookState, not BookButtonType
```

**Verdict: PASS.** Architect's plan.md item 3 is correct: BorrowReducer switches BorrowAction + TPPBookState, never BookButtonType. Adding `.readStreaming` to BookButtonType will NOT compile-error here. `downloadRelatedButtons` is hand-maintained — `.readStreaming` correctly excluded (streaming = no download). Correctly listed in dont_touch.

### 6. Off-limits list completeness — files referencing the two types not in `files_scope` ∪ `dont_touch`

BookButtonType references in production that need scope-classification:
- All 9 files identified in #2 above
- NormalBookCell.swift NOT classified
- BorrowReducer.swift correctly classified as dont_touch
- Remaining 7 ARE in files_scope ✓

TPPBookContentType references:
- LocalBookContentService.swift NOT classified
- Other equality-check files (BackgroundDownloadHandler, DownloadStartDispatcher, DownloadThrottlingService, LCPFulfillmentHandler — all dont_touch by `MyBooks/Download*`, `MyBooks/Background*` glob); CatalogViewModel.swift (just one equality check, no switch); RecentlyReadingService.swift (one equality, no switch); Audiobooks/LCP/LCPAudiobooks.swift (equality only, dont_touch by Audiobooks/); PDF/LCP/LCPPDFs.swift (equality only); Samples/SamplePreviewManager.swift (rawValue only); Logging/TPPBook+Logging.swift (uses converter); DeviceSpecificErrorMonitor.swift (uses converter)
- Files in Palace/MyBooks/ not covered by Borrow*/Download*/BookReturn* glob: `LocalBookContentService.swift` (UNCLASSIFIED), `BookContentResetService.swift` (equality only), `RecentlyReadingService.swift` (equality only). LocalBookContentService is the one that breaks.

**Verdict: FAIL.** `Palace/MyBooks/LocalBookContentService.swift` and `Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift` are not in either `files_scope` or `dont_touch`. Once `.streamingHTML` and `.readStreaming` cases land, both will compile-error and the implementer will have to invent a fix mid-flight.

### 7. Verification-criteria greps — syntactically valid + failure-mode-relevant

Sampled greps from each contract:
- Contract A grep #2 `grep -c 'ContentTypeStreamingHTML' .../TPPOPDSAcquisitionPath.swift` ≥ 3 — would flag a partial supportedTypes addition. ✓
- Contract A grep #6 `grep -n 'streaming-media\|ContentTypeStreamingHTML' .../OPDS2PublicationExtended.swift` ≥ 1 — would PASS even without production edit (the existing comment at line 266 already matches "streaming-media"). Weak — doesn't actually verify the filter behavior. **Should be replaced with a test-result check.**
- Contract B grep #4 `grep -c 'UserDefaults' .../StreamingReaderViewModel.swift` == 0 — would correctly flag protocol-violation. ✓
- Contract B grep #6 force-unwrap regex — works in principle but pattern `![ ;)\.]` is fragile; would miss `foo!.bar` (the `.` excluded). Better: rely on SwiftLint's `force_unwrapping` rule which is already in verify-pr.sh.
- Contract C grep #2 — counts `.readStreaming` per file, expected ≥1 each. Would catch missing arms. ✓
- Contract C grep #3 — counts `.streamingHTML` in 6 files. Misses LocalBookContentService.swift.
- Contract D grep — relies on `~/harness/bin/harness simdrive validate-journey` which the architect themselves marks as "if the subcommand doesn't exist, use MCP". Should resolve before dispatch.

**Verdict: PASS-with-revisions.** Contract A grep #6 (OPDS2 filter) is structurally too weak. Contract B grep #6 (force unwrap regex) is brittle. Contract D verification subcommand existence unconfirmed.

### 8. Module C `critical_path` classification

Module C's actual touched files are display/routing layers (BookButtonState, BookButtonType, BookCellModel, BookDetailViewModel, BookDetailView, HalfSheetview, NavigationCoordinator). The borrow path itself (BorrowOperation, all Download* files, BookReturnService, BookSignInRedirectHandler, TokenRefreshInterceptor) is dont_touch.

**However**, the architect's plan.md item 8 says: "Minimal-surface approach: after a successful borrow for a streaming-HTML title, set the registry directly to `.downloadSuccessful`." That edit MUST land somewhere. Looking at all current `setState(.downloadSuccessful, ...)` callsites:
- `MyBooksDownloadCenter.swift:1042` — dont_touch (`MyBooks/Download*`... wait, MyBooksDownloadCenter is NOT in dont_touch glob; the glob is `MyBooks/Download*.swift` which matches `Download*.swift` at MyBooks/ level — `MyBooksDownloadCenter.swift` starts with "MyBooks", not "Download")
- `BackgroundDownloadHandler.swift:300, 347, 351` — dont_touch (`MyBooks/Background*` is NOT in dont_touch glob; `MyBooks/Download*` glob doesn't match `Background*` either)

Re-checking dont_touch: `Palace/MyBooks/Borrow*.swift`, `Palace/MyBooks/BookReturn*.swift`, `Palace/MyBooks/Download*.swift`. So `MyBooksDownloadCenter.swift` (Mass-prefix "MyBooks") and `BackgroundDownloadHandler.swift` (Mass-prefix "Background") are NOT in dont_touch.

But Contract C `files_scope` does NOT include either. So the actual location of the "set registry to .downloadSuccessful after streaming-HTML borrow" change is UNSPECIFIED. The architect lists this as the linchpin justification for critical_path — but then doesn't tell the implementer which file to edit.

The three resolution paths (in order of decreasing surface area):
- (a) Edit `MyBooksDownloadCenter.swift` to detect streaming-HTML books in `startDownload` and bypass to setState(.downloadSuccessful) immediately. Requires Contract C to add that file.
- (b) Edit `BookDetailViewModel.didSelectDownload` to detect streaming-HTML BEFORE calling downloadCenter and call setState directly. Already in scope, but the implementer wouldn't know they need this.
- (c) Skip the registry-state shortcut entirely. Modify `BookButtonState.buttonTypes` so streaming-HTML books map `.downloadNeeded` to `[.readStreaming, .return]` too. Removes the need for any state machine change. Simplest, lowest blast radius.

**Verdict: FAIL — architecture-spec gap.** Contract C says "After successful streaming-HTML borrow, set the registry directly to .downloadSuccessful" but doesn't specify the call site. Three reasonable implementations are possible; the implementer will pick one mid-flight without architect guidance, and the "set directly to .downloadSuccessful" claim in the commit message will not reconcile if option (c) is chosen.

**Critical_path classification itself is correct** (errs on the side of caution; touches MyBooks state-derived display) — not critical_path_meta.

### 9. Cross-module dependencies in `depends_on`

- A → []. ✓
- B → []. Confirmed: B only consumes `TPPBook` (existing) and optionally `ContentTypeStreamingHTML` (would import PalaceCatalog if used directly, but the contract says the consumer in C uses A's constant). ✓
- C → [A, B]. Confirmed: needs `.streamingHTML` TPPBookContentType case (A) and `StreamingReaderView` (B). ✓
- D → [C]. Confirmed: journey records against working production code. ✓

**Verdict: PASS.**

### 10. Strings + AccessibilityIdentifiers namespace coordination

```
$ grep -n 'struct BookButton\|struct BookDetailView' Palace/Utilities/Localization/Strings.swift
718:    struct BookDetailView {
759:    struct BookButton {
```
No existing `StreamingReader` namespace. Module B adds `Strings.StreamingReader.*`; Module C adds `Strings.BookButton.readStreaming` + `Strings.BookDetailView.streamingHTMLContentType`. Disjoint sub-namespaces.

```
$ grep -n 'enum BookDetail\|enum StreamingReader' Palace/Utilities/Testing/AccessibilityIdentifiers.swift
90:    public enum BookDetail {
```
No existing `StreamingReader` namespace. Module B adds `AccessibilityID.StreamingReader.*`; Module C adds `AccessibilityID.BookDetail.readStreamingButton` (inside existing BookDetail enum). Disjoint additions to different enums.

Wave plan: A+B parallel (wave 1), C after both (wave 2). Module B's Strings edits land first. Module C rebases on B's commits. Merge-conflict risk is low (different namespaces) but non-zero (same file).

**Verdict: PASS.** Namespace coordination is safe.

### 11. Test contracts pin SUT instantiation

Verified the verification-criteria blocks contain SUT-instantiation greps:
- Contract A grep #8: `grep -c 'OPDS2Publication(' PalaceTests/OPDS2/OPDS2PublicationExtendedTests.swift` ≥ 1 ✓
- Contract B grep #3: `grep -c 'StreamingReaderViewModel(' ...` ≥ 1 ✓; `grep -c 'StreamingReaderProgressStore(' ...` ≥ 1 ✓
- Contract C grep #6: three SUT greps for `BookButtonState.`, `BookCellModel(`, `BookDetailViewModel(`.

But the file paths are wrong:
- Contract C references `PalaceTests/MyBooks/BookCellModelTests.swift` — actual file is `PalaceTests/MyBooks/BookCellModelOfflineTests.swift`. No `BookCellModelTests.swift` exists.
- Contract C references `PalaceTests/ViewModels/BookDetailViewModelTests.swift` — actual file is `PalaceTests/Book/BookDetailViewModelTests.swift`.
- Contract C references `PalaceTests/Book/BookButtonMapperTests.swift` — that file exists but defines `BookButtonMapperExtendedTests`, NOT `BookButtonMapperTests`. The actual `BookButtonMapperTests` class is in `PalaceTests/BookStateManagement/BookButtonMapperTests.swift`. The verification-criteria greps will technically pass against the Extended file (which references BookButtonState too) but the implementer needs to know whether to add streaming-HTML tests to the Extended file or the canonical one.

**Verdict: FAIL — wrong test paths.** Three Contract C test-path references are incorrect. The implementer will create new files at the wrong locations OR look for files that don't exist and ad-hoc rename.

## Findings (BLOCKING)

1. **NormalBookCell.swift:218 missing from Contract C `files_scope`.** Exhaustive switch over BookButtonType; adding `.readStreaming` will compile-error here. **Fix:** add `Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift` to Module C scope; bump scope count from 8 to 9 (or 10 if you also re-count BookButtonType.swift internal switches as 5 instead of 4).

2. **LocalBookContentService.swift:77 missing from Contract C `files_scope`.** Exhaustive switch over `defaultBookContentType`; adding `.streamingHTML` will compile-error here. **Fix:** add `Palace/MyBooks/LocalBookContentService.swift` to Module C scope; bump TPPBookContentType switch-site count from 6 to 7. The streamingHTML case here is "no-op" (no local content to delete for a streaming title), so a `case .streamingHTML: break` arm with an explanatory comment is the minimal correct edit.

3. **Linchpin "set registry to .downloadSuccessful after streaming-HTML borrow" call site is unspecified.** Contract C's `files_scope` does NOT include any file where the post-borrow registry state-setting actually happens. Three resolution paths exist; the implementer should not be left to invent the architecture. **Fix:** the architect must pick one approach and add the relevant file to `files_scope` OR rewrite the approach to option (c) (modify BookButtonState's `.downloadNeeded` branch to also yield `.readStreaming` for streamingHTML books — purely presentation-layer, zero registry-state-machine change, lowest blast radius). Option (c) is cleaner and would let Module C honestly stay out of MyBooks state-machine territory, possibly downgrading from critical_path to standard. Recommendation: rewrite as option (c).

4. **Wrong test file paths in Contract C verification block.** Three test paths cited don't exist or don't contain the named test class. **Fix:**
   - Replace `PalaceTests/MyBooks/BookCellModelTests.swift` with `PalaceTests/MyBooks/BookCellModelOfflineTests.swift` (modify) OR `PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift` (new).
   - Replace `PalaceTests/ViewModels/BookDetailViewModelTests.swift` with `PalaceTests/Book/BookDetailViewModelTests.swift`.
   - Disambiguate `PalaceTests/Book/BookButtonMapperTests.swift` (Extended class) vs `PalaceTests/BookStateManagement/BookButtonMapperTests.swift` (canonical class). Pick one location for streaming-HTML cases and update the verification grep.

5. **Internal arithmetic inconsistency: BookButtonType internal switch count.** plan.md §Risks #2 says 4; Contract C verification grep #2 says "≥5 (case + 4 internal switches)"; Contract C `files_scope` text lists 5 by name. Actual count is 5. **Fix:** standardize on 5 across plan.md, Contract C summary, and Contract C grep expectation ("≥6: case + 5 switches").

## Findings (non-blocking advisories)

A. **Contract A grep #6 too weak.** `grep -n 'streaming-media\|ContentTypeStreamingHTML' Palace/OPDS2/Models/OPDS2PublicationExtended.swift ≥ 1` will pass on the existing comment line 266 even without any production fix. Replace with a test-result assertion (the new `testOPDS2Publication_toBook_streamingMediaOnlyAcquisition_doesNotDrop` test passing IS the verification).

B. **Contract A `files_scope` over-claims OPDS2PublicationExtended.swift production edits.** The filter is generic; once `supportedTypes()` includes `ContentTypeStreamingHTML`, the filter unblocks automatically. Re-word `files_scope` to say "test-only modification of OPDS2PublicationExtended.swift coverage; production-code edits at the toBook sites are not strictly required".

C. **Contract C grep #3 should be 7, not 6.** Add LocalBookContentService.swift to the loop.

D. **Contract D `validate-journey` subcommand existence unconfirmed.** The architect notes the fallback to MCP `validate_replay` but the implementer should not need to discover this. Pre-flight: confirm whether `~/harness/bin/harness simdrive validate-journey` exists; if not, the contract's verification grep should call the MCP tool directly.

## Manifest update

Suggest writing this block into `manifest.yaml`:

```yaml
architect_review:
  reviewer_agent_id: general-purpose
  verdict: BLOCKED
  at: 2026-06-03T00:00:00Z
  reviewed_files:
    - .forgeos/swarms/swarm_c2b95c85/plan.md
    - .forgeos/swarms/swarm_c2b95c85/contracts/A-Format-Recognition.md
    - .forgeos/swarms/swarm_c2b95c85/contracts/B-StreamingReader.md
    - .forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md
    - .forgeos/swarms/swarm_c2b95c85/contracts/D-Simdrive-Journey.md
    - .forgeos/intent/pp-4161-streaming-html-reader.md
  findings:
    blocking:
      - id: F1
        title: "NormalBookCell.swift:218 missing from Contract C files_scope (exhaustive BookButtonType switch)"
        file: Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift
        fix: "Add to Module C files_scope; bump BookButtonType switch-site count from 8 to 9"
      - id: F2
        title: "LocalBookContentService.swift:77 missing from Contract C files_scope (exhaustive TPPBookContentType switch)"
        file: Palace/MyBooks/LocalBookContentService.swift
        fix: "Add to Module C files_scope; bump TPPBookContentType switch-site count from 6 to 7; minimal edit is `case .streamingHTML: break` with comment"
      - id: F3
        title: "Linchpin 'set registry to .downloadSuccessful after streaming-HTML borrow' call site unspecified"
        file: null
        fix: "Either name the borrow-completion file to edit OR rewrite approach as option (c): BookButtonState maps .downloadNeeded to [.readStreaming, .return] for streamingHTML books (purely presentation, no state-machine change). Option (c) recommended."
      - id: F4
        title: "Three wrong test paths in Contract C verification block"
        file: null
        fix: "Fix BookCellModelTests.swift, BookDetailViewModelTests.swift, BookButtonMapperTests.swift path references; disambiguate Extended vs canonical class location"
      - id: F5
        title: "Internal arithmetic inconsistency: BookButtonType internal switch count (4 vs 5)"
        file: null
        fix: "Standardize on 5 across plan.md, Contract C summary, and Contract C verification grep"
    advisory:
      - "Contract A grep #6 (streaming-media presence in OPDS2PublicationExtended.swift) is too weak — passes on the existing comment alone"
      - "Contract A files_scope over-claims OPDS2PublicationExtended.swift production edits — filter is generic, unblocks automatically"
      - "Contract C grep #3 should iterate 7 files, not 6 (add LocalBookContentService.swift)"
      - "Contract D validate-journey subcommand existence unconfirmed; pre-flight or rewrite to MCP call"
  re_review_required: true
```

## Decision rationale

Five blocking findings, three of which are real spec gaps that would force implementer mid-flight invention (F1 NormalBookCell, F2 LocalBookContentService, F3 registry shortcut). Two are spec hygiene (F4 test paths, F5 internal count). The advisory items are quality-of-life and should be folded into the v2 contract.

If the architect rewrites Module C to use option (c) for F3 (BookButtonState presentation-only mapping with no state-machine change), Module C's `critical_path` classification can stay (still touches MyBooks display logic) and the contract becomes meaningfully smaller AND honest. That's the recommended path.

Re-emit Contracts A and C with the fixes above, then re-review for APPROVE.
