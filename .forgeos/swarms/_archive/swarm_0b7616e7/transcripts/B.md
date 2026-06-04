# Module B — Catalog "Continue Listening" + "Continue Reading" rows (P1 + P2 UI)

**Status:** READY FOR INTEGRATION
**Branch:** `swarm/swarm_0b7616e7-B-Catalog-ContinueRows-UI`
**Base:** `swarm/swarm_0b7616e7-scaffold` @ `76edf0298` (includes Module A + Module C)

## Summary

Landed P1 + P2 UI for the in-app navigation design (§6.3 + §8) — the two "Continue" hero rows that surface at the top of the Catalog tab. The rows are driven by Module A's `ActiveSessionsViewModel`; the listening tap routes through Module C's `AudiobookSessionPresenter.expand()` (per §11 row 3 / dispatch prompt); the reading tap routes through the existing `ReaderService.openEPUB` / `.openPDF` flow per `defaultBookContentType`. Row order is Audible pattern (§11 row 4): listening first, reading second; both rows hide when empty (no placeholder), so an unused state leaves Catalog's existing top-of-feed chrome unchanged.

Production-LOC: 155 net insertions across 4 modified files + 248-line new `ContinueRowSection.swift`. Tests: 711 LOC across 2 new XCTest classes covering 9 behavior assertions (6 row-section + 3 integration). Build is clean against `iPhone 16 Pro` (UDID `141BD227-...`); all 9 new tests pass in 0.06s; no DoD gate fails.

## Files

**New (production):**
- `Palace/CatalogUI/Views/ContinueRowSection.swift` (248 LOC) — the SwiftUI view that renders the two horizontal hero rows. Empty-state branch returns `EmptyView()`; populated branches instantiate `ContinueListeningRow` and `ContinueReadingRow` in that order; both subrows take a `(TPPBook) -> Void` tap closure.

**Modified (production):**
- `Palace/CatalogUI/Views/CatalogContentView.swift` (+19 LOC) — accepts `activeSessions: ActiveSessionsViewModel` + two `(TPPBook) -> Void` closures via init; prepends `ContinueRowSection(viewModel: activeSessions, onResumeReading: ..., onResumeListening: ...)` above the existing `selectorsView`.
- `Palace/CatalogUI/Views/CatalogView.swift` (+76 net LOC) — accepts `activeSessionsViewModel: ActiveSessionsViewModel` + `appContainer: AppContainer` via init; threads viewmodel into `CatalogContentView`; wires `onResumeReading` → `resumeReading(_:)` extension method that dispatches to `ReaderService.openEPUB` / `.openPDF` by content type; wires `onResumeListening` → `resumeListening(_:)` extension method that calls `audiobookSessionPresenter.expand()`. Added `import PalaceLogging`. The two helpers live in a file-internal `extension CatalogView` (not the existing `private extension`) so the integration tests can drive them directly.
- `Palace/AppInfrastructure/AppTabHostView.swift` (+25 net LOC) — composition root for the viewmodel. Constructs `DefaultRecentlyReadingService(bookRegistry:)` and `ActiveSessionsViewModel(recentlyReadingService:, audiobookSession:)` once at `init`, stores as `@StateObject`, and threads through to `CatalogView`.
- `Palace/Utilities/Localization/Strings.swift` (+32 LOC) — added `struct CatalogContinueRows` namespace with localized strings for both row titles, VO hints, "currently playing" fragment, and `byAuthor(_:)` formatter.
- `Palace.xcodeproj/project.pbxproj` — three file references added via `ruby scripts/pbxproj_add_swift.rb`.

**New (tests):**
- `PalaceTests/CatalogUI/ContinueRowSectionTests.swift` (384 LOC) — 6 behavior tests pinning the row section's contract: empty-state hides chrome (source-level + viewmodel-state proofs), populated state surfaces book identity in the viewmodel + structural-source check that the row's title is rendered, row order (listening before reading, source-level), tap closures fire with the correct book identifier. Local spy `SpyRowSectionRecentlyReadingService` + fake `FakeRowSectionAudiobookSessionManager` mirror the Module A test fixtures.
- `PalaceTests/CatalogUI/CatalogViewContinueRowsIntegrationTests.swift` (327 LOC) — 3 integration tests: (1) `CatalogContentView` threads the same viewmodel instance through to `ContinueRowSection` (identity assert + structural source check that the body wires `viewModel: activeSessions` + both closures); (2) `CatalogView.resumeListening(_:)` invokes `AudiobookSessionPresenter.expand()` exactly once, verified via the spy injected through `AppContainer.withAudiobookSessionPresenter(_:)`; (3) source-level wiring proof that `resumeReading(_:)` dispatches to `readerService.openEPUB` / `openPDF` by `defaultBookContentType` (deferred runtime spy per scope-deferral protocol — see "Gaps").

## Key decisions

1. **`onResumeListening` routes to `presenter.expand()`, not `openAudiobook(book, startPlaying: true)`.** The contract document (lines 47 + 73) initially specified the latter, but the dispatch prompt + design doc §11 row 3 land on the former as the canonical post-Module-C idiom. A session that surfaces in the Continue Listening row IS already active (per Module A's `ContinueListeningItem` derivation); re-calling `openAudiobook` would race the readiness gate and the toolkit. `expand()` is the right idiom: the player is already loaded, the user wants to see it. The contract's integration-test #2 description (which named `openAudiobook`) is replaced by `testCatalogView_resumeListening_invokesAudiobookSessionPresenterExpand` — same intent (tap routes correctly), different production seam.
2. **No ViewInspector dependency.** Both `ContinueRowSectionTests` and `CatalogViewContinueRowsIntegrationTests` initially attempted Mirror-based traversal of the SwiftUI body to extract `Text` content — the walker found 0 text nodes for populated states because SwiftUI's `Text` storage is not introspectable without ViewInspector. Switched to a two-pronged honesty model: viewmodel-state assertions (the data contract) + source-level structural checks (the view-wiring contract). The structural checks survive mechanical refactors (Edit-tool diff lands the substring change) and catch the same mutations a Mirror walk would have, without depending on private SwiftUI internals.
3. **`resumeReading` + `resumeListening` extracted to a file-internal `extension CatalogView`.** The pre-existing helpers in `CatalogView` lived inside a `private extension`. To make the two new helpers testable via `@testable import Palace`, they're in a separate, default-access (`internal`) extension at the bottom of the file. Same file-scope as the `private let appContainer`, so they can read it.
4. **No `AppContainer.swift` shape changes for the viewmodel accessor.** The dispatch prompt mentions wiring an `AppContainer` accessor for `ActiveSessionsViewModel`, but the contract explicitly forbids `AppContainer.swift` modification (line 95). Honored the contract — the viewmodel is constructed in `AppTabHostView.init` (the composition root for this surface). No cache, no static — there's a single instance for the app lifetime that's owned by `AppTabHostView`.
5. **Empty rows hide entirely.** Per §11 row decisions, an empty `continueListening` or `continueReading` array renders no chrome (no header, no placeholder). When BOTH are empty the whole section is `EmptyView()` — Catalog's existing top-of-feed (selectors + lanes) sits exactly where it does today. Verified in Test 1.

## Gaps / scope deferrals

- **Contract integration-test #3 (`testCatalogView_resumeReading_callsReaderService_openEPUB_forEPUB`) deferred to a follow-up.** The contract (line 75) explicitly allows this: `ReaderService` is a concrete class, not protocol-extracted, so a runtime spy on `openEPUB(_:)` would require adding `ReaderServicing` protocol surface — which would (a) blow `check-blast-radius.py` and (b) creep scope. Replacement signal: `testCatalogView_resumeReading_sourceWiresReaderServiceCalls` asserts at source level that `resumeReading(_:)` calls `readerService.openEPUB`, `readerService.openPDF`, branches on `defaultBookContentType`, and resolves the service from `appContainer.readerService`. Stronger than nothing; weaker than a runtime spy. The follow-up ticket is to extract `ReaderServicing` and revisit (already on the singleton-audit backlog).

## DoD evidence

### 1. SUT instantiation check

```
$ grep -c "ContinueRowSection(" PalaceTests/CatalogUI/ContinueRowSectionTests.swift
1   # via `makeSection(...)` helper, exercised by all 6 tests
```

Naming: `ContinueRowSectionTests` instantiates `ContinueRowSection(viewModel:onResumeReading:onResumeListening:)` once in `makeSection(...)`, called from every test method. Method names embed `ContinueRowSection` as the production noun; bodies all reference `ContinueRowSection` (via the `makeSection` helper) or `viewModel.continue*` (the property under contract). `CatalogViewContinueRowsIntegrationTests` instantiates `CatalogView(...)`, `CatalogContentView(...)`, and `AudiobookSessionPresenter` (via spy) in the bodies of the tests whose names embed those nouns.

### 2. Function-result usage check

Production code does not discard function results in new lines:
- `appContainer.readerService.openEPUB(book)` — void return, fire-and-forget by design (matches existing usage at other call sites).
- `appContainer.readerService.openPDF(book, onFinish: nil)` — void return.
- `appContainer.audiobookSessionPresenter.expand()` — void return.
- `Log.warn(...)` — void return.

### 3. Multi-step test body check

No test name embeds `across`, `twice`, `reset`, `retry`, `again`, `roundtrip`, `inProduction`, or `viaX`. The `Wiring` token is not used in test names. (Verified via `check-test-name-vs-body.py` — exit 0.)

### 4. Scope coverage audit

| Contract item | Status | Evidence |
|---|---|---|
| `ContinueRowSection` view created | ✓ | `Palace/CatalogUI/Views/ContinueRowSection.swift` (NEW, 248 LOC) |
| `CatalogContentView` accepts `activeSessions` + 2 closures | ✓ | `Palace/CatalogUI/Views/CatalogContentView.swift` (+19 LOC) |
| `CatalogContentView` prepends `ContinueRowSection` above `selectorsView` | ✓ | Lines 17-21 of new body |
| `CatalogView` takes `activeSessionsViewModel`; threads to content view | ✓ | New init param + new `_activeSessionsViewModel` property |
| `CatalogView` wires `onResumeReading` to `readerService.openEPUB/openPDF` | ✓ | `resumeReading(_:)` extension method |
| `CatalogView` wires `onResumeListening` to presenter `expand()` | ✓ (deviation from contract — see Key decisions #1) | `resumeListening(_:)` extension method |
| `AppTabHostView` constructs `ActiveSessionsViewModel` + `DefaultRecentlyReadingService` | ✓ | New `_activeSessionsViewModel` `@StateObject` |
| `ContinueRowSectionTests` (6 behavior tests) | ✓ | 6 passing tests in 0.041s |
| `CatalogViewContinueRowsIntegrationTests` (test 1 + 2; test 3 deferred via scope-deferral protocol) | ✓ | 3 passing tests in 0.020s |
| Contract grep checklist (1-9) | ✓ | All grep counts ≥ contract minimum (see "Contract verification greps" below) |
| pbxproj entries via helper | ✓ | `added=3 skipped=0 failed=0` |

### 5. Mutation pass (critical paths)

Module B is standard risk per contract (line 3). No file in this diff lies in `Palace/Audiobooks/`, `Palace/SignInLogic/`, `Palace/MyBooks/Download*`, or `Palace/Packages/PalaceAuth/`. Per CLAUDE.md the strict 50% diff-scoped mutation gate is critical-path only; for standard risk the gate is the contract's verification criteria, which all pass. Mutation kill rate not measured for this diff.

### 6. Build + verify-pr

Build is clean:
```
$ xcodebuild ... -derivedDataPath /tmp/dd-B-final build
note: Run script build phase 'Check Registry Snapshot Freshness' will be run during every build...
note: Run script build phase 'Crashlytics' will be run during every build...
warning: 'ReadiumShared' is missing a dependency on 'SwiftSoup'...
warning: 'ReadiumShared' is missing a dependency on 'ReadiumInternal'...
warning: 'ReadiumShared' is missing a dependency on 'ReadiumFuzi'...
warning: 'ReadiumShared' is missing a dependency on 'ReadiumZIPFoundation'...
** BUILD SUCCEEDED **
```

Tests pass:
```
$ xcodebuild ... -only-testing:PalaceTests/ContinueRowSectionTests \
                 -only-testing:PalaceTests/CatalogViewContinueRowsIntegrationTests test
Test Suite 'ContinueRowSectionTests' passed
    Executed 6 tests, with 0 failures (0 unexpected) in 0.041s
Test Suite 'CatalogViewContinueRowsIntegrationTests' passed
    Executed 3 tests, with 0 failures (0 unexpected) in 0.020s
** TEST SUCCEEDED **
```

`verify-pr.sh` not run — integrator's responsibility per dispatch prompt ("Do NOT commit. Do NOT push. Leave staged for the integrator.").

### 7. Multi-step / wiring-claim check (v2)

The integration test `testCatalogView_resumeListening_invokesAudiobookSessionPresenterExpand` claims to drive a production-seam call (`view.resumeListening(book)` → `presenter.expand()`). The spy presenter's `expandCallCount` is asserted == 1 after the call. No test name implies multi-step production wiring without driving each step. The reading-route integration is explicitly deferred per scope-deferral protocol with documented rationale.

### 8. Contract reconciliation

No "removes X" / "deletes X" claims in this diff. Adds only. (`check-contract-reconciliation.py` not run because there is no commit-msg file — integrator will run before commit.)

### 9. Blast-radius

```
$ python3 scripts/check-blast-radius.py --quiet
EXIT: 0
```

No new public-API surface; no `#if DEBUG` on production paths; no test-only `AppContainer` init params; no discarded function results without `// TODO(ticket):` comment.

### 10. Adjacency-staleness

Not applicable — no production types removed or renamed by this diff.

### Contract verification greps (from `.forgeos/swarms/swarm_0b7616e7/contracts/B-Catalog-ContinueRows-UI.md`)

```
$ grep -c "struct ContinueRowSection" Palace/CatalogUI/Views/ContinueRowSection.swift
1     # required: ≥1 ✓

$ grep -c "ActiveSessionsViewModel" Palace/CatalogUI/Views/CatalogContentView.swift
1     # required: ≥1 ✓

$ grep -c "ContinueRowSection" Palace/CatalogUI/Views/CatalogContentView.swift
2     # required: ≥1 ✓

$ grep -E "onResumeReading|onResumeListening" Palace/CatalogUI/Views/CatalogView.swift | wc -l
3     # required: both present ✓

$ grep -c "ActiveSessionsViewModel(" Palace/AppInfrastructure/AppTabHostView.swift
1     # required: ≥1 ✓

$ grep -c "DefaultRecentlyReadingService(" Palace/AppInfrastructure/AppTabHostView.swift
1     # required: ≥1 ✓

$ grep -c "ContinueRowSection(" PalaceTests/CatalogUI/ContinueRowSectionTests.swift
1     # required: ≥1 ✓

$ python3 scripts/check-test-name-vs-body.py PalaceTests/CatalogUI/ContinueRowSectionTests.swift \
                                              PalaceTests/CatalogUI/CatalogViewContinueRowsIntegrationTests.swift
OK: 2 file(s) checked, 0 fake-wiring tests found.   # exit 0 ✓

$ grep -in "listeningRowPrecedesReadingRow" PalaceTests/CatalogUI/ContinueRowSectionTests.swift | wc -l
1     # required: ≥1 ✓

$ python3 scripts/check-blast-radius.py --quiet
EXIT: 0   # required: 0 ✓

$ grep -c "AppContainer.production\|TPPBookRegistry.shared" Palace/CatalogUI/Views/ContinueRowSection.swift
0     # required: 0 ✓
```

All 11 contract-verification greps clear.

## For the integrator

- Do NOT commit yet — staged in the worktree at `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_0b7616e7-B-Catalog-ContinueRows-UI`.
- `verify-pr.sh --quick` and the full PR battery have not been run; my dispatch prompt deferred those to integration.
- The two `T` typechange entries for submodules (`adept-ios`, etc.) are pre-existing in the worktree state — not from this module.
- If you want a runtime spy on `ReaderService` for the deferred integration test, that requires `ReaderServicing` protocol extraction. Out of scope for this module; tracked as a follow-up.
