# Module B — MyBooks (CI-flake migration + URLSession.shared sweep)

## Files in scope (6)

FLAKE-* migration:
- PalaceTests/MyBooks/MyBooksViewModelTests.swift (FLAKE-002: L428, L1607)
- PalaceTests/MyBooks/DownloadProgressPublisherTests.swift (FLAKE-002: L184)
- PalaceTests/MyBooks/TokenRefreshInterceptorTests.swift (FLAKE-002: L239, L262)
- PalaceTests/MyBooks/MyBooksDownloadCenterIntegrationTests.swift (FLAKE-001: L52 Thread.sleep)

URLSession.shared.downloadTask sweep (use `fakeDownloadTask()` helper from Phase 0):
- PalaceTests/MyBooks/DownloadStateManagerTests.swift (8 sites: L49, L67, L105, L126, L139, L140, L161, L181)
- PalaceTests/MyBooks/TokenRefreshInterceptorTests.swift (6 sites: L137, L148, L166, L192, L386, L409)
- PalaceTests/MyBooks/BackgroundDownloadHandlerTests.swift (2 sites — find via `grep -n "URLSession.shared.downloadTask"`)

Authoritative list: `grep -rn "URLSession.shared.downloadTask" PalaceTests/MyBooks/`.

## Migration patterns

FLAKE migration: same as Module A — `drainMainQueue` / `awaitCondition` / production-signal expectation.

URLSession.shared.downloadTask sweep: replace each
```swift
let task = URLSession.shared.downloadTask(with: URL(string: "https://example.com")!)
```
with
```swift
let task = fakeDownloadTask()
```

If the test needs a specific URL (rare — most just want any URLSessionDownloadTask for identity comparison):
```swift
let task = fakeDownloadTask(url: URL(string: "https://example.test/specific")!)
```

The `fakeDownloadTask` helper is defined in `PalaceTests/XCTestCase+fakeDownloadTask.swift` (already on this branch from commit 9c0eaf7d5). It returns a URLSessionDownloadTask backed by `URLSessionConfiguration.ephemeral` + `NoNetworkURLProtocol` — never resume it, but if you accidentally do, NSURLErrorNotConnectedToInternet is returned rather than leaking to real network.

## Out of scope

- `Palace/MyBooks/*` — production code is **read-only**.
- Adding new tests for coverage.
- SHALLOW-001 / FLUFF-001-003 cleanup in these files (separate Phase 4).
- The 16 URLSession.shared sweep is part of THIS module's scope — do not defer.

## Verification before reporting done

1. Linter for each scoped file returns 0 blocking violations.
2. `grep -n "URLSession.shared.downloadTask" PalaceTests/MyBooks/` returns 0 hits.
3. Each migrated test class still passes:
   ```bash
   xcodebuild test -project Palace.xcodeproj -scheme Palace \
     -destination "id=$HARNESS_SESSION_SIM_UDID" \
     -only-testing:PalaceTests/MyBooksViewModelTests \
     -only-testing:PalaceTests/DownloadProgressPublisherTests \
     -only-testing:PalaceTests/TokenRefreshInterceptorTests \
     -only-testing:PalaceTests/MyBooksDownloadCenterIntegrationTests \
     -only-testing:PalaceTests/DownloadStateManagerTests \
     -only-testing:PalaceTests/BackgroundDownloadHandlerTests
   ```
4. Write `.forgeos/swarms/swarm_9d3d2fab/transcripts/module-b-mybooks.md`.

Do NOT commit. Do NOT push.
