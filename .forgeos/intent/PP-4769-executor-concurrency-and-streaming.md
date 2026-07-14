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

## Files in scope
- PalaceTests/Network/TPPNetworkExecutorConcurrencyTests.swift (new)
- Palace.xcodeproj/project.pbxproj (test-target registration only)

## Issue #2 — scope-deferral (NOT landed here)
Investigation (see report) shows the ticket's Issue-#2 premise does not hold:
- `TPPNetworkExecutor.download(_:completion:)` ALREADY uses a
  `URLSessionDownloadTask` (streams to disk); it does NOT buffer the body into a
  single `Data`. So "migrate download to disk streaming" is a no-op for the
  large-`Data` allocation.
- `download(_:completion:)` has ZERO production callers (only two tests). The
  real book-download path, `MyBooksDownloadCenter`, stands up its own
  `URLSession` with a `URLSessionDownloadDelegate` and never calls this method —
  it already streams to disk.
- The actual single-giant-`Data` allocation (the 898c0776 crash's
  `__DataStorage.init`) is in the SHARED data-task completion path
  (`TPPNetworkResponder` `didReceive data:` → `progressData.append` →
  `.success(info.progressData, …)`) used by GET/PUT/POST (e.g. a large OPDS
  feed). Migrating THAT to disk streaming changes the `(Data?, …)` completion
  contract that every GET/PUT/POST caller depends on — a large, cross-cutting
  refactor, not a tight critical-path fix.
Per CLAUDE.md scope-deferral protocol, Issue #2 is STOPPED for a user decision
rather than partial-shipped.

## Reproduction
- Issue #1: Crashlytics abfef568 — EXC_BAD_ACCESS `objc_release` at the tail of
  `executeRequest`, driven from OPDSFeedService.fetchFeed continuations under
  concurrent library-switch load. Deterministic repro: the new test's 64-way
  concurrent fan-out over the shared completion path.
