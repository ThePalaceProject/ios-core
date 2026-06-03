# Module B — Catalog "Continue Reading" + "Continue Listening" rows (P1 + P2 UI)

**Risk:** standard (Catalog top-of-feed UI addition; no critical-path behavior altered)
**Reviewers required:** architect, qa_test, clean_code
**Estimated LOC:** 150–300 prod + 150–250 tests
**Depends on:** A (consumes `ActiveSessionsViewModel`)
**Blocks:** none (D consumes Module C presenter; this module only consumes A)
**Phase coverage:** §6.3 (B1 surface placement) + §8 P1 + §8 P2 from `docs/architecture/in-app-navigation-during-playback.md`

## Scope summary

Render the "Continue Listening" + "Continue Reading" hero rows at the top of the Catalog feed (above existing lanes), driven by Module A's `ActiveSessionsViewModel`. Wire the viewmodel through `CatalogView` → `CatalogContentView`. Wire the tap-to-resume actions: ebook taps go through `AppContainer.production().readerService.openEPUB(_:)` / `.openPDF(_:)`; audiobook taps go through `AudiobookSessionManaging.openAudiobook(_:startPlaying:)`.

**Audible-pattern decision (§11 row 4):** both rows live on Catalog. "Continue Listening" is the first row when present, then "Continue Reading", then existing entry-point selectors + lanes. Both rows are hidden when their respective arrays are empty.

## Public surface — new types

### `ContinueRowSection` (SwiftUI view)

File: `Palace/CatalogUI/Views/ContinueRowSection.swift` (NEW).

```swift
import SwiftUI

struct ContinueRowSection: View {
    @ObservedObject var viewModel: ActiveSessionsViewModel
    let onResumeReading: (TPPBook) -> Void   // taps an EPUB/PDF card
    let onResumeListening: (TPPBook) -> Void // taps an audiobook card

    var body: some View { ... }
}
```

The rows render as horizontal hero cards (Audible / Apple Books pattern: large cover + title + progress label + play affordance). For 3.3.0 prototype the row is a single hero card (limit=1); the API supports >1 for future expansion. Reduce-motion + Dynamic Type already handled by SwiftUI defaults — verify nothing custom breaks AX5.

### Wiring changes

File: `Palace/CatalogUI/Views/CatalogContentView.swift` (MODIFY).
- Add `@ObservedObject var activeSessions: ActiveSessionsViewModel` as a non-optional field (constructor-injected from `CatalogView`).
- Add `onResumeReading: (TPPBook) -> Void` and `onResumeListening: (TPPBook) -> Void` closures.
- In `body`, prepend `ContinueRowSection(...)` ABOVE the existing `selectorsView` / `ScrollView`. Conditionally hide when both arrays are empty.

File: `Palace/CatalogUI/Views/CatalogView.swift` (MODIFY).
- Take `activeSessionsViewModel: ActiveSessionsViewModel` via init (default-constructed inside `AppTabHostView`'s init for the production path; tests inject explicitly).
- Pass it into `CatalogContentView`.
- Wire `onResumeReading` to call `readerService.openEPUB(book)` for `.epub` content type and `readerService.openPDF(book)` for `.pdf`. Use `appContainer.readerService` from the environment.
- Wire `onResumeListening` to call `Task { await audiobookSession.openAudiobook(book, startPlaying: true) }` where `audiobookSession` comes from `AppContainer`.

File: `Palace/AppInfrastructure/AppTabHostView.swift` (MODIFY).
- Construct the `ActiveSessionsViewModel` once in `init` (StateObject) using `appContainer.bookRegistry`, `appContainer.audiobookSession`, and the new `DefaultRecentlyReadingService(bookRegistry:)`.
- Pass it into `CatalogView`.

## Behavior contracts (test these — required)

### `ContinueRowSectionTests` in `PalaceTests/CatalogUI/`

1. **`testContinueRowSection_hidesBothRows_whenViewModelIsEmpty`** — both arrays empty → the rendered hierarchy MUST NOT contain row chrome. Use ViewInspector OR a behavior test that snapshots empty (zero rows) state.

2. **`testContinueRowSection_showsListeningRow_whenPresent`** — viewmodel `continueListening.count == 1` → row text contains the book title.

3. **`testContinueRowSection_showsReadingRow_whenPresent`** — viewmodel `continueReading.count == 1` → row text contains the book title.

4. **`testContinueRowSection_listeningRowPrecedesReadingRow`** — both rows populated → in the rendered hierarchy, listening appears BEFORE reading (Audible order, §11 row 4).

5. **`testContinueRowSection_tappingReadingRow_invokesOnResumeReading`** — tap fires `onResumeReading(book)` with the correct book. Use a spy closure.

6. **`testContinueRowSection_tappingListeningRow_invokesOnResumeListening`** — tap fires `onResumeListening(book)` with the correct book. Use a spy closure.

### `CatalogViewContinueRowsIntegrationTests` in `PalaceTests/CatalogUI/`

1. **`testCatalogView_passesActiveSessionsToContentView`** — construct `CatalogView` with a viewmodel containing 1 listening + 1 reading; assert that `CatalogContentView` receives the same instance. (Behavior assertion: rendered hierarchy contains both row texts.)

2. **`testCatalogView_resumeListening_callsAudiobookSession_openAudiobook`** — simulate a tap on the listening row → spy `AudiobookSessionManaging` records `openAudiobook(_:startPlaying:)` call with the right book identifier.

3. **`testCatalogView_resumeReading_callsReaderService_openEPUB_forEPUB`** — tap on listening row → spy `ReaderService` records `openEPUB(_:)` call. (If `ReaderService` is not protocol-extracted, this test is deferred; document and propose extraction in a follow-up. Do not block on it.)

## Files in scope for this implementer

Production:
- `Palace/CatalogUI/Views/ContinueRowSection.swift` (NEW)
- `Palace/CatalogUI/Views/CatalogContentView.swift` (MODIFY — add ActiveSessionsViewModel + closures + row prepending)
- `Palace/CatalogUI/Views/CatalogView.swift` (MODIFY — accept + thread viewmodel; wire resume actions)
- `Palace/AppInfrastructure/AppTabHostView.swift` (MODIFY — construct ActiveSessionsViewModel and DefaultRecentlyReadingService; pass to CatalogView)

Tests:
- `PalaceTests/CatalogUI/ContinueRowSectionTests.swift` (NEW)
- `PalaceTests/CatalogUI/CatalogViewContinueRowsIntegrationTests.swift` (NEW)

## Files OFF-LIMITS to this implementer

- `Palace/MyBooks/RecentlyReadingService.swift` — Module A's contract; consume the public surface only.
- `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift` — Module A owns; consume only.
- `Palace/Audiobooks/*` — Module C territory.
- `Palace/AppInfrastructure/NavigationHostView.swift`, `NavigationCoordinator.swift` — Module D will touch.
- `Palace/AppInfrastructure/AppContainer.swift` — do NOT modify the struct shape. The viewmodel + service are constructed inside `AppTabHostView` (composition root for this surface); no container additions needed for P1/P2.

## Test patterns

- `@MainActor` test class.
- ViewInspector or assertion against rendered SwiftUI hierarchy where feasible — if the codebase lacks ViewInspector, use behavior tests that exercise the closures directly (spy closures + invoke the modifier the row would fire).
- Use `TPPBookMocker` (`PalaceTests/Mocks/`) for book construction.
- Mock `AudiobookSessionManaging` via existing or new mock in `PalaceTests/Mocks/`.

## Verification criteria (grep-able)

```bash
# 1. New view exists:
grep -c "struct ContinueRowSection" Palace/CatalogUI/Views/ContinueRowSection.swift   # >= 1

# 2. CatalogContentView consumes ActiveSessionsViewModel:
grep -n "ActiveSessionsViewModel" Palace/CatalogUI/Views/CatalogContentView.swift   # >= 1 hit

# 3. CatalogContentView prepends ContinueRowSection:
grep -n "ContinueRowSection" Palace/CatalogUI/Views/CatalogContentView.swift   # >= 1 hit

# 4. CatalogView wires both resume closures:
grep -n "onResumeReading\|onResumeListening" Palace/CatalogUI/Views/CatalogView.swift   # both present

# 5. AppTabHostView constructs the viewmodel:
grep -n "ActiveSessionsViewModel(" Palace/AppInfrastructure/AppTabHostView.swift   # >= 1
grep -n "DefaultRecentlyReadingService(" Palace/AppInfrastructure/AppTabHostView.swift   # >= 1

# 6. Tests construct the SUTs:
grep -c "ContinueRowSection(" PalaceTests/CatalogUI/ContinueRowSectionTests.swift   # >= 1
python3 scripts/check-test-name-vs-body.py PalaceTests/CatalogUI/ContinueRowSectionTests.swift   # exit 0
python3 scripts/check-test-name-vs-body.py PalaceTests/CatalogUI/CatalogViewContinueRowsIntegrationTests.swift   # exit 0

# 7. Row order test exists:
grep -in "listeningRowPrecedesReadingRow\|listeningBeforeReading\|listening_then_reading" PalaceTests/CatalogUI/ContinueRowSectionTests.swift   # >= 1

# 8. Blast-radius (DoD #9):
python3 scripts/check-blast-radius.py --quiet   # exit 0

# 9. No singleton reads in the new view:
grep -n "AppContainer.production\|TPPBookRegistry.shared" Palace/CatalogUI/Views/ContinueRowSection.swift   # 0 hits
```

## pbxproj wiring

```bash
ruby scripts/pbxproj_add_swift.rb Palace/CatalogUI/Views/ContinueRowSection.swift
ruby scripts/pbxproj_add_swift.rb PalaceTests/CatalogUI/ContinueRowSectionTests.swift
ruby scripts/pbxproj_add_swift.rb PalaceTests/CatalogUI/CatalogViewContinueRowsIntegrationTests.swift
```

The modifies to `CatalogContentView.swift`, `CatalogView.swift`, and `AppTabHostView.swift` do NOT require pbxproj changes (those files are already in both targets).

## Scope-deferral protocol

If wiring `onResumeReading` requires extracting a `ReaderServicing` protocol from `ReaderService` (currently a concrete class), STOP and propose:
- (a) defer the integration test to a follow-up after `ReaderService` protocol extraction;
- (b) consume the concrete `ReaderService` directly (less testable, but works);
- (c) extend this module's scope to add the protocol.

Do NOT silently ship partial wiring while claiming READY.

## Risk classification

Standard. UI-only addition + 3-file edit. The Catalog tab's existing behavior is unchanged when both rows are empty (the section view returns `EmptyView()`).
