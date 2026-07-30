---
name: lcp-open-latency-491
created: 2026-07-30
author: Maurice Carrier
branch: hotfix/3.2.3-lcp-open
priority: 3.2.3 build 491 (critical-path: borrow / download / DRM fulfillment)
---

# Intent: cut LCP audiobook open latency and make the wait legible (3.2.3 build 491)

## Context

With LCP streaming-from-license broken upstream (readium/swift-toolkit#579, no
release carries the fix), a `.lcpa` must be fully on disk before the player will
open. The archive is a single encrypted container, so there is no partial-play
threshold: time-to-open is now proportional to the size of the audiobook, where
in 3.1.0 it was independent of it.

Measured on the simulator against the A1QA staging library on build 490:

| Title | Lane | `.lcpa` |
|---|---|---|
| The Hitchhiker's Guide to the Galaxy | Palace Marketplace | 438 MB |
| Carl's Doomsday Scenario | Audible | 778 MB |
| The Confusion | Audible | 1,897 MB |

Two defects sit on top of that inherent cost.

**Duplicate download.** `LocalBookContentService.redownloadLCPContentFile` guards
only on `fileExists`, so an in-flight download is invisible to it. Two callers
reach it independently: the registry-load self-heal (`BookRegistrySync`) and the
open-time gate (`AudiobookSessionManager.gateOnLCPContentDownload`). Reproduced
twice on the simulator: two concurrent full transfers of the same archive, one
stored and one discarded (`⚠️ File move failed`). For The Confusion that is 3.8 GB
moved instead of 1.9 GB, with both transfers competing for the same bandwidth.
This accounts for roughly half of the reported ~2-minute open at 280 Mbps.

**No progress during the wait.** `LCPFulfillmentHandler` marks an LCP audiobook
`.downloadSuccessful` the instant the small `.lcpl` lands, so the half-sheet's
existing linear progress bar is disqualified by its own visibility condition
(`bookState == .downloading && buttonState != .downloadSuccessful`) and renders
an invisible spacer. The percentage is already being computed and published; it
is simply never drawn. Field report: patrons read the silence as a failure and
back out before the download completes.

## Claims

- **A.** `redownloadLCPContentFile` becomes idempotent against concurrency: a
  lock-guarded in-flight set keyed by book identifier, released on completion
  (success and failure), so a second caller during the download window no-ops
  instead of starting a duplicate transfer. The existing `fileExists` skip is
  retained. The LCP fulfillment call is injected so the guard is testable
  without a live LCP service, a license on disk, or a network fetch.
- **B.** An LCP audiobook stays `.downloading` until its `.lcpa` is actually on
  disk; `markDownloadSuccessful` moves from the license-fulfilled point into the
  content-completion callback. This lights up the existing half-sheet and
  book-cell progress bars for the fresh-borrow path with no UI change, and stops
  offering "Listen" for a book whose audio is absent. Cancel remains functional
  on this path because the fulfillment download task is registered in
  `downloadInfo`.
- **C.** The self-heal re-download reports progress (currently discarded as
  `progress: { _ in }`) and an active/idle signal, which `BookDetailViewModel`
  exposes as `isDownloadingLCPContent` and `HalfSheetView.progressIndicator`
  renders as the linear bar. This path is NOT covered by B: the book is
  legitimately `.downloadSuccessful` from an earlier session and only its content
  went missing.
- **D.** A dependency-upgrade gate: any change to the Readium pin must record
  money-path validation evidence or CI fails, plus the architecture record of the
  3.7 → 3.9 streaming loss that motivates it.

## Anti-claims

- **Does NOT restore LCP streaming.** That waits on readium/swift-toolkit#579.
  The inherent size-proportional wait remains; this change removes the doubling
  and makes the remaining wait legible.
- **Does NOT put the self-heal re-download into `.downloading`.** That state maps
  to `buttons = [.cancel]` (`BookButtonState.swift:106`), and the self-heal runs
  on an out-of-band background `URLSession` that is not registered in
  `downloadInfo`, so Cancel would be a button that cannot cancel. C therefore
  uses a dedicated signal rather than a registry-state change.
- **Does NOT downgrade a book that already has local content.** On a failed
  content download the existing "streaming license intact" guard is preserved for
  books whose `.lcpa` is present; only a first fulfillment that never landed
  content becomes `.downloadFailed` (honest and retryable).
- **Does NOT change the 180 s gate ceiling.** Flagged separately: a large archive
  on a slow connection can still exceed it and surface "Audiobook Unavailable".

## Files in scope

- `Palace/MyBooks/LocalBookContentService.swift` (A, C)
- `Palace/MyBooks/DownloadProgressPublisher.swift` (C)
- `Palace/MyBooks/MyBooksDownloadCenter.swift` (C wiring)
- `Palace/MyBooks/LCPFulfillmentHandler.swift` (B)
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` (C)
- `Palace/Book/UI/BookDetail/HalfSheetview.swift` (C)
- `PalaceTests/MyBooks/LocalBookContentServiceTests.swift` (A, C)
- `PalaceTests/MyBooks/LCPFulfillmentHandlerTests.swift` (B)
- `scripts/check-dependency-money-paths.sh` + `scripts/tests/` + docs (D)
- `Palace.xcodeproj/project.pbxproj` (build 490 → 491, new files both targets)

## Verification plan

- Unit + mutation on the changed decision points (in-flight guard, state
  transition, failure branches).
- Suites derived from the changed files rather than guessed.
- simdrive pass on the simulator against A1QA: single download per open, bar
  visible for the whole wait, Listen absent until the archive is on disk.
