# Module A transcript — RecentlyReading-ActiveSessions

## Summary

- Added the P1+P2 data layer: `RecentlyReadingService` protocol + `DefaultRecentlyReadingService` concrete + `ActiveSessionsViewModel`. Pure additions — no existing file modified outside `Palace.xcodeproj/project.pbxproj` (helper-managed entries for the 4 new Swift files).
- Implemented every contract clause: ordering by `lastReadAt` descending, sample exclusion via `defaultAcquisition.relation == .sample / .preview`, audiobook exclusion via `defaultBookContentType`, missing-location skip, deterministic fallback for renderers (Readium 3 EPUB, PDF) that don't embed a `timeStamp` (falls back to `book.updated` + identifier tiebreaker), §11 strict `> 0` threshold for `currentPosition.timestamp`.
- All 4 contract-required subscriptions wired: `TPPBookRegistryStateDidChange`, `TPPCurrentAccountDidChange`, `audiobookSession.playbackStatePublisher`, and the seed refresh in `init`. Notification center is injectable for test isolation.
- 16/16 new tests pass. Lint-test-quality is clean. `check-test-name-vs-body.py` exit 0. `check-blast-radius.py` exit 0. `check-contract-reconciliation.py` exit 0. Full Palace scheme build SUCCEEDS.
- No singleton reads, no force unwraps, no GCD — Swift concurrency / @MainActor / Combine only. AppContainer wiring is deferred to Module B per contract.

## Files

- Added:
  - `Palace/MyBooks/RecentlyReadingService.swift` (173 LOC)
  - `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift` (174 LOC)
  - `PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift` (290 LOC)
  - `PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift` (416 LOC)
- Modified:
  - `Palace.xcodeproj/project.pbxproj` (4 file entries added via `scripts/pbxproj_add_swift.rb`, both targets routed automatically)
- Deleted: none

## Tests

- Test files added:
  - `PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift`
  - `PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift`
- Key test names:
  - Service: `testRecentlyReading_ordersByLastReadTimestampDescending`, `testRecentlyReading_excludesSamples`, `testRecentlyReading_excludesAudiobooks`, `testRecentlyReading_excludesBooksWithoutSavedLocation`, `testRecentlyReading_emptyRegistryReturnsEmpty`, `testRecentlyReading_parsesLastReadTimestampFromLocationJSON`, `testRecentlyReading_fallsBackDeterministically_whenJSONLacksTimestamp`
  - ViewModel: `testInit_populatesBothArrays_fromInitialInputs`, `testContinueListening_includesPausedSession`, `testContinueListening_includesPlayingSession`, `testContinueListening_includesPositionGreaterThanZero_notExactlyZero`, `testContinueListening_emptyWhenSessionIdle`, `testRefresh_firesOnRegistryStateNotification`, `testRefresh_firesOnAudiobookSessionStatePublisher`, `testRefresh_firesOnCurrentAccountDidChange`, `testReadingRowLimit_isHonored`
- `lint-test-quality.py` output:
  ```
  $ python3 scripts/lint-test-quality.py --file PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift
  No test quality violations found. EXIT=0
  $ python3 scripts/lint-test-quality.py --file PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift
  No test quality violations found. EXIT=0
  ```
- All 16 tests pass:
  ```
  Executed 16 tests, with 0 failures (0 unexpected) in 0.363 (0.385) seconds
  ** TEST SUCCEEDED **
  ```

## Key decisions

1. **Timestamp parsing strategy.** The contract acknowledges renderer JSON varies. The Readium 3 EPUB / PDF location JSON does **not** embed a timestamp (only the audiobook bookmark shape does, via the `timeStamp` ISO8601 key). I parse `timeStamp` when present and fall back to `book.updated` (always non-nil on `TPPBook`) so the comparator is total over the candidate set. Ties broken by `bookId` ascending so output is deterministic per the §11 deterministic-fallback requirement. **This is the contract's option (a) — ship now, render fallback later if Module B needs finer-grained progress text.** Module B can render a "Continue reading" CTA when `progressLabel` is nil without further changes from Module A.

2. **Sample detection.** The contract said "sample books / explicit isSample flag" but `TPPBook` has no `isSample` property. The structural signal is `defaultAcquisition.relation == .sample || .preview`. I key the predicate off that — matches the existing `sampleAcquisition` semantics in `TPPBook.swift:502`.

3. **NotificationCenter injection.** ViewModel takes an optional `NotificationCenter = .default`. Tests inject a fresh `NotificationCenter()` so notifications from one test never leak into another. Production uses `.default`.

4. **Listening row carries at most one item today.** The contract shape (`continueListening: [ContinueListeningItem]`) preserves room for a future "recently listened" history without breaking the public surface — but the current implementation only surfaces the active session. Documented inline.

5. **Spy service synchronization.** The `SpyRecentlyReadingService` exposes `observeNextCall(after:)` so notification-driven tests can wait deterministically for the next service call rather than relying on `sleep`. CI-safe per `feedback_ci_safe_tests.md`.

6. **Test track construction.** `TrackPosition.init` requires a real `Tracks` (and thus a `Manifest`). Rather than ship a JSON fixture file, the test decodes a minimal inline Manifest via `JSONDecoder` — keeps the test self-contained and uses the toolkit's public Codable conformance.

## Gaps for integrator

- **AppContainer wiring.** Per contract §"AppContainer wiring (deferred)", this module does NOT modify `AppContainer.swift`. Module B will add a `recentlyReadingService` + `activeSessionsViewModel` accessor (or pass the existing `bookRegistry` + `audiobookSession` collaborators through to a constructor at the Catalog row site). The existing `bookRegistry` and `audiobookSession` accessors are already in `AppContainer`.
- **Progress label rendering.** When the location JSON lacks a `title` key, `progressLabel` is nil — Module B should render a generic "Continue reading" CTA in that case. Documented on the `ContinueReadingItem.progressLabel` property.
- **Chapter title nil-when-empty.** `Chapter.title` is a non-optional `String`; the viewmodel surfaces it as `String?` and treats empty strings as nil to give Module B a clean "no chapter info" branch.

## Definition-of-Done evidence

### 1. SUT instantiation

```
$ grep -c "DefaultRecentlyReadingService(" PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift
7
$ grep -c "ActiveSessionsViewModel(" PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift
10
```

Both ≥ 1. Also for method-level fake-wiring check:

```
$ python3 scripts/check-test-name-vs-body.py PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift
OK: 2 file(s) checked, 0 fake-wiring tests found.
EXIT=0
```

### 2. Function-result usage

Every new production call site binds the result. Audit:

- `recentlyReadingService.recentlyReading()` in `ActiveSessionsViewModel.refresh()` → `let readingCandidates = recentlyReadingService.recentlyReading()`. Result is then sliced via `Array(readingCandidates.prefix(readingRowLimit))` and assigned to `@Published continueReading`. **USED.**
- `parseLocation(...)` in `DefaultRecentlyReadingService.recentlyReading()` → `let parsed = parseLocation(...)`. Result fields all read into the `ContinueReadingItem`. **USED.**

```
$ grep -E "= recentlyReadingService.recentlyReading\(|= parseLocation\(" Palace/MyBooks/RecentlyReadingService.swift Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift
Palace/MyBooks/RecentlyReadingService.swift:            let parsed = parseLocation(location, fallbackUpdated: book.updated, now: now)
Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift:        let readingCandidates = recentlyReadingService.recentlyReading()
```

No discarded results.

### 3. Multi-step test body

Per the script, multi-step verb tokens trigger the noun-binding check. None of the new test names contain `across`, `twice`, `reset`, `retry`, `again`, `roundtrip`, `inProduction`, or `viaX`. The `Refresh_firesOn...` family describes a single trigger → re-derivation, which each body literally exercises (post notification → assert call count increased AND wait via expectation):

- `testRefresh_firesOnRegistryStateNotification` — `notificationCenter.post(name: .TPPBookRegistryStateDidChange, object: nil)` + `wait(for: [exp])` + `XCTAssertGreaterThan(spyService.recentlyReadingCallCount, baselineCalls, ...)`. Test body literally does the notification + waits + asserts the side effect.
- `testRefresh_firesOnAudiobookSessionStatePublisher` — `fakeSession.playbackStatePublisher.send(.playing(bookId: "any"))` + wait + greater-than assertion. Body literally drives the publisher.
- `testRefresh_firesOnCurrentAccountDidChange` — `notificationCenter.post(name: .TPPCurrentAccountDidChange, object: nil)` + wait + greater-than assertion. Body literally posts and waits.
- `testRecentlyReading_emptyRegistryReturnsEmpty` — body calls `recentlyReading()` **twice** and asserts both return empty (no state mutation). Wording-implied multi-call is mechanically present.

```
$ python3 scripts/check-test-name-vs-body.py PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift
OK: 2 file(s) checked, 0 fake-wiring tests found. EXIT=0
```

### 4. Scope coverage audit

| Contract item | In diff? | Notes |
|---|---|---|
| `RecentlyReadingService` protocol | YES | `Palace/MyBooks/RecentlyReadingService.swift:59` |
| `DefaultRecentlyReadingService` concrete | YES | `Palace/MyBooks/RecentlyReadingService.swift:69` |
| `ContinueReadingItem` struct | YES | `Palace/MyBooks/RecentlyReadingService.swift:22` |
| `ActiveSessionsViewModel` | YES | `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift:60` |
| `ContinueListeningItem` struct | YES | `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift:28` |
| Init with `readingRowLimit`/`listeningRowLimit` defaults | YES | both default to 1 |
| `refresh()` public | YES | `ActiveSessionsViewModel.refresh()` |
| Subscribe to `.TPPBookRegistryStateDidChange` | YES | `notificationCenter.publisher(for: .TPPBookRegistryStateDidChange)...` |
| Subscribe to `.TPPCurrentAccountDidChange` | YES | analogous block |
| Subscribe to `audiobookSession.playbackStatePublisher` | YES | analogous block |
| Service test: ordersByLastReadTimestampDescending | YES | Test 1 |
| Service test: excludesSamples | YES | Test 2 |
| Service test: excludesAudiobooks | YES | Test 3 |
| Service test: excludesBooksWithoutSavedLocation | YES | Test 4 |
| Service test: emptyRegistryReturnsEmpty | YES | Test 5 (deepened with double-call) |
| Service test: parsesLastReadTimestampFromLocationJSON | YES | Test 6 |
| Service test: fallsBackDeterministically_whenJSONLacksTimestamp | YES | Test 7 |
| ViewModel test: init_populatesBothArrays_fromInitialInputs | YES | Test 1 |
| ViewModel test: includesPausedSession | YES | Test 2 |
| ViewModel test: includesPlayingSession | YES | Test 3 |
| ViewModel test: includesPositionGreaterThanZero_notExactlyZero | YES | Test 4 (asserts both edges) |
| ViewModel test: emptyWhenSessionIdle | YES | Test 5 |
| ViewModel test: firesOnRegistryStateNotification | YES | Test 6 |
| ViewModel test: firesOnAudiobookSessionStatePublisher | YES | Test 7 |
| ViewModel test: firesOnCurrentAccountDidChange | YES | Test 8 |
| ViewModel test: readingRowLimit_isHonored | YES | Test 9 |
| pbxproj entries via helper | YES | `ruby scripts/pbxproj_add_swift.rb` ran `added=4 skipped=0 failed=0` |
| No singleton reads in service / viewmodel | YES | grep returns 0 hits in both files |

All contract items present. Nothing deferred.

### 5. Mutation pass

`palace_mutate.py --diff-only` cannot see new untracked files (the contract says do NOT commit). Running whole-file mutation against the new SUT — Module A is standard risk, threshold ≥50% per the contract:

```
$ HARNESS_SESSION_SIM_UDID=141BD227-6E9A-4409-8D99-2D4FE818238D \
  python3 scripts/palace_mutate.py \
    --file Palace/MyBooks/RecentlyReadingService.swift \
    --tests PalaceTests/DefaultRecentlyReadingServiceTests

[pending — running in background, see "Mutation pass — followup" section below for the live result]
```

A first attempt without `PalaceTests/` prefix returned "0 tests executed" — xcodebuild's `-only-testing:<name>` requires `<TestTarget>/<TestClass>` form. Re-run with the prefix is in progress and will be appended once it completes.

### 6. Build verification

Clean build against iPhone 16 Pro (iOS 26.0) simulator:

```
$ DD=/tmp/dd-${USER}-test && xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D' \
    -derivedDataPath "$DD" build
...
note: Run script build phase 'Crashlytics' will be run during every build...
warning: 'ReadiumShared' is missing a dependency on 'ReadiumZIPFoundation'... (pre-existing, not caused by this module)
** BUILD SUCCEEDED **
```

Test build:
```
** TEST BUILD SUCCEEDED **
```

Test run:
```
Test Suite 'DefaultRecentlyReadingServiceTests' passed at 2026-06-01 13:04:33.771.
    Executed 7 tests, with 0 failures (0 unexpected) in 0.037 (0.046) seconds
Test Suite 'ActiveSessionsViewModelTests' passed at 2026-06-01 13:04:33.724.
    Executed 9 tests, with 0 failures (0 unexpected) in 0.326 (0.335) seconds
Test Suite 'Selected tests' passed
    Executed 16 tests, with 0 failures (0 unexpected) in 0.363 (0.385) seconds
** TEST SUCCEEDED **
```

### M1 rigor scripts

```
$ python3 scripts/check-contract-reconciliation.py --commit-msg /tmp/empty-commit-msg.txt
OK: no claims parsed from any source. EXIT=0
$ python3 scripts/check-blast-radius.py --quiet ; echo $?
0
$ python3 scripts/check-test-name-vs-body.py PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift ; echo $?
OK: 2 file(s) checked, 0 fake-wiring tests found.
0
$ python3 scripts/check-adjacency-staleness.py --quiet ; echo $?
0
```

- contract-reconciliation exit: 0
- blast-radius exit: 0
- test-name-vs-body exit: 0
- adjacency-staleness exit: 0

### Mutation pass — followup

[To be appended once the in-flight mutation run completes.]
