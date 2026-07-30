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

## Scope change (2026-07-30, after three review rounds)

Claim **B** was removed from this branch and moved to
`feat/lcp-download-state-honesty` for the next release. Three SoD review rounds
each found that B's fix generated a new defect in code outside the diff, because
the invariant it retires ("license on disk implies playable") is denormalized
across roughly five sites and was being patched one arm at a time.

Archaeology settled the urgency: the early mark is byte-identical in 3.1.0
(`LCPFulfillmentHandler.swift:179-188`), and 3.1.0 pinned Readium 3.7.0, which
predates the PR #723 clamp removal that shipped in 3.8.0 — so in 3.1.0 the early
"Listen" was truthful because streaming worked. What regressed in 3.2.0 is
latency, not function, and CarPlay routes through the same gated `openAudiobook`
(`CarPlayAudiobookBridge.swift:151`), so it is not an unmitigated path. B fixes a
misleading label on pre-existing behaviour and is holdable.

B returns next release as what it actually is: a redefinition of the
license-only-means-playable predicate, verified by a reconciliation table test
run to fixpoint.

The patron-visible half of B is preserved here without it — see claim C.

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
- **B.** WITHDRAWN from this branch (see Scope change above). No registry state
  transition is altered here; `LCPFulfillmentHandler` is byte-identical to 490.
- **C.** The content re-download reports progress (previously discarded as
  `progress: { _ in }`) and an active/idle signal, which `BookDetailViewModel`
  and `BookCellModel` expose as `isDownloadingLCPContent` and
  `HalfSheetProgressCue.resolve` renders as the linear bar. Extended after the
  split to emit the same edge around the FRESH-BORROW content phase in
  `LCPFulfillmentHandler`, so the bar shows for that wait too without any state
  change — this is how the patron-visible half of B is preserved. Progress was
  already published by `lcpProgress` and `downloadInfo` already populated, so
  only the edge was missing. `BookCellModel` additionally tracks
  `observedProgress`, because its `downloadProgress` reads `downloadInfo`, which
  this out-of-band transfer never populates.
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
- **Does NOT change any registry state transition.** The fulfillment path's
  state behaviour, including the existing "streaming license intact" guard, is
  byte-identical to 490. That was claim B and it is withdrawn.
- **Does NOT stop "Listen" being offered before the audio is local.** That is
  pre-existing 3.1.0 behaviour and is B's job next release. The open-time gate
  continues to cover it: tapping Listen triggers the download and opens when it
  lands, now with a visible bar.
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
- `PalaceTests/MyBooks/LCPFulfillmentHandlerTests.swift` (C)
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
