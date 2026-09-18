---
name: lcp-prefetch-progress-noise
created: 2026-09-18
author: Maurice Carrier
branch: fix/lcp-prefetch-progress-noise
priority: 3.3.0 QA regression (build 505), audiobook critical path
---

# Intent: progress UI must describe a WAIT, not background work

## Context

QA on build 505: "After borrowing, I am presented with the Listen button, but
also a download progress bar. If I tap listen before download progress
completes, I get a loading screen."

Measured on device (Moes Max, build 505, A1QA Test Library) rather than reasoned
about. The gate log line is decisive:

    PP-5135: LCP content missing and streaming is ON — fetching the .lcpa
    in the background … without blocking this open

So the open does NOT wait for the archive. Tap-to-audio with the fetch in
flight: 5.45s (Snow Crash) and 6.29s (Dungeon Crawler Carl). The same book
re-opened once the `.lcpa` had landed: 0.88s. The `.lcpa` itself completed in
~12s on fast wifi; on a patron connection it is minutes.

The release owner's call: the loading screen is acceptable, the progress bar is
not. The bar is the defect because it advertises a transfer the patron does not
need to wait for, beside a Listen button that already works.

Two surfaces show waiting-UI for non-waiting work, and they have DIFFERENT
sources — which is why fixing one does not fix the other:

1. **Book detail half-sheet** — `HalfSheetProgressCue.resolve` returns
   `.downloading` on `isDownloadingLCPContent` unconditionally. That signal is
   the background `.lcpa` fetch.
2. **Audiobook player** — `downloadBar` gates on `presenter.isDownloading`,
   mirrored from the toolkit. For LCP that "download" is LOCAL DECRYPTION of
   tracks out of the `.lcpa` into caches (`LCPDownloadTask`), and
   `LCPStreamingPlayer` does not wait for it either. Confirmed in the recording:
   the bar read 37% then 62% AFTER the `.lcpa` had already been stored, while
   audio was playing.

The premise both surfaces were built on is dead. Their comments still assert it
("streaming is broken upstream", "must land in full before playback") — true
when written, false since PP-4957 shipped streaming at 100% and PP-5135 made the
archive fetch run alongside it.

## The leak (found while reproducing the above; larger than it)

Driving the reporter's Return repro on device turned up a data-retention defect
that the progress bar was the only visible trace of.

The fetch is fire-and-forget by construction: `LCPContentFulfilling` returns
`Void` and its task handle is discarded, so a Return CANNOT cancel an in-flight
transfer — `BookRegistrySync` documents the same thing ("cancel would report
success while the transfer kept running"). The return cleanup deletes the
content, and the transfer then completes and re-creates it.

MEASURED, not inferred. Moes Max, build 505, A1QA Test Library. Each on-disk
filename is SHA-256 of the book identifier, so the mapping is exact:

    d8fe7151…lcpa  0.48 GB  10:20  = sha256("urn:isbn:9781488207822")
                                     The Lost Book of Adana Moreau
    ec2af318…lcpa  1.07 GB  10:18  = sha256("urn:isbn:9780593684139")
                                     The Heaven & Earth Grocery Store

NEITHER identifier appears in that account's `registry.json` — both loans were
fully returned. 1.55 GB of DRM-protected audio for books the patron gave back.

The guard is at the WRITE rather than at the transfer deliberately: one check
covers return and expiry instead of racing each separately, and it needs no
cancellation machinery the fulfiller cannot support.

CORRECTED IN REVIEW — this was overclaimed. The write is NOT "the single point
where content comes into existence". `LCPFulfillmentHandler` reaches
`BackgroundDownloadHandler.replaceBook`, a second `.lcpa` producer with the same
fire-and-forget shape and no guard, reachable with LCP streaming OFF and always
for LCP PDF/EPUB. This change NARROWS the orphan window on the streaming path;
it does not close it everywhere. The sibling is named here rather than fixed,
because widening a release fix into a second producer is a bigger change than
this branch should carry.

A LIBRARY SWITCH IS ALSO NOT CLOSED, and deliberately so. `bookRegistry.state(for:)`
is current-account scoped, so after a switch it answers for a different library
and reports `.unregistered` for a book account A still holds — deleting on that
answer destroys up to a gigabyte the patron is entitled to. The guard therefore
writes when the account has moved. An earlier revision of this intent listed the
library switch as intentionally CLOSED; that was wrong in the dangerous
direction and was found in review.

## Claims

- **A.** The half-sheet shows no progress cue for an LCP content transfer once
  the book renders an open affordance. Decided by the pure
  `HalfSheetProgressCue.resolve`.
- **B.** Claim A covers `.used` as well as `.downloadSuccessful`. Both map to
  `.listen` in `BookButtonState.buttonTypes` and `.used` is independently
  reachable via `BookButtonMapper`, so a guard naming only `.downloadSuccessful`
  leaves the other arm drawing the bar.
- **C.** The waiting case is preserved. CORRECTED: the original wording said the
  book "has not resolved to an open affordance", which is false when LCP
  streaming is OFF — the archive is then required before playback while the
  button still reads `.downloadSuccessful`, and the allowlist alone answered
  `.idle`. `resolve` now takes `contentRequiredBeforePlayback` and a required
  transfer outranks the allowlist. `lcp_audiobook_streaming_enabled` DEFAULTS
  OFF and is the kill switch, so this is the common path, not an edge.
- **D.** The player shows its download bar only until playback has started for
  this session. Latched, not `isPlaying`, so a pause does not re-summon the bar.
- **E.** Both decisions are pure and enumerable, so a flipped conditional is
  caught mechanically rather than by reading.
- **F.** A completed `.lcpa` fetch is written to disk only while the patron
  still holds the book AND the library has not changed under it. Decided by the pure
  `LocalBookContentService.mayStoreFetchedContent(registryState:accountUnchanged:)`,
  consulted at
  the point where the archive would come into existence on THIS path (see the
  named sibling producer above — it is not the only one). On refusal the
  fetched file is DELETED, not merely left unmoved — skipping the move alone
  relocates the leak into the temp directory instead of closing it.
- **G.** A deallocated service, or one whose account has moved, takes the
  NON-DESTRUCTIVE arm and writes. Neither can vouch for the loan, and retention
  is recoverable where deletion is not.
- **H.** A borrow in flight still shows "Borrowing…". `BorrowOperation` sets the
  processing flag before `fetchBook` and moves the registry only after, so the
  button reads `.canBorrow` for the whole round trip; the allowlist admits that
  state when `isBorrowProcessing`. An earlier revision suppressed it and pinned
  the suppression with a test — found independently by all three reviewers.
- **I.** A book being returned shows no cue, checked FIRST and unconditionally,
  so the wait clause in Claim C cannot re-open the reported repro when streaming
  is off.

## Anti-claims

- **Does NOT change when the `.lcpa` is fetched, or whether it starts.**
  PP-5135's trigger, placement and wifi policy are untouched. What IS now
  changed is whether a COMPLETED fetch is written to disk — see Claim F. An
  earlier revision of this intent said "presentation only"; that stopped being
  true when the leak was found and is corrected rather than left standing.
- **Does NOT touch the loading screen.** The release owner explicitly accepted
  it. The determinate "Downloading…" inside the loading shell stays: there the
  patron IS waiting, which is exactly when a bar is the right answer.
- **Does NOT address the 5–6s streaming start.** Whether that is bandwidth
  contention with the new background fetch or inherent LCP stream start-up is
  NOT discriminated by this change and is not claimed. The clean test is the
  same title on a 504 build, where streaming existed and the fetch did not.
- **Does NOT change the My Books shelf cell.** Already correct —
  `NormalBookCell` gates on `stableButtonState == .downloadInProgress`, so a
  streaming book shows Listen with no bar. Verified, not assumed.
- **Does NOT touch the toolkit's own `AudiobookPlayerView`.** That is the
  submodule player behind `in_app_playback_nav_enabled = OFF`; a separate repo
  and a separate PR. Named here so its absence is deliberate, not overlooked.
- **Does NOT add an "available offline" indicator.** Replacing the bar with a
  quiet non-blocking affordance is the better long-term answer and is a design
  change with new strings and localization — larger than a release fix.

## Files in scope

- `Palace/Book/UI/BookDetail/HalfSheetview.swift` — the half-sheet cue
- `Palace/Audiobooks/AudiobookDownloadProgressPolicy.swift` — new pure policy
- `Palace/Audiobooks/AudiobookSessionPresenter.swift` — latched playback-started
- `Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift` — bar gate
- `PalaceTests/MyBooks/HalfSheetProgressCueTests.swift`
- `PalaceTests/ViewModels/BookDetailLCPContentProgressTests.swift`
- `PalaceTests/Audiobooks/AudiobookDownloadProgressPolicyTests.swift` — new
- `Palace/MyBooks/LocalBookContentService.swift` — the write guard (Claims F, G)
- `PalaceTests/MyBooks/LocalBookContentServiceTests.swift`
- `PalaceTests/Audiobooks/AudiobookSessionPresenterTests.swift`
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` — streaming-flag provider
- `Palace/AppInfrastructure/AppContainer.swift` — composition root: injects the
  archive-transfer edge + progress publishers and the seed query into
  `AudiobookSessionPresenter`. Added after blast-radius review noted this is
  precisely where the change's blast radius lives and it was absent here.
- `Palace.xcodeproj/project.pbxproj` — new files wired into both targets

## Verification plan

- RED before GREEN on every behavior change, recorded: the half-sheet change was
  13 tests / 3 failures before, 21 tests / 0 failures after.
- Mutation on the changed lines via `palace_mutate.py --diff-only`, mechanically
  derived. A run that reports `records NO measurement` is NOT a pass.
- Full suite via `verify-pr.sh --quick` before the PR. Scoped runs are spot
  checks and are never reported as the suite.
- Claims F/G proven by REINTRODUCING the defect, not by asserting green:
  deleting the write guard fails exactly
  `testFetchCompletingAfterTheBookIsReturned_doesNotWriteTheArchive` and
  `testFetchCompletingWhileTheBookIsReturning_doesNotWriteTheArchive`
  (36 tests, 2 failures), and NOTHING else. Restored byte-identical after.
  Note what stayed GREEN under the reintroduced defect:
  `testMayStoreFetchedContent_overTheWholeStateTable`. The leak was never a
  wrong rule — it was that no code path consulted one — so a pure-rule test
  alone would have passed over a live 1.55 GB leak. Only the wiring tests
  discriminate.
