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

## Round 2 verification

**Reviewer:** general-purpose (Phase 1a round 2)
**At:** 2026-06-03T14:39:00Z
**Verdict:** APPROVED with two new advisories (E + F)

### Per-finding verification

**F1 — NormalBookCell.swift in Contract C `files_scope`:** PASS.
```
$ grep -c 'NormalBookCell.swift' .forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md
4
$ grep -c 'NormalBookCell' .forgeos/swarms/swarm_c2b95c85/manifest.yaml
3
```
Contract C `files_scope` line `Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift (exhaustive switch at :218 — add .readStreaming to the model.callDelegate(for: type) arm) [ADDED v2 per F1]` is present. Verification grep #2 enumerates `NormalBookCell.swift` with expected `≥ 1`. Manifest `fix_applied` annotation matches.

**F2 — LocalBookContentService.swift in Contract C `files_scope`:** PASS.
```
$ grep -c 'LocalBookContentService.swift' .forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md
4
$ grep -c 'LocalBookContentService' .forgeos/swarms/swarm_c2b95c85/manifest.yaml
5
```
Contract C `files_scope` line `Palace/MyBooks/LocalBookContentService.swift (:77 switch — case .streamingHTML: break with comment "streaming-HTML has no local on-device asset") [ADDED v2 per F2]` present. Verification grep #3 now iterates 7 files (includes LocalBookContentService.swift). Confirmed `.deleteLocalContent` semantics is correct — no on-device asset for streaming-HTML, so `break` is the right arm.

**F3 — Option (c) adopted, no registry-state shortcut:** PASS.
```
$ grep -c 'Option (c)' .forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md
4
$ grep -c 'set registry directly to .downloadSuccessful' .forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md
0
```
Implementation guidance is `.downloadNeeded` → `[.readStreaming, .return]` mapping for streamingHTML — pure presentation. dont_touch additions confirmed:
```
$ grep 'MyBooksDownloadCenter\|Background\*' .forgeos/swarms/swarm_c2b95c85/manifest.yaml
... implementer_prompt_summary mentions both ...
  - Palace/MyBooks/Background*.swift                       # v2 — Option (c) excludes Background* edits
  - Palace/MyBooks/MyBooksDownloadCenter.swift             # v2 — Option (c) excludes MyBooksDownloadCenter edits
```
Both new dont_touch entries present.

**F4 — Wrong test paths corrected:** PASS.
```
$ grep -c 'PalaceTests/BookStateManagement/BookButtonMapperTests.swift' .forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md
4
$ grep -c 'PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift' .forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md
3
$ grep -c 'PalaceTests/Book/BookDetailViewModelTests.swift' .forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md
3
$ grep -c 'PalaceTests/ViewModels/BookDetailViewModelTests' .forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md
0
```
Existence confirmed:
```
$ ls PalaceTests/BookStateManagement/BookButtonMapperTests.swift     # exists
$ ls PalaceTests/Book/BookDetailViewModelTests.swift                  # exists
$ ls -d PalaceTests/MyBooks/                                          # directory exists; BookCellModelStreamingHTMLTests.swift is NEW (sibling of BookCellModelOfflineTests.swift)
```
`-only-testing` selectors at verification #11 correctly reference the canonical classes.

**F5 — BookButtonType internal switch count standardized at 5:** PASS.
```
$ grep -c '5 internal switches' .forgeos/swarms/swarm_c2b95c85/plan.md
1
$ grep -c '≥ 6' .forgeos/swarms/swarm_c2b95c85/contracts/C-BookButton-Presenter-Wiring.md
1
```
plan.md §Risks #2 reads "5 internal switches in BookButtonType.swift itself"; Contract C verification grep #2 expects `BookButtonType.swift ≥ 6 (case + 5 internal switches)`. Consistent across plan, contract `files_scope` text, and verification expectation.

**Advisory A — Contract A grep #6 replaced with test-pass assertion:** PASS.
```
$ grep -c 'testOPDS2Publication_toBook_streamingMediaOnlyAcquisition_doesNotDrop' .forgeos/swarms/swarm_c2b95c85/contracts/A-Format-Recognition.md
2
```
Test-pass assertion is now the verification, not the brittle comment-line grep.

**Advisory B — Contract A flags test-coverage-only on OPDS2PublicationExtended.swift:** PASS.
```
$ grep -c 'test-coverage only' .forgeos/swarms/swarm_c2b95c85/contracts/A-Format-Recognition.md
1
```
Filter behavior unblocks automatically once `supportedTypes()` lists ContentTypeStreamingHTML; no production-code edit needed at the two toBook sites.

**Advisory C — Contract C grep #3 iterates 7 files:** PASS.
Grep #3's `for f in ...` loop enumerates `BookCellModel.swift`, `BookButtonState.swift`, `LocalBookContentService.swift`, `BookService.swift`, `BookDetailViewModel.swift`, `TPPBook+Extensions.swift`, `CatalogView.swift` — exactly 7 files. Each expected `≥ 1`.

**Advisory D — Contract D uses MCP, not the non-existent harness subcommand:** PASS.
```
$ grep -c 'mcp__simdrive__validate_replay\|mcp__simdrive__replay' .forgeos/swarms/swarm_c2b95c85/contracts/D-Simdrive-Journey.md
2
$ grep -c 'harness simdrive validate-journey' .forgeos/swarms/swarm_c2b95c85/contracts/D-Simdrive-Journey.md
1
```
The single remaining `harness simdrive validate-journey` hit is in an EXPLANATORY comment ("does NOT exist; use the MCP validate_replay instead"), not in a command-to-run block. Acceptable — fix is correctly recorded for the reader.

### Check 1 — critical_path classification under v2

Module C still touches MyBooks display logic that gates user access (BookButtonState chooses the buttons the user sees). A bug here (e.g., streamingHTML book maps to empty button set, or to `[.download]` instead of `[.readStreaming]`) gates a user from opening their borrowed content. `critical_path` classification is **defensible and recommended-keep**. Mutation kill-rate ≥80% diff-scoped is correct rigor.

### Check 2 — does the v2 BookButtonState change compile?

Inspected `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift` (current HEAD):
- `.downloadNeeded` branch (lines 59-65) is a **flat `if/else`** over `currentUserAccount.authDefinition`, NOT a switch over `defaultBookContentType`. Contract C says "extend the inner switch" — there is NO inner switch to extend. The implementer must **introduce** a new switch over `book.defaultBookContentType` inside the `.downloadNeeded` arm.
- `.downloadSuccessful, .used` branch (lines 67-74) IS a real switch over `defaultBookContentType` with cases `.audiobook`, `.pdf/.epub`, `.unsupported`. Once Module A lands `.streamingHTML`, this switch becomes non-exhaustive and breaks. Contract C correctly says the implementer adds `case .streamingHTML: buttons.append(.readStreaming)` here.

This is **not blocking** — the implementer will figure out from the existing code that they need to introduce a new switch in `.downloadNeeded`. But the contract wording ("extend the inner switch") is misleading; it should say "introduce an inner switch over `defaultBookContentType` inside the `.downloadNeeded` arm so streamingHTML maps to `[.readStreaming, .return]` while all other content types preserve the existing `[.download, .return]` / `[.download, .remove]` behavior." Filed below as advisory **E**.

### Check 3 — sibling consumers of .downloadNeeded that auto-trigger download

Surveyed all `.downloadNeeded` references in `Palace/MyBooks/` and `Palace/Book/UI/BookDetail/`. Critical finding:

`Palace/MyBooks/BorrowOperation.swift:453`:
```swift
// F-014: ... fire startDownload whenever the borrow lands on .downloadNeeded
if attemptDownload && mapping.state == .downloadNeeded {
    await MainActor.run { [weak self] in
        self?.delegate?.startDownload(for: borrowedBook, withRequest: nil)
    }
}
```

And `Palace/MyBooks/DownloadStartDispatcher.swift:248`:
```swift
if state == .downloadNeeded && currentBook.defaultAcquisitionIfBorrow != nil {
    // ... auto-borrow with attemptDownload: true ...
}
```

Trace for streaming-HTML book:
1. User taps `.get` (from `.canBorrow` state) → `BookDetailViewModel.handleAction(.get)` → `didSelectDownload` → `downloadCenter.startDownload(for:)`.
2. `DownloadStartDispatcher` sees `.downloadNeeded` + has borrow acquisition → calls `startBorrow(attemptDownload: true)`.
3. Borrow succeeds → registry → `.downloadNeeded`.
4. `BorrowOperation:453` triggers `startDownload` again → enters fulfillment for a streaming-media MIME asset.

Module C's Option (c) is a presentation-layer fix that **does NOT prevent the production auto-download chain from firing for streaming-HTML books**. Whether the fulfilled `startDownload` for a streaming-media MIME no-ops gracefully, fails silently, or leaves a stray local file is currently UNTESTED. The contract puts `Borrow*` and `Download*` and `MyBooksDownloadCenter` in `dont_touch` — so the implementer cannot patch this even if they discover a regression mid-flight.

This is the **most material new finding** in round 2. Filed as advisory **F** below. Severity: advisory (not blocking), because:
- (i) The behavior of `startDownload` for a streaming-media MIME might be a benign no-op (`DownloadStartCoordinator.processWithCredentials` might log warn + return without persisting an asset; needs verification).
- (ii) The simdrive journey in Module D will catch a user-visible regression (e.g., spinning download progress + downloadFailed banner) but it is run at the end of the wave, not as a Module C gate.
- (iii) The "right" architectural fix is a one-line guard at `BorrowOperation:453` (`&& mapping.book.defaultBookContentType != .streamingHTML`) or at `DownloadStartDispatcher:248`. Both are in dont_touch.

Recommendation: surface explicitly in plan.md §Risks as item #10. EITHER (a) extend Module C scope to include a single-line guard at one of those two sites with explicit test coverage proving the auto-download is skipped for streamingHTML, OR (b) add a Module C test that drives the full `.get → borrow → post-borrow state` chain for a streamingHTML book and asserts `bookRegistry.state` is `.downloadNeeded` (not stuck `.downloading` or `.downloadFailed`) after a 5-second timeout — proving the auto-download chain no-ops harmlessly. Approach (b) keeps Option (c)'s anti-scope discipline intact; approach (a) buys correctness with a tiny scope exception.

### Check 4 — Module B compile-time dependency on A

Inspected Contract B's `What public types/protocols` block: `StreamingReaderViewController.init(book: TPPBook, ...)`, `StreamingReaderViewModel.init(book: TPPBook, ...)`. **TPPBook only** — no reference to `.streamingHTML` or `ContentTypeStreamingHTML`. Module B has no compile-time dependency on Module A. Wave 1 parallel dispatch (A + B) is safe.

### New issues (advisory)

**E. Contract C BookButtonState change wording — "extend the inner switch" is misleading because there is no existing switch in `.downloadNeeded`.** The implementer must INTRODUCE a new switch over `defaultBookContentType` inside the `.downloadNeeded` arm, while extending the existing switch in `.downloadSuccessful, .used`. Severity: advisory. Fix: re-word the Contract C `files_scope` entry for BookButtonState.swift to "Introduce a switch over `book.defaultBookContentType` inside the `.downloadNeeded` branch returning `[.readStreaming, .return]` for `.streamingHTML` and preserving the existing `[.download, .return]` / `[.download, .remove]` behavior for all other cases; extend the existing inner switch in `.downloadSuccessful, .used` to add `case .streamingHTML: buttons.append(.readStreaming)`."

**F. Production auto-download chain (BorrowOperation:453 + DownloadStartDispatcher:248) still fires for streaming-HTML books under Option (c).** Module C scope is presentation-only, so it cannot patch the chain. Without explicit test coverage proving graceful no-op, regression risk is real (user taps Get → spurious downloadFailed banner / stuck downloading state / phantom local file). Severity: advisory (not blocking) because the implementer can address with a Module C test (approach (b)) that proves the chain no-ops harmlessly OR escalate via scope-deferral protocol with a one-line guard exception (approach (a)). Plan.md §Risks should add this as item #10 with the two recommended approaches documented so the implementer doesn't discover it mid-flight.

**G. Stale acceptance gates in manifest.yaml.** Lines 112-113 still reference "8 switch sites" and "6 production files":
```
- "Module C: BookButtonType has case .readStreaming; grep -c 'case .readStreaming' across the 8 switch sites returns 8+"
- "Module C: TPPBookContentType switches updated in 6 production files; none introduces a new default: clause"
```
Both numbers should be bumped to 9 and 7 respectively per F1+F2. Severity: advisory (cosmetic; the per-finding `fix_applied` annotations correctly say 9 and 7).

**H. Stale acceptance gate #116.** `"Module C: contract-snapshot test pins borrow → registry.setState(.downloadSuccessful) → present StreamingReaderView call order"` — this references the round-1 registry-state shortcut that Option (c) explicitly removed. The actual contract test #8 pins `handleAction(.readStreaming) → processingButtons.insert(.readStreaming) → coordinator.presentStreamingReader(book:)`. Severity: advisory. Fix: re-word the acceptance gate to match the v2 contract test #8 description.

### Final verdict

**APPROVED** with advisories E + F + G + H. Orchestrator may proceed to Phase 2 (ForgeOS changeset propose) + Phase 3 (dispatch implementers).

The five blocking findings (F1–F5) from round 1 are cleanly resolved in v2. The four round-1 advisories (A–D) are correctly applied. The v2 rewrite to Option (c) is a meaningful improvement — Module C is now genuinely smaller and the contract is honest about its scope.

The two new findings introduced by the v2 scope-narrowing are advisories, not blockers:
- E (wording) is a contract-doc fix the implementer can navigate around.
- F (auto-download chain) needs ONE of two responses: a Module C test demonstrating graceful no-op OR an explicit scope exception. Recommend the orchestrator add plan.md §Risks #10 documenting both approaches so the implementer addresses it consciously rather than discovering it mid-PR.
- G + H are stale-text cleanup in the manifest acceptance_gates; non-blocking but should be cleaned before release.

Module-A + Module-B parallel wave dispatch is safe. Module-C critical_path classification stays. Mutation kill-rate ≥80% diff-scoped on BookButtonState + BookButtonType + BookCellModel remains the right rigor bar.

