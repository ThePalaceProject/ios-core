//
//  HalfSheetProgressCueTests.swift
//  PalaceTests
//
//  The half-sheet's progress cue decides whether a patron sees anything at all
//  while a book transfers. The question it answers is NOT "is a transfer
//  running" but "is the patron WAITING on one" — those diverged when LCP
//  streaming shipped.
//
//  History, because it reverses twice. While streaming was broken upstream
//  (readium/swift-toolkit#579) an LCP audiobook's entire `.lcpa` archive — well
//  over a gigabyte for some Audible-labelled Marketplace titles — had to land
//  before playback started, so choosing `.idle` during that window made the
//  sheet look inert and patrons backed out mid-download. That is why the cue
//  fires on `isDownloadingLCPContent` independently of book state.
//
//  PP-4957 turned streaming on (100% in production) and PP-5135 made the
//  `.lcpa` fetch actually run alongside it, so for a PLAYABLE book the archive
//  is now a background prefetch for offline use — the patron can listen the
//  instant Listen appears. Device trace, build 505: tap to audio was 5.45s and
//  6.29s with the fetch still in flight. Showing a determinate download bar
//  beside a working Listen button tells the patron to wait for something they
//  do not need, so that combination is now `.idle`.
//
//  The waiting case is unchanged and still pinned below: while the content is
//  required before playback the book is not yet playable, and the bar stays.
//
//  The decision is extracted from the SwiftUI body precisely so it can be
//  pinned here.
//

import XCTest
import PalaceBookModel
@testable import Palace

final class HalfSheetProgressCueTests: XCTestCase {

    // MARK: - Borrowing

    func testBorrowInFlightBeforeAnyBytes_showsBorrowingSpinner() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .downloading,
            buttonState: .downloadInProgress,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .borrowing,
                       "a borrow with no bytes yet must show the indeterminate spinner, not an inert 0% bar")
    }

    func testBorrowFlagSetButBytesFlowing_showsDeterminateBar() {
        // Once real progress arrives the determinate bar is more informative
        // than the spinner, even if the borrow flag has not cleared yet.
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0.1,
            bookState: .downloading,
            buttonState: .downloadInProgress,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .downloading)
    }

    // MARK: - Ordinary download

    func testDownloadingState_showsDeterminateBar() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.42,
            bookState: .downloading,
            buttonState: .downloadInProgress,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .downloading)
    }

    /// The `buttonState != .downloadSuccessful` clause: a book whose button has
    /// already resolved to "successful" is finished even if the registry state
    /// lags, and must not keep drawing a bar.
    func testDownloadingStateButButtonAlreadySuccessful_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 1.0,
            bookState: .downloading,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle)
    }

    // MARK: - LCP content re-download
    //
    // The case the `bookState` clause cannot reach: the book is legitimately
    // `.downloadSuccessful` from an earlier session and only its `.lcpa` went
    // missing, so a background content re-download is running against a book
    // that is not, by registry state, downloading.

    /// REVERSED by PP-4957 + PP-5135. `.downloadSuccessful` is the state that
    /// renders the Listen button, and with streaming on the book plays without
    /// its archive — so the transfer running behind it is a prefetch, not a
    /// wait. A determinate bar next to a working Listen button asks the patron
    /// to wait for something they do not need.
    func testLCPPrefetchWhileListenIsAvailable_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.3,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle,
                       "a background prefetch for a book that already plays must not draw a download bar beside Listen")
    }

    /// `.used` is the other button state that renders Listen (see
    /// `BookButtonState.buttonTypes`), so it must answer identically. Pinned
    /// separately because a guard written against `.downloadSuccessful` alone
    /// silently leaves this arm showing the bar.
    func testLCPPrefetchWhileUsedStateShowsListen_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.3,
            bookState: .downloadSuccessful,
            buttonState: .used,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle)
    }

    /// The waiting case, unchanged: content still required before playback, so
    /// the book is NOT yet playable and the bar is the only signal the patron
    /// has. This is the arm the original cue was written for; suppressing it
    /// would restore the silent wait patrons backed out of.
    func testLCPContentDownloadBeforeTheBookIsPlayable_stillShowsDeterminateBar() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.3,
            bookState: .downloadNeeded,
            buttonState: .downloadNeeded,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .downloading,
                       "while the archive is required before playback the patron IS waiting — the bar must stay")
    }

    func testLCPContentDownloadAtZeroProgressBeforePlayable_stillShowsBar() {
        // The bar must appear on the leading edge, before the first progress
        // sample lands, or there is a visible gap of nothing.
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0,
            bookState: .downloadNeeded,
            buttonState: .downloadNeeded,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .downloading)
    }

    func testLCPContentDownloadFinished_returnsToIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 1.0,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle,
                       "the cue must close when the transfer ends or the bar would hang at 100% forever")
    }

    /// This cell has now reversed TWICE, so both reversals are recorded.
    ///
    /// It first asserted `.borrowing`, assuming a processing borrow is the more
    /// urgent thing to tell the patron. A trace of a real Audible LCP borrow
    /// disproved that: the borrow stays "processing" for the entire archive
    /// fetch, so the ordering pinned the half-sheet on a motionless spinner for
    /// minutes and then jumped to "Listen". It became `.downloading`.
    ///
    /// It is now `.idle`. Both earlier answers assumed the patron was waiting on
    /// the archive; with streaming on they are not — `.downloadSuccessful` is
    /// already rendering Listen. Neither a spinner nor a bar belongs beside a
    /// button that works. The borrow flag is ignored here for the same reason it
    /// lost the first reversal: it stays set across the whole fetch and so says
    /// nothing about whether the patron can act.
    ///
    /// `.borrowing` still applies whenever no content transfer is running, and
    /// `.downloading` whenever the book is not yet playable — both pinned in the
    /// companion tests.
    func testContentTransferBesideAWorkingListenButton_isIdle_evenMidBorrow() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(
            cue, .idle,
            "the book already plays — neither the borrow spinner nor a download bar should appear beside Listen"
        )
    }

    // MARK: - The structural invariant
    //
    // Reported from device: returning to the half-sheet mid-transfer showed a
    // progress bar beside the Listen button ONCE, and did not reproduce. A
    // transient that cannot be re-run cannot be chased, so the rule is enforced
    // by construction instead: if the book renders an open affordance, NO cue
    // may fire, whatever the other inputs say. These pin the paths that were
    // still open after the LCP clause was added.

    /// `.used` + a registry state of `.downloading`. The old clause 3 guarded
    /// `buttonState != .downloadSuccessful` and did not name `.used`, so this
    /// returned `.downloading` — a bar beside Listen, reachable without the LCP
    /// flag being involved at all.
    func testUsedStateWithDownloadingRegistryState_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.5,
            bookState: .downloading,
            buttonState: .used,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle,
                       "`.used` renders Listen just as `.downloadSuccessful` does — a guard that names only one of them leaves this arm drawing the bar")
    }

    /// The borrow spinner had no open-affordance guard whatsoever. A borrow flag
    /// that has not cleared (it stays set across the whole archive fetch) plus a
    /// playable book put a spinner beside a working Listen button.
    func testBorrowStillProcessingButBookIsPlayable_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle,
                       "the borrow flag stays set across the fetch — it must not summon a spinner onto a book that already plays")
    }

    func testBorrowStillProcessingWithUsedState_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .downloadSuccessful,
            buttonState: .used,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle)
    }

    /// THE DEVICE REPRODUCTION (build 505, Moes Max): borrow, tap Listen as soon
    /// as it appears, enter the player, return to the detail view, tap Return —
    /// and a download bar appears. `.returning` is not an open affordance, so a
    /// guard written only against Listen-rendering states does not catch it,
    /// while the background `.lcpa` fetch is still in flight and clause 1 fires.
    ///
    /// A bar on a book the patron just gave back is never right, whatever is
    /// still transferring behind it.
    func testReturningWhileTheArchiveStillTransfers_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.4,
            bookState: .downloadSuccessful,
            buttonState: .returning,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle,
                       "the patron is giving the book back — a download bar on it is never the right answer")
    }

    // NOTE: a hand-listed `testNonAcquisitionStatesNeverShowACue_evenMidTransfer`
    // lived here. It enumerated "the cases someone remembered", which is exactly
    // the drift `testEveryButtonStateHasAPinnedCueVerdict` now closes by
    // DERIVING the bucket from `BookButtonState.allCases`. Keeping both would
    // give completeness two homes, one of which silently goes stale.

    /// The invariant stated directly, over every combination of the other four
    /// inputs. Enumerated rather than sampled: the transient above was reached
    /// by some combination nobody predicted, so the guarantee has to hold for
    /// ALL of them rather than for the ones we thought to write down.
    func testNoCueEverFiresForAButtonStateThatRendersAnOpenAffordance() {
        let openAffordances: [BookButtonState] = [.downloadSuccessful, .used]
        let bookStates: [TPPBookState] = [
            .downloading, .downloadSuccessful, .downloadNeeded, .used, .downloadFailed
        ]

        for buttonState in openAffordances {
            for bookState in bookStates {
                for isBorrowProcessing in [true, false] {
                    for isLCP in [true, false] {
                        for progress in [0.0, 0.5, 1.0] {
                            let cue = HalfSheetProgressCue.resolve(
                                isBorrowProcessing: isBorrowProcessing,
                                downloadProgress: progress,
                                bookState: bookState,
                                buttonState: buttonState,
                                isDownloadingLCPContent: isLCP,
                                contentRequiredBeforePlayback: false
                            )
                            XCTAssertEqual(
                                cue, .idle,
                                "a book rendering an open affordance must never show a progress cue — failed at buttonState=\(buttonState), bookState=\(bookState), borrowing=\(isBorrowProcessing), lcp=\(isLCP), progress=\(progress)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// REGRESSION GUARD. `BorrowOperation` sets the processing flag BEFORE
    /// `fetchBook` (30s ceiling on a slow distributor) and moves the registry
    /// only afterwards, so for the whole round trip the state is `.unregistered`
    /// and the button reads `.canBorrow`. This is the case
    /// `BookDetailViewModel`'s `isBorrowProcessing` seed exists for — a borrow
    /// kicked off from a swimlane, then navigated into.
    ///
    /// An earlier revision of the allowlist answered `.idle` here, which removed
    /// the only "Borrowing…" signal and re-opened the documented "borrow stuck
    /// with Cancel-only UI" defect. Found by three independent reviewers.
    func testBorrowInFlightWhileStillCanBorrow_showsBorrowingSpinner() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .unregistered,
            buttonState: .canBorrow,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .borrowing,
                       "a borrow in flight IS a wait to acquire — suppressing it is the 'stuck with Cancel-only UI' defect")
    }

    /// The other half: without a borrow in flight, `.canBorrow` is just a book
    /// on the shelf and must stay silent.
    func testCanBorrowWithNoBorrowInFlight_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0,
            bookState: .unregistered,
            buttonState: .canBorrow,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle)
    }

    // MARK: - The wait outranks the allowlist (LCP streaming OFF)
    //
    // `lcp_audiobook_streaming_enabled` DEFAULTS OFF and is the feature's kill
    // switch. With it off, `shouldTriggerContentDownloadBeforeOpen` blocks the
    // open until the archive lands while the book still reads
    // `.downloadSuccessful` — so the allowlist alone would restore exactly the
    // silent multi-gigabyte wait this cue was written to prevent.

    func testArchiveRequiredBeforePlayback_showsTheBarEvenForAPlayableButtonState() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.3,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: true
        )
        XCTAssertEqual(cue, .downloading,
                       "streaming OFF means the patron genuinely cannot play until this lands — the bar is the only signal")
    }

    /// The same inputs with streaming ON stay idle, so the flag is doing the
    /// work rather than the assertion being satisfiable either way.
    func testArchiveNotRequired_sameInputs_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.3,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle,
                       "streaming ON: the book already plays and the archive is a prefetch")
    }

    /// `.returning` while the archive is required: the patron is giving the book
    /// back, so even a genuine wait has nothing to wait FOR.
    func testReturningWhileArchiveRequired_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.3,
            bookState: .downloadSuccessful,
            buttonState: .returning,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: true
        )
        XCTAssertEqual(cue, .idle,
                       "a book being handed back shows nothing, streaming flag or not — otherwise the reported repro returns whenever streaming is off")
    }

    /// Streaming OFF with NO transfer running: the wait clause must not fire on
    /// the flag alone. Pins that `contentRequiredBeforePlayback` gates the
    /// TRANSFER rather than acting as a standalone switch.
    func testArchiveRequiredButNothingTransferring_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: true
        )
        XCTAssertEqual(cue, .idle,
                       "the flag alone is not a wait — there must actually be a transfer")
    }

    /// Streaming OFF + a borrow in flight + a content transfer. Two clauses can
    /// each claim this cell, so which wins is pinned rather than left to drift.
    func testArchiveRequiredDuringABorrow_theTransferWins() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .unregistered,
            buttonState: .canBorrow,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: true
        )
        XCTAssertEqual(cue, .downloading,
                       "a known transfer with a percentage outranks an indeterminate borrow spinner — the precedence the borrow clause already lost once, on device evidence")
    }

    /// Completeness over the whole enum, with the idle bucket DERIVED rather
    /// than hand-listed, so a new `BookButtonState` lands in an asserted bucket
    /// and must be deliberately moved out of it.
    ///
    /// Replaces a tautology. The previous version built a set by inserting every
    /// member of `allCases` and then asserted it equalled `Set(allCases)` —
    /// guaranteed by construction, killing zero mutants, while the real
    /// completeness claim still rested on a hand-written list. All three
    /// reviewers flagged it independently, and it was the sole justification
    /// offered for adding `CaseIterable` to a production enum. This version
    /// makes the conformance load-bearing: it asserts what `resolve` ANSWERS for
    /// every case, so a changed verdict fails and a new case fails.
    func testEveryButtonStateHasAPinnedCueVerdict() {
        // The states that represent a pending acquisition — a wait the patron
        // can do nothing about but watch.
        let mayShowCue: Set<BookButtonState> = [.downloadInProgress, .downloadNeeded]
        // `.canBorrow` depends on whether a borrow is actually in flight, so it
        // is asserted separately below rather than bucketed.
        let conditional: Set<BookButtonState> = [.canBorrow]
        let mustBeIdle = Set(BookButtonState.allCases)
            .subtracting(mayShowCue)
            .subtracting(conditional)

        for state in mayShowCue {
            XCTAssertEqual(
                HalfSheetProgressCue.resolve(
                    isBorrowProcessing: false,
                    downloadProgress: 0.4,
                    bookState: .downloading,
                    buttonState: state,
                    isDownloadingLCPContent: true,
                    contentRequiredBeforePlayback: false
                ),
                .downloading,
                "\(state) is a pending acquisition — the patron is waiting and the bar is their only signal"
            )
        }

        for state in mustBeIdle {
            XCTAssertEqual(
                HalfSheetProgressCue.resolve(
                    isBorrowProcessing: false,
                    downloadProgress: 0.4,
                    bookState: .downloading,
                    buttonState: state,
                    isDownloadingLCPContent: true,
                    contentRequiredBeforePlayback: false
                ),
                .idle,
                "\(state) is not a wait the patron is in — a cue here points at work they are not blocked on. If a new case belongs in mayShowCue, move it there deliberately."
            )
        }

        // The conditional cell, both ways.
        XCTAssertEqual(
            HalfSheetProgressCue.resolve(
                isBorrowProcessing: false, downloadProgress: 0, bookState: .unregistered,
                buttonState: .canBorrow, isDownloadingLCPContent: true,
                contentRequiredBeforePlayback: false
            ),
            .idle,
            "a book merely available to borrow is not a wait"
        )
        XCTAssertEqual(
            HalfSheetProgressCue.resolve(
                isBorrowProcessing: true, downloadProgress: 0, bookState: .unregistered,
                buttonState: .canBorrow, isDownloadingLCPContent: false,
                contentRequiredBeforePlayback: false
            ),
            .borrowing,
            "a borrow in flight IS a wait — this is the regression three reviewers caught"
        )
    }

    // MARK: - Idle

    func testNothingInFlight_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )
        XCTAssertEqual(cue, .idle)
    }

    // MARK: - Precedence over the borrow spinner
    //
    // Reproduces the patron-visible complaint from the 3.2.3 trace: borrowing an
    // Audible LCP title left the half-sheet on a motionless spinner for the whole
    // multi-minute archive fetch, then jumped straight to "Listen".

    func testContentDownload_outranksTheBorrowSpinner() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .downloadNeeded,
            buttonState: .downloadNeeded,
            isDownloadingLCPContent: true,
            contentRequiredBeforePlayback: false
        )

        XCTAssertEqual(
            cue, .downloading,
            "borrow stays 'processing' across the whole .lcpa fetch and that fetch reports 0 until its first byte — checking the spinner first pins the sheet on 'borrowing' for the entire download"
        )
    }

    func testBorrowSpinner_stillShowsWhenNoContentDownloadIsRunning() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .downloadNeeded,
            buttonState: .downloadNeeded,
            isDownloadingLCPContent: false,
            contentRequiredBeforePlayback: false
        )

        XCTAssertEqual(cue, .borrowing,
                       "an ordinary borrow with no content transfer must still show the borrow cue")
    }
}
