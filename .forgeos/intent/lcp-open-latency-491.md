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

## Course correction (2026-07-30, after four review rounds)

Claim **B** was briefly split out and has been RESTORED, deliberately.

Splitting it produced an incoherent UI: with the book still marked
`.downloadSuccessful` during the content phase, the sheet showed a progress bar
next to a live "Listen" button. Reusing the ordinary download state means the
existing progress bar and Cancel affordance do the job, with no parallel cue for
the fresh-borrow path.

What changed on restore is HOW. Three review rounds each found that patching one
reconciliation arm broke a neighbouring one, because the invariant being retired
— "a file on disk means the book is playable" — was re-derived independently in
four arms, and `checkIfBookFileExists` reports true for an LCP audiobook holding
only its `.lcpl`. Rather than patch a fourth arm, the predicate itself is now
explicit (`ContentPresence`: absent / licenseOnly / present) and every arm
consumes it. The PP-3704 special case collapsed into the `.licenseOnly` branch
and was deleted rather than duplicated.

This is guarded by a reconciliation table test asserting convergence to a
fixpoint and, at every step of that settle, the safety property: no outcome
leaves a book claiming to be playable with its content absent and no recovery
scheduled. That property is the patron-visible defect stated directly, so it
survives future rewrites of the chain.

## Claims

- **A.** `redownloadLCPContentFile` becomes idempotent against concurrency: a
  lock-guarded in-flight claim keyed by book identifier, released on completion
  (success and failure), so a second caller during the download window no-ops
  instead of starting a duplicate transfer. The existing `fileExists` skip is
  retained. The LCP fulfillment call is injected so the guard is testable
  without a live LCP service, a license on disk, or a network fetch.
  Reworked after review: the claim expires on an IDLE window rather than a total
  duration (a total-duration window sized to the gate's 180s ceiling expired
  healthy transfers of every measured title, reintroducing the duplicate), is
  heartbeated from the progress callback, uses a monotonic clock, and is
  token-matched on release so a late completion cannot free a successor's slot.
- **B.** An LCP audiobook stays `.downloading` until its `.lcpa` is on disk;
  `markDownloadSuccessful` moves from the license-fulfilled point into the
  content-completion callback. The ordinary download progress bar and Cancel
  then cover the wait, and "Listen" is not offered for a book with no audio.
  Load-time reconciliation consumes a tri-state `ContentPresence` predicate so a
  license-only book is never promoted to a playable state, and a warm `load()`
  cannot flip a transfer that is still in flight.
- **C.** The background content re-download reports progress (previously
  discarded as `progress: { _ in }`) and an active/idle signal, which
  `BookDetailViewModel` and `BookCellModel` expose as `isDownloadingLCPContent`
  and `HalfSheetProgressCue.resolve` renders as the linear bar. This covers the
  SELF-HEAL path only — a book that is legitimately `.downloadSuccessful` and
  whose content went missing — because the fresh-borrow path is now carried by
  B's ordinary `.downloading` bar. `BookCellModel` tracks `observedProgress` for
  this case, scoped to it, because its `downloadProgress` reads `downloadInfo`,
  which the out-of-band transfer never populates.
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
- **Does NOT downgrade a book that already has playable content.** The
  content-failure guard tests the FILE rather than registry state, so a
  re-fetch failure for a book whose `.lcpa` is present leaves it alone.
- **Does NOT put the self-heal re-download into `.downloading`.** That state
  maps to `buttons = [.cancel]`, and the self-heal runs on an out-of-band
  session Cancel cannot reach, so it uses the dedicated signal instead.
- **Does NOT change the 180 s gate ceiling.** Flagged separately: a large archive
  on a slow connection can still exceed it and surface "Audiobook Unavailable".

## Files in scope

- `Palace/MyBooks/LocalBookContentService.swift` (A, C)
- `Palace/MyBooks/DownloadProgressPublisher.swift` (C)
- `Palace/MyBooks/MyBooksDownloadCenter.swift` (C wiring)
- `Palace/MyBooks/LCPFulfillmentHandler.swift` (C — the two content-phase
  emission points only; the state transition is unchanged from 490)
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` (C)
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` (C)
- `Palace/Book/UI/BookDetail/HalfSheetview.swift` (C)
- `PalaceTests/MyBooks/LocalBookContentServiceTests.swift` (A, C)
- `PalaceTests/MyBooks/LCPFulfillmentHandlerTests.swift` (B)
- `Palace/Book/Models/BookRegistrySync.swift` (B — the `ContentPresence` predicate and the arms that consume it)
- `PalaceTests/Book/BookRegistryReconciliationTableTests.swift` (B — table + properties)
- `scripts/check-dependency-money-paths.sh` + `scripts/tests/` + docs (D)
- `Palace.xcodeproj/project.pbxproj` (build 490 → 491, new files both targets)

## Verification plan

- Unit + mutation on the changed decision points (in-flight guard, state
  transition, failure branches).
- Suites derived from the changed files rather than guessed.
- simdrive pass on the simulator against A1QA: single download per open and no
  discarded transfer, bar visible for the whole wait.
  Result on build 491: 1 download started and 0 discarded, for the scenario that
  produced 2 and 1 on build 490; content landed and playback started.
