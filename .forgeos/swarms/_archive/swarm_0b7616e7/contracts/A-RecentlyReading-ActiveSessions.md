# Module A — RecentlyReadingService + ActiveSessionsViewModel (P1 + P2 data layer)

**Risk:** standard (additive — no existing audiobook/auth/borrow code path is altered)
**Reviewers required:** architect, qa_test, clean_code
**Estimated LOC:** 250–400 prod + 250–400 tests
**Depends on:** none — can run in parallel with C
**Blocks:** B (CatalogUI Continue rows consumes `ActiveSessionsViewModel`)
**Phase coverage:** §6.3 (B1 surface) + §8 P1 + §8 P2 from `docs/architecture/in-app-navigation-during-playback.md`

## Scope summary

Create the two pure-additive types that drive both "Continue Reading" and "Continue Listening" rows. **No UI** in this module — UI lives in Module B. **No audiobook hoist** in this module — that is Module C.

Existing inputs (do NOT touch):
- `TPPBookRegistryProvider.location(forIdentifier:)` — last-read source of truth for EPUB/PDF.
- `TPPBookRegistry.myBooks` — list of "in My Books" candidates.
- `TPPBook.defaultBookContentType` (`Palace/Book/Models/TPPBook.swift:615`) — `.epub` / `.pdf` / `.audiobook` / `.unsupported`.
- `TPPBookLocation.locationString` (`Palace/Book/Models/TPPBookLocation.swift:33`) — opaque renderer-specific JSON; the `lastSavedTimeStamp` lives inside this JSON per renderer.
- `AudiobookSessionManager` (`Palace/Audiobooks/AudiobookSessionManager.swift:83`) — `state: AudiobookSessionState`, `currentBook: TPPBook?`, `currentPosition: TrackPosition?`, `playbackStatePublisher`.
- `AudiobookSessionManaging` protocol (`Palace/Audiobooks/AudiobookSessionManaging.swift:19`) — already DI-friendly.
- `AppContainer.audiobookSession: AudiobookSessionManaging` — already in container.

Outputs (new):
1. `RecentlyReadingService` protocol + concrete impl — returns "Continue Reading" candidates ordered by last-read timestamp descending. Excludes samples. Excludes books not in `myBooks` (or with no saved location).
2. `ActiveSessionsViewModel` (`@MainActor ObservableObject`) — two `@Published` arrays: `continueReading: [ContinueReadingItem]`, `continueListening: [ContinueListeningItem]`. Refreshes on `TPPBookRegistryStateDidChange`, `TPPCurrentAccountDidChange`, and on `audiobookSession.playbackStatePublisher` emissions.

## Public surface — new types

### `RecentlyReadingService` (protocol + impl)

File: `Palace/MyBooks/RecentlyReadingService.swift` (NEW — production-only, NOT a package).

```swift
import Foundation

@MainActor
protocol RecentlyReadingService {
    /// Returns "Continue Reading" candidates ordered by last-read timestamp descending.
    /// Excludes samples (TPPBook.isSample==true OR the saved location is a sample bookmark).
    /// Excludes audiobooks (those go to the Continue Listening row).
    /// Excludes books with no saved location.
    /// Caller is responsible for prefix(limit) — service returns the full ordered set.
    func recentlyReading() -> [ContinueReadingItem]
}

struct ContinueReadingItem: Identifiable, Equatable {
    var id: String { bookId }
    let bookId: String
    let book: TPPBook
    let contentType: TPPBookContentType  // .epub or .pdf — never .audiobook
    let lastReadAt: Date
    let progressFraction: Double?
    let progressLabel: String?
}

final class DefaultRecentlyReadingService: RecentlyReadingService {
    init(bookRegistry: TPPBookRegistryProvider, clock: @escaping () -> Date = Date.init) { ... }
    func recentlyReading() -> [ContinueReadingItem] { ... }
}
```

### `ActiveSessionsViewModel`

File: `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift` (NEW — under CatalogUI because it drives the Catalog row; the data source service lives in MyBooks).

```swift
import Combine
import Foundation
import SwiftUI

@MainActor
final class ActiveSessionsViewModel: ObservableObject {
    @Published private(set) var continueReading: [ContinueReadingItem] = []
    @Published private(set) var continueListening: [ContinueListeningItem] = []

    init(
        recentlyReadingService: RecentlyReadingService,
        audiobookSession: AudiobookSessionManaging,
        notificationCenter: NotificationCenter = .default,
        readingRowLimit: Int = 1,
        listeningRowLimit: Int = 1
    )

    /// Re-derives both arrays from current inputs. Called by init, by the
    /// registry-state notification subscriber, and by the audiobook session
    /// publisher subscriber.
    func refresh()
}

struct ContinueListeningItem: Identifiable, Equatable {
    var id: String { bookId }
    let bookId: String
    let book: TPPBook
    let isCurrentlyPlaying: Bool
    let chapterTitle: String?
    let progressFraction: Double?
    let progressLabel: String?
}
```

## Behavior contracts (test these — required)

### `RecentlyReadingService` — `DefaultRecentlyReadingServiceTests` in `PalaceTests/MyBooks/`

1. **`testRecentlyReading_ordersByLastReadTimestampDescending`** — registry has 3 books with EPUB locations saved at T0, T1, T2 (T2 newest). Returned order MUST be `[T2, T1, T0]`. Mutates: flipping `>` to `<` in the sort comparator fails the test.

2. **`testRecentlyReading_excludesSamples`** — book with `defaultAcquisition.type` indicating a sample OR a registry location flagged sample MUST NOT appear in output.

3. **`testRecentlyReading_excludesAudiobooks`** — book with `defaultBookContentType == .audiobook` and a saved location MUST NOT appear (audiobooks go to the listening row).

4. **`testRecentlyReading_excludesBooksWithoutSavedLocation`** — registry has a downloaded EPUB but `registry.location(forIdentifier:)` returns nil. MUST NOT appear.

5. **`testRecentlyReading_emptyRegistryReturnsEmpty`** — `myBooks` empty → output `[]`. No crash, no force-unwrap.

6. **`testRecentlyReading_parsesLastReadTimestampFromLocationJSON`** — given a `TPPBookLocation` with a known JSON shape, parsed `lastReadAt` MUST match the embedded `lastSavedTimeStamp`. Mutates: swapping key name fails the test.

7. **`testRecentlyReading_fallsBackDeterministically_whenJSONLacksTimestamp`** — for older PDF-renderer locations that may not embed a timestamp, the service falls back to a deterministic comparator (document choice). MUST be deterministic and not crash.

### `ActiveSessionsViewModel` — `ActiveSessionsViewModelTests` in `PalaceTests/ViewModels/`

1. **`testInit_populatesBothArrays_fromInitialInputs`** — 1 in-progress EPUB + audiobook session in `.paused(bookId:)` for book X → `continueReading.count == 1` and `continueListening.count == 1`.

2. **`testContinueListening_includesPausedSession`** — session state `.paused(bookId: "B")` + `currentPosition.timestamp > 0` → `continueListening` contains B.

3. **`testContinueListening_includesPlayingSession`** — session state `.playing(bookId: "B")` → `continueListening` contains B with `isCurrentlyPlaying == true`.

4. **`testContinueListening_includesPositionGreaterThanZero_notExactlyZero`** — §11 decision: threshold is `>0` seconds. A session with `currentPosition.timestamp == 0.0` MUST be EXCLUDED. A session with `currentPosition.timestamp == 0.5` MUST be INCLUDED. Mutates: flipping `> 0` to `>= 0` fails the test.

5. **`testContinueListening_emptyWhenSessionIdle`** — session `.idle` → `continueListening == []`.

6. **`testRefresh_firesOnRegistryStateNotification`** — post `.TPPBookRegistryStateDidChange` → spy service's `recentlyReading()` MUST be called again. Mutates: removing the NotificationCenter subscriber fails the test.

7. **`testRefresh_firesOnAudiobookSessionStatePublisher`** — spy session manager emits a new `AudiobookSessionState` via `playbackStatePublisher` → viewmodel re-derives `continueListening`. Mutates: dropping the publisher subscription fails the test.

8. **`testRefresh_firesOnCurrentAccountDidChange`** — post `.TPPCurrentAccountDidChange` → service queried again (so library swap clears the rows for the previous account). Mutates: removing the notification subscriber fails the test.

9. **`testReadingRowLimit_isHonored`** — service returns 5 EPUBs, viewmodel constructed with `readingRowLimit: 2` → `continueReading.count == 2` (top-2 by recency).

## Files in scope for this implementer

Production:
- `Palace/MyBooks/RecentlyReadingService.swift` (NEW)
- `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift` (NEW)

Tests:
- `PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift` (NEW)
- `PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift` (NEW)

Mocks (extend or add to `PalaceTests/Mocks/`):
- A spy `RecentlyReadingService` for viewmodel tests.
- A `MockAudiobookSessionManager` that conforms to `AudiobookSessionManaging` and exposes `playbackStatePublisher` writable. Check `PalaceTests/Mocks/` for an existing mock first; only add if missing.

## Files OFF-LIMITS to this implementer

- `Palace/Audiobooks/*` — Module C territory.
- `Palace/AppInfrastructure/AppTabHostView.swift`, `NavigationHostView.swift`, `NavigationCoordinator.swift` — Modules C/D.
- `Palace/CatalogUI/Views/CatalogView.swift`, `CatalogContentView.swift` — Module B will integrate the row.
- `Palace/AppInfrastructure/AppContainer.swift` — wired by Module B at integration time after this contract lands.

## AppContainer wiring (deferred)

This module does NOT wire the new types into `AppContainer`. The container exposes `bookRegistry` and `audiobookSession` already; Module B threads them through when wiring the Catalog row. This module's tests construct the viewmodel with explicit collaborators (no `.shared`).

## Test patterns

- `@MainActor` test class (AudiobookSessionManaging is MainActor-isolated).
- `XCTestExpectation` + small budget (200ms) for publisher-driven tests; never `sleep`.
- Mock dependencies via constructor injection — no `AppContainer.production()` reads in tests.
- TPPBook construction: `TPPBookMocker` (`PalaceTests/Mocks/`).

## Verification criteria (grep-able)

```bash
# 1. New types exist:
grep -c "protocol RecentlyReadingService" Palace/MyBooks/RecentlyReadingService.swift   # >= 1
grep -c "final class DefaultRecentlyReadingService" Palace/MyBooks/RecentlyReadingService.swift   # >= 1
grep -c "final class ActiveSessionsViewModel" Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift   # >= 1

# 2. SUT instantiation in tests (DoD #1):
grep -c "DefaultRecentlyReadingService(" PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift   # >= 1
grep -c "ActiveSessionsViewModel(" PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift   # >= 1
python3 scripts/check-test-name-vs-body.py PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift   # exit 0
python3 scripts/check-test-name-vs-body.py PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift   # exit 0

# 3. Threshold test exists and pins both edges:
grep -n "timestamp == 0\|timestamp_is_zero\|PositionGreaterThanZero_notExactlyZero" PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift   # both branches present

# 4. Samples-excluded test exists:
grep -in "excludesSample" PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift

# 5. Mutation pass (additive — non-critical-path; aim 50% diff-scoped):
python3 scripts/palace_mutate.py --file Palace/MyBooks/RecentlyReadingService.swift --tests DefaultRecentlyReadingServiceTests --diff-only

# 6. Blast-radius (DoD #9):
python3 scripts/check-blast-radius.py --quiet   # exit 0

# 7. No singleton reads in viewmodel:
grep -n "AppContainer.production\|TPPBookRegistry.shared\|AudiobookSessionManager.shared" Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift   # 0 hits

# 8. No singleton reads in service:
grep -n "AppContainer.production\|TPPBookRegistry.shared" Palace/MyBooks/RecentlyReadingService.swift   # 0 hits
```

## pbxproj wiring

After creating each file, run:

```bash
ruby scripts/pbxproj_add_swift.rb Palace/MyBooks/RecentlyReadingService.swift
ruby scripts/pbxproj_add_swift.rb Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift
ruby scripts/pbxproj_add_swift.rb PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift
ruby scripts/pbxproj_add_swift.rb PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift
```

The helper auto-routes test files to the `PalaceTests` target. Do NOT hand-edit `Palace.xcodeproj/project.pbxproj`.

## Scope-deferral protocol

If progress-fraction extraction from `TPPBookLocation.locationString` proves entangled (different renderers store JSON differently), STOP and propose:
- (a) ship with `progressFraction: nil` / `progressLabel: nil` for unknown renderers, document the gap, let Module B render a fallback "Continue reading" CTA without progress text;
- (b) extend Module A to parse the 2–3 known renderer shapes.

Do NOT silently ship partial parsing while claiming READY.

## Risk classification

Standard. Pure additions. No existing code path altered. No critical-path file modified.
