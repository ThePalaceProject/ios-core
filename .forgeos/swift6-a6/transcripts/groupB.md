# Swift 6 `targeted` sweep — Phase A.6, GROUP B (MyBooks download tests)

Isolation-only fixes. No behavior change. Only GROUP B files touched.

Primary fix pattern: `must restate inherited '@unchecked Sendable' conformance`
→ append `, @unchecked Sendable` to the test-double subclass declaration
(`URLSessionDownloadTask` subclasses used purely as injectable fakes/stubs).

## Per-file log

### PalaceTests/MyBooks/DefaultRecentlyReadingServiceTests.swift
- Worklist warning: `:402:42 conformance of 'StubBookOpenTracker' to 'BookOpenTracking' crosses into main actor-isolated code`
- Status: **already resolved** in current tree — `StubBookOpenTracker` is already annotated `@MainActor` (line 401). No edit required; warning does not reproduce. File NOT modified.

### PalaceTests/MyBooks/DownloadAuthRetryHandlerAuthCoordinatorTests.swift
- `:93` `FakeURLSessionDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/DownloadAuthRetryHandlerTests.swift
- `:123` `FakeURLSessionDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/DownloadCancellationHandlerTests.swift
- `:183` `StubDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/DownloadCompletionParserTests.swift
- `:277` `StubDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/DownloadResumeAfterKillTests.swift
- `:262` `LateCancelStubTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/DownloadStartCoordinatorTests.swift
- `:280` `StubDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/DownloadStartDispatcherTests.swift
- Worklist warning: `:877:44 conformance of 'SpyDispatcherDelegate' to 'DownloadStartDispatcherDelegate' crosses into main actor-isolated code`
- Status: **already resolved** in current tree — `SpyDispatcherDelegate` is already annotated `@MainActor` (line 876). No edit required; warning does not reproduce. File NOT modified.

### PalaceTests/MyBooks/DownloadTaskLifecycleServiceTests.swift
- `:208` `StubDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/DownloadThrottlingServiceTests.swift
- `:231` `FakeDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/LCPFulfillmentHandlerTests.swift
- `:362` `FakeDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/MyBooksDownloadCenterConcurrencyTests.swift
- `:704` `StubDownloadTask` — added `, @unchecked Sendable`.
- `:726` `SyncCompletingDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/MyBooksDownloadCenterTests.swift
- `:21` `MockURLSessionDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/RightsManagementDispatcherTests.swift
- `:294` `StubDownloadTask` — added `, @unchecked Sendable`.

### PalaceTests/MyBooks/TokenRefreshInterceptorAuthCoordinatorTests.swift
- `:69` `FakeURLSessionDownloadTask` — added `, @unchecked Sendable`.

## Summary
- Warnings in worklist for GROUP B: 16 (lines 19–34).
- Fixed via edit: 14 (`@unchecked Sendable` restatements).
- Already resolved in tree (no edit needed): 2 (`@MainActor` conformance-crossing warnings — StubBookOpenTracker, SpyDispatcherDelegate).
- Production `Palace/...` files touched: 0.
- `nonisolated(unsafe)` used: 0.
- Confirm: ONLY GROUP B files modified.
