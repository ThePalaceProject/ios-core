---
name: PP-4769-executor-concurrency-and-streaming
created: 2026-07-14
author: claude-opus-4-8
type: bugfix
tracking: PP-4769 — two 3.1.0-only memory crashes in TPPNetworkExecutor. Issue #1 abfef568 (EXC_BAD_ACCESS objc_release at tail of executeRequest, 7 crashes/7 patrons). Issue #2 898c0776 (EXC_BREAKPOINT in __DataStorage.init NSData→Data bridge, 2 crashes, iPad memory pressure).
related_prs: []
---

# Intent: PP-4769 — executor concurrency regression test + download-streaming study

## Claims
- Adds a concurrency regression test class
  `TPPNetworkExecutorConcurrencyTests` that fires N (64) concurrent
  `executeRequest` / GET calls through the REAL production completion seam
  (`TPPNetworkExecutor` → `TPPNetworkResponder` → `NYPLResult` completion,
  via `HTTPStubURLProtocol`) and asserts every completion fires EXACTLY once —
  no double-fire, no drop, no crash — across the success arm, the failure
  (500) arm, and the raw completion-handler overload. This provably closes
  Issue #1: the crash was a use-after-free driven from an async continuation
  (OPDSFeedService.fetchFeed → withCheckedContinuation) over the shared
  completion path; the Swift 6 `CompletionBox` rework fixed the capture but
  there was no concurrent-teardown test pinning it.

## Anti-claims
- Does NOT modify any production code. The executeRequest completion path is
  already race-clean on develop (single-ownership `CompletionBox` handoff,
  landed by the Swift 6 rework #1190/#1185); this change adds the missing
  regression proof, not a behavior change.
- Does NOT change `download(_:completion:)`, `executeRequest`, the responder,
  or any completion contract.
- No `#if DEBUG` on production paths. No new production API surface.

## Issue #2 — bounded response-size guard (option a, per coordinator decision)
The ticket's original Issue-#2 framing ("stream download to disk in
`download(_:completion:)`") did not hold: that method ALREADY uses a
`URLSessionDownloadTask` (streams to disk), has ZERO production callers, and is
not the crash site; the real book-download path (`MyBooksDownloadCenter`) uses
its own `URLSessionDownloadDelegate` and already streams to disk. The real
single-giant-`Data` allocation (898c0776, `__DataStorage.init`) is the SHARED
data-task completion path (`TPPNetworkResponder` `didReceive data:` →
`progressData.append`).

Per the coordinator's decision, this lands the targeted bounded guard on that
shared path.

## Claims (Issue #2)
- Adds `TPPNetworkResponder.maxResponseBodyBytes` (100 MB, named constant
  `defaultMaxResponseBodyBytes`) — a per-response body ceiling.
- Up-front guard in a new `urlSession(_:dataTask:didReceive response:
  completionHandler:)`: a declared `Content-Length` (`expectedContentLength`)
  over the cap `.cancel`s the response before any body is buffered.
- Running-total guard in `urlSession(_:dataTask:didReceive data:)`: for
  chunked/unknown-length responses, once accumulated size would exceed the cap
  the task is cancelled and no further data is appended.
- Oversize tasks complete with a clean `TPPErrorCode.responseTooLarge` (915)
  NSError in `didCompleteWithError` (checked before the generic cancelled
  branch), and the partial body is discarded.

## Anti-claims (Issue #2)
- Does NOT change the `(Data?, URLResponse?, Error?)` / `NYPLResult<Data>`
  completion contract for any caller. Only the pathological oversize case
  changes behavior (clean failure instead of OOM crash).
- Does NOT change `download(_:completion:)`, `executeRequest`, the 401/token
  refresh/retry path, or the auth-error decision.
- `maxResponseBodyBytes` is a documented plain `internal var` (no `#if DEBUG`,
  no new init param, no new public API surface) — test seam only, mirrors
  `TPPNetworkExecutor.tokenRefreshWatchdogSeconds`.

## Files in scope
- PalaceTests/Network/TPPNetworkExecutorConcurrencyTests.swift (new — Issue #1)
- PalaceTests/Network/TPPNetworkResponderSizeLimitTests.swift (new — Issue #2)
- Palace/Network/TPPNetworkResponder.swift (Issue #2 guard)
- Palace/Logging/TPPErrorLogger.swift (adds `responseTooLarge = 915`)
- Palace.xcodeproj/project.pbxproj (test-target registration only)

## Reproduction
- Issue #1: Crashlytics abfef568 — EXC_BAD_ACCESS `objc_release` at the tail of
  `executeRequest`, driven from OPDSFeedService.fetchFeed continuations under
  concurrent library-switch load. Deterministic repro: the new test's 64-way
  concurrent fan-out over the shared completion path.
- Issue #2: Crashlytics 898c0776 — EXC_BREAKPOINT in `__DataStorage.init` under
  iPad memory pressure buffering a giant response body. Deterministic repro:
  `TPPNetworkResponderSizeLimitTests` lowers the cap and drives oversize
  declared-length + accumulated-length responses to the clean-failure path.
