//
//  AudiobookMorphingPlayerViewTests.swift
//  PalaceTests
//
//  Unit coverage for the pure, mutation-testable seams of the custom morphing
//  audiobook player: the bookmark-error → localized-toast mapping (restores the
//  toolkit's `BookmarkError.localizedDescription`, which is module-internal and
//  unreachable from the app), the toast error/success classifier, the adaptive
//  control metrics (toolkit `controlPanelView` / `playbackControlsView` tiers),
//  and the rubber-band resistance curve for the interactive pull-down.
//
//  The SwiftUI body itself is opaque to XCTest; these static helpers carry the
//  logic that would otherwise hide inside it, so they are asserted directly.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceAudiobookToolkit
@testable import Palace

@MainActor
final class AudiobookMorphingPlayerViewTests: XCTestCase {

    typealias V = AudiobookMorphingPlayerView

    // MARK: - Bookmark error → localized toast (item 1)

    /// The two public `BookmarkError` cases map to the faithful app-side copy,
    /// NOT the raw `Error.localizedDescription` ("operation couldn't be
    /// completed"). Kills a switch-arm swap.
    func testBookmarkErrorMessage_mapsPublicCasesToLocalizedCopy() {
        XCTAssertEqual(V.bookmarkErrorMessage(for: BookmarkError.bookmarkAlreadyExists),
                       Strings.Generic.bookmarkAlreadyExists,
                       "`.bookmarkAlreadyExists` must map to the already-saved-here copy")
        XCTAssertEqual(V.bookmarkErrorMessage(for: BookmarkError.bookmarkFailedToSave),
                       Strings.Generic.bookmarkFailedToSave,
                       "`.bookmarkFailedToSave` must map to the couldn't-be-saved copy")
        // The two arms must be distinct — a mutation collapsing them is caught.
        XCTAssertNotEqual(V.bookmarkErrorMessage(for: BookmarkError.bookmarkAlreadyExists),
                          V.bookmarkErrorMessage(for: BookmarkError.bookmarkFailedToSave),
                          "The two BookmarkError cases must surface different copy")
    }

    /// Any non-`BookmarkError` failure falls back to the generic add-failed
    /// string — never the raw system description. Kills dropping the `default`.
    func testBookmarkErrorMessage_unknownErrorFallsBackToGeneric() {
        let foreign = NSError(domain: "Foo", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "operation couldn't be completed"])
        XCTAssertEqual(V.bookmarkErrorMessage(for: foreign),
                       Strings.Generic.bookmarkAddFailed,
                       "A non-BookmarkError must fall back to the generic add-failed string, not the raw description")
    }

    // MARK: - Toast error/success classifier

    /// The success string (bookmark added) is NOT an error; every failure copy —
    /// the generic plus the two mapped cases plus any 'error'-bearing string — IS.
    func testToastIsError_classifiesSuccessAndFailureCopy() {
        XCTAssertFalse(V.toastIsError(Strings.Generic.bookmarkAdded),
                       "Bookmark-added is a success toast → bookmark glyph, not error")
        XCTAssertTrue(V.toastIsError(Strings.Generic.bookmarkAddFailed),
                      "Generic add-failed is an error toast")
        XCTAssertTrue(V.toastIsError(Strings.Generic.bookmarkAlreadyExists),
                      "Already-exists is an error toast")
        XCTAssertTrue(V.toastIsError(Strings.Generic.bookmarkFailedToSave),
                      "Failed-to-save is an error toast")
        XCTAssertTrue(V.toastIsError("A playback Error occurred"),
                      "Any string containing 'error' (case-insensitive) is an error toast")
        XCTAssertFalse(V.toastIsError("Now playing"),
                       "An arbitrary non-error string is not an error toast")
    }

    // MARK: - Adaptive control metrics (item 2 — toolkit tier parity)

    /// Standard iPhone-portrait tier (width ≥ 370, not landscape) matches the
    /// toolkit `controlPanelView` + `playbackControlsView` "else" values exactly.
    func testControlMetrics_standardPortraitTier_matchesToolkit() {
        let m = V.ControlMetrics(width: 390, landscape: false)
        XCTAssertFalse(m.narrow)
        XCTAssertEqual(m.chipHeight, 40)
        XCTAssertEqual(m.fontSize, 15)
        XCTAssertEqual(m.iconSize, 19)
        XCTAssertEqual(m.chipPadH, 14)
        XCTAssertEqual(m.outerPadH, 20)
        XCTAssertEqual(m.chipSpacing, 12)
        XCTAssertEqual(m.transportSpacing, 40)
        XCTAssertEqual(m.transportHeight, 72)
    }

    /// Narrow tier (SE/Mini, width < 370) matches the toolkit narrow values.
    func testControlMetrics_narrowTier_matchesToolkit() {
        let m = V.ControlMetrics(width: 360, landscape: false)
        XCTAssertTrue(m.narrow)
        XCTAssertEqual(m.chipHeight, 34)
        XCTAssertEqual(m.fontSize, 12)
        XCTAssertEqual(m.iconSize, 15)
        XCTAssertEqual(m.chipPadH, 10)
        XCTAssertEqual(m.outerPadH, 12)
        XCTAssertEqual(m.chipSpacing, 6)
    }

    /// Landscape tier matches the toolkit landscape values and shrinks the
    /// transport row to spacing 25 / height 56.
    func testControlMetrics_landscapeTier_matchesToolkit() {
        let m = V.ControlMetrics(width: 800, landscape: true)
        XCTAssertEqual(m.chipHeight, 34)
        XCTAssertEqual(m.fontSize, 13)
        XCTAssertEqual(m.iconSize, 16)
        XCTAssertEqual(m.chipPadH, 12)
        XCTAssertEqual(m.outerPadH, 16)
        XCTAssertEqual(m.chipSpacing, 8)
        XCTAssertEqual(m.transportSpacing, 25)
        XCTAssertEqual(m.transportHeight, 56)
    }

    /// The narrow boundary is `< 370`: 369 is narrow, 370 is standard. Kills a
    /// `<` → `<=` mutation on the tier threshold.
    func testControlMetrics_narrowBoundary_isStrictlyLessThan370() {
        XCTAssertTrue(V.ControlMetrics(width: 369, landscape: false).narrow,
                      "369pt must be the narrow tier")
        XCTAssertFalse(V.ControlMetrics(width: 370, landscape: false).narrow,
                       "370pt must be the standard tier (kills `<` → `<=`)")
    }

    // MARK: - Rubber-band resistance (item 3)

    /// A non-upward (≥ 0) offset passes through unresisted — the pull-down tracks
    /// the finger 1:1 downward; only the upward direction is rubber-banded.
    func testRubberBand_nonUpwardOffsetPassesThrough() {
        XCTAssertEqual(V.rubberBand(0), 0, accuracy: 0.0001,
                       "Zero offset must pass through (guard boundary)")
        XCTAssertEqual(V.rubberBand(120), 120, accuracy: 0.0001,
                       "A downward (positive) offset is not rubber-banded")
    }

    /// An upward (negative) pull is resisted: the resulting magnitude is strictly
    /// smaller than the input, and the curve asymptotes toward the -72 limit
    /// without ever crossing it. Kills dropping the resistance or the clamp.
    func testRubberBand_upwardPullIsResistedAndClamped() {
        let small = V.rubberBand(-100)
        XCTAssertLessThan(small, 0, "Upward pull stays negative")
        XCTAssertGreaterThan(small, -100, "Resistance: |result| < |input| for a -100 pull")
        XCTAssertGreaterThan(small, -72, "Never past the -72 asymptote limit")

        // Deep pull approaches, but never crosses, the limit.
        let deep = V.rubberBand(-100_000)
        XCTAssertGreaterThan(deep, -72, "Asymptote: even a huge pull stays above -72")
        XCTAssertLessThan(deep, -70, "…but a huge pull gets close to the -72 limit")

        // Monotonic: a deeper pull yields a larger (more negative) magnitude.
        XCTAssertLessThan(V.rubberBand(-400), V.rubberBand(-100),
                          "Deeper upward pull must resist further (monotonic resistance)")
    }

    // MARK: - Loading overlay state decision (PP-4542 skeleton-occlusion fix)

    /// A loaded player shows no overlay — regardless of the other flags.
    func testLoadingOverlayState_loadedIsHidden() {
        XCTAssertEqual(
            V.loadingOverlayState(isLoaded: true, isDownloading: false, loadingTimedOut: false, hasStartedPlayback: false, forceSkeletons: false),
            .hidden,
            "A loaded, non-downloading player has no loading overlay")
        XCTAssertEqual(
            V.loadingOverlayState(isLoaded: true, isDownloading: true, loadingTimedOut: true, hasStartedPlayback: false, forceSkeletons: false),
            .hidden,
            "Once loaded, neither a lingering download flag nor a stale timeout resurrects the overlay")
    }

    /// The core fix: while content is downloading (and not yet loaded) the overlay
    /// is the DETERMINATE downloading state — NOT the opaque shimmer skeleton that
    /// previously occluded the progress bar and read as a hang. Downloading also
    /// wins over a fired 30s timeout, so a slow-but-healthy download never shows
    /// the load-error overlay. Kills a branch-reorder that checks `loadingTimedOut`
    /// (or falls through to `.skeleton`) before `isDownloading`.
    func testLoadingOverlayState_downloadingBeatsSkeletonAndTimeout() {
        XCTAssertEqual(
            V.loadingOverlayState(isLoaded: false, isDownloading: true, loadingTimedOut: false, hasStartedPlayback: false, forceSkeletons: false),
            .downloading,
            "An in-flight download shows the determinate downloading state, not the shimmer skeleton")
        XCTAssertEqual(
            V.loadingOverlayState(isLoaded: false, isDownloading: true, loadingTimedOut: true, hasStartedPlayback: false, forceSkeletons: false),
            .downloading,
            "A download in flight is healthy progress — it must win over a fired load timeout, never the error overlay")
    }

    /// A genuine load timeout (not loaded, NOT downloading, timer fired) surfaces
    /// the error+retry. Kills dropping the `loadingTimedOut` branch.
    func testLoadingOverlayState_timeoutWithoutDownloadIsLoadError() {
        XCTAssertEqual(
            V.loadingOverlayState(isLoaded: false, isDownloading: false, loadingTimedOut: true, hasStartedPlayback: false, forceSkeletons: false),
            .loadError,
            "A stalled, non-downloading load that fired the 30s timer shows the load-error overlay")
    }

    /// The transient load window (not loaded, not downloading, timer not yet
    /// fired) is the skeleton. The QA `forceSkeletons` override forces the
    /// skeleton even over a loaded/downloading player so it can be inspected.
    func testLoadingOverlayState_skeletonDefaultAndForceOverride() {
        XCTAssertEqual(
            V.loadingOverlayState(isLoaded: false, isDownloading: false, loadingTimedOut: false, hasStartedPlayback: false, forceSkeletons: false),
            .skeleton,
            "The brief pre-download load window is the shimmer skeleton")
        XCTAssertEqual(
            V.loadingOverlayState(isLoaded: true, isDownloading: true, loadingTimedOut: false, hasStartedPlayback: false, forceSkeletons: true),
            .skeleton,
            "forceSkeletons is the QA inspection override — it wins over every other flag")
    }

    /// The 30s load-error timer must be suppressed while a download is in flight:
    /// a healthy multi-minute content download is not a load failure. Only a
    /// not-loaded AND not-downloading state surfaces the timeout. This is what
    /// stops a >30s LCP `.lcpa` download from false-tripping the error overlay.
    func testShouldSurfaceLoadTimeout_onlyWhenNotLoadedAndNotDownloading() {
        XCTAssertTrue(V.shouldSurfaceLoadTimeout(isLoaded: false, isDownloading: false),
                      "A stalled, non-downloading load surfaces the timeout")
        XCTAssertFalse(V.shouldSurfaceLoadTimeout(isLoaded: false, isDownloading: true),
                       "A download in flight must NOT surface the load-error timeout")
        XCTAssertFalse(V.shouldSurfaceLoadTimeout(isLoaded: true, isDownloading: false),
                       "A loaded player has nothing to time out")
        XCTAssertFalse(V.shouldSurfaceLoadTimeout(isLoaded: true, isDownloading: true),
                       "A loaded player never surfaces the timeout")
    }

    // MARK: - Speed-chip rate sync (exit/return label mismatch)

    /// Once a manager is bound, the chip adopts the session's (restored,
    /// persisted) rate — regardless of the stale fallback. This is the fix for
    /// the speed label reading 1.0× after exit/return while audio plays faster.
    func testDisplayRate_boundAdoptsSessionRate() {
        XCTAssertEqual(
            V.displayRate(sessionRate: .doubleTime, isBound: true, fallback: .normalTime),
            .doubleTime,
            "A bound player must show the session's actual rate, not the stale chip fallback")
    }

    /// Pre-bind, the session rate is the meaningless 1.0× default (no player yet)
    /// — the chip must KEEP its fallback rather than be pinned to that default,
    /// so the bind-time re-sync can later show the real restored rate. Kills a
    /// mutation that swaps the ternary (would clobber the chip with 1.0×).
    func testDisplayRate_unboundKeepsFallback() {
        XCTAssertEqual(
            V.displayRate(sessionRate: .normalTime, isBound: false, fallback: .doubleTime),
            .doubleTime,
            "Pre-bind, the chip keeps its fallback — the default session rate must not overwrite it")
    }

    // MARK: - Timecode formatter (relocated when the dead mini-player view was removed)

    /// Pure `TimeInterval` -> "MM:SS" / "H:MM:SS" formatter, relocated onto the
    /// morphing player when the dead mini-player view was removed. Pins the
    /// format so a regression that changes the separator, drops the leading-zero
    /// pad, or removes the non-finite/negative guard fails here.
    func testFormatTime_returnsExpectedTimecodes() {
        XCTAssertEqual(V.formatTime(0), "0:00",
                       "Zero seconds must format as 0:00 (preserves leading zero on seconds)")
        XCTAssertEqual(V.formatTime(59), "0:59",
                       "59 seconds must format as 0:59")
        XCTAssertEqual(V.formatTime(60), "1:00",
                       "60 seconds must format as 1:00 - minute rollover")
        XCTAssertEqual(V.formatTime(125), "2:05",
                       "125 seconds must format as 2:05")
        XCTAssertEqual(V.formatTime(3600), "1:00:00",
                       "1 hour must format as 1:00:00 - hour rollover adds the H field")
        XCTAssertEqual(V.formatTime(3725), "1:02:05",
                       "1h 2m 5s must format as 1:02:05 - leading-zero pad on M field when hours present")
        XCTAssertEqual(V.formatTime(-1), "--:--",
                       "Negative inputs must format as --:-- (guard against malformed positions)")
        XCTAssertEqual(V.formatTime(.nan), "--:--",
                       "NaN must format as --:-- (guard against /0 in playbackProgress upstream)")
        XCTAssertEqual(V.formatTime(.infinity), "--:--",
                       "Infinity must format as --:-- (defensive against toolkit edge cases)")
    }

    // MARK: downloadingAccessibilityLabel

    /// The download overlay collapses its children for VoiceOver, so the label
    /// must fold in the book title/author — otherwise a blind patron hears only
    /// a bare percentage for the up-to-180s download. Asserts title AND author
    /// are both present (kills dropping either) and that the percentage leads.
    func testDownloadingAccessibilityLabel_foldsTitleAndAuthor() {
        let label = V.downloadingAccessibilityLabel(title: "The Hobbit", authors: "J.R.R. Tolkien", progress: 0.42)
        XCTAssertTrue(label.contains("42%"), "Progress percentage must lead the announcement: \(label)")
        XCTAssertTrue(label.contains("The Hobbit"), "Title must be announced so the patron knows what is downloading: \(label)")
        XCTAssertTrue(label.contains("J.R.R. Tolkien"), "Author must be announced: \(label)")
    }

    /// Missing/empty title or author must not emit a dangling separator or an
    /// empty segment — only the parts that exist are joined.
    func testDownloadingAccessibilityLabel_omitsMissingMetadata() {
        let noAuthor = V.downloadingAccessibilityLabel(title: "Dune", authors: nil, progress: 0.5)
        XCTAssertTrue(noAuthor.contains("Dune"), "Title present: \(noAuthor)")
        XCTAssertFalse(noAuthor.hasSuffix(". "), "No dangling separator when author is absent: \(noAuthor)")

        let bareEmpty = V.downloadingAccessibilityLabel(title: "", authors: "", progress: 0.0)
        XCTAssertTrue(bareEmpty.contains("0%"), "Percentage still announced with empty metadata: \(bareEmpty)")
        XCTAssertFalse(bareEmpty.contains(". ."), "Empty title/author must not produce empty joined segments: \(bareEmpty)")
    }

    /// Progress is clamped so a transiently out-of-range value from the toolkit
    /// never announces a nonsensical "-4%" or "142%".
    func testDownloadingAccessibilityLabel_clampsProgress() {
        XCTAssertTrue(V.downloadingAccessibilityLabel(title: "T", authors: nil, progress: -0.04).contains("0%"),
                      "Negative progress clamps to 0%")
        XCTAssertTrue(V.downloadingAccessibilityLabel(title: "T", authors: nil, progress: 1.42).contains("100%"),
                      "Over-unity progress clamps to 100%")
    }

    // MARK: - PP-4971 — whole-book remaining is wall-clock, not book time

    /// The baseline: at normal speed the figure is the book time unchanged, so
    /// the fix cannot be "always divide by something".
    func testWholeBookRemaining_atNormalSpeed_readsBookTime() {
        XCTAssertEqual(
            V.wholeBookRemainingText(bookTimeRemaining: 3600, rate: .normalTime),
            "1 hr 00 min remaining"
        )
    }

    /// The reported defect: a 2× listener was told the full book time remained.
    func testWholeBookRemaining_atDoubleSpeed_isHalved() {
        XCTAssertEqual(
            V.wholeBookRemainingText(bookTimeRemaining: 3600, rate: .doubleTime),
            "30 min remaining"
        )
    }

    /// Slower than normal has to move the other way — a sign error would pass a
    /// test that only ever checked speeds above 1×.
    func testWholeBookRemaining_belowNormalSpeed_takesLonger() {
        XCTAssertEqual(
            V.wholeBookRemainingText(bookTimeRemaining: 3600, rate: .threeQuartersTime),
            "1 hr 20 min remaining"
        )
    }

    /// Changing speed must change the answer at every step of the rail, not just
    /// at the presets — the whole point of PP-4518 was the 0.05× steps.
    func testWholeBookRemaining_everyRateOnTheRailProducesADistinctFigure() {
        // 10 hours of book: enough that adjacent 0.05x steps differ by minutes.
        let bookTime: TimeInterval = 36_000
        var seen = Set<String>()
        for rate in PlaybackRate.allCases {
            seen.insert(V.wholeBookRemainingText(bookTimeRemaining: bookTime, rate: rate))
        }
        XCTAssertEqual(
            seen.count, PlaybackRate.allCases.count,
            "Two speeds produced the same remaining figure — the rate is not reaching the calculation"
        )
    }

    /// A finished book reads zero however fast it was played.
    func testWholeBookRemaining_finishedBookIsZeroAtEverySpeed() {
        for rate in PlaybackRate.allCases {
            XCTAssertEqual(
                V.wholeBookRemainingText(bookTimeRemaining: 0, rate: rate),
                "0 min remaining",
                "rate \(rate.rawValue) did not report a finished book as zero"
            )
        }
    }

    /// The playhead can overrun the manifest duration, which used to be absorbed
    /// by a `max(0,)` at the call site. That clamp now lives in the shared rule,
    /// so a negative must still never surface as "-1 min remaining".
    func testWholeBookRemaining_overrunPlayheadDoesNotGoNegative() {
        XCTAssertEqual(
            V.wholeBookRemainingText(bookTimeRemaining: -120, rate: .normalTime),
            "0 min remaining"
        )
    }

    // MARK: - PP-5205: a mid-session track change must not take over the screen

    private typealias Overlay = V.LoadingOverlayState

    private func state(
        loaded: Bool, downloading: Bool, timedOut: Bool, started: Bool, force: Bool = false
    ) -> Overlay {
        V.loadingOverlayState(
            isLoaded: loaded, isDownloading: downloading,
            loadingTimedOut: timedOut, hasStartedPlayback: started, forceSkeletons: force
        )
    }

    /// THE REGRESSION. Selecting a later chapter is a cross-track seek, which
    /// `LCPStreamingPlayer:204` answers by dropping `isLoaded`. Before this fix that
    /// produced `.downloading` — a full-screen panel replacing a playing book.
    func testMidSessionTrackChange_doesNotTakeOverTheScreen() {
        XCTAssertEqual(
            state(loaded: false, downloading: true, timedOut: false, started: true),
            .awaitingReload,
            "A chapter seek on a book already playing must leave the player on screen. `.downloading` here is PP-5205: the patron sees a Downloading panel and hears the audio stop on a book they were listening to."
        )
    }

    /// The cell that must NOT change — the overlay exists for this window.
    func testPrePlayback_stillShowsTheDownloadingPanel() {
        XCTAssertEqual(
            state(loaded: false, downloading: true, timedOut: false, started: false),
            .downloading,
            "Before playback begins the patron IS blocked and waiting; a silent screen is what this state exists to prevent."
        )
    }

    /// The cell that separates this design from the one that returned `.hidden`.
    /// `loadingTimedOut` is only ever armed from a not-usable state's `.onAppear`, so
    /// `.hidden` would render EmptyView, never arm, and make `.loadError` unreachable
    /// for the whole session — a dead player behind working-looking chrome.
    func testStalledMidSessionPlayer_stillReachesTheLoadError() {
        XCTAssertEqual(
            state(loaded: false, downloading: false, timedOut: true, started: true),
            .loadError,
            "The latch suppresses the TAKEOVER, never the failure path. If this returns anything else, a genuinely dead mid-session player shows the patron no error and no Retry."
        )
    }

    func testTimeoutBeatsTheLatch_evenWhileDownloading() {
        XCTAssertEqual(
            state(loaded: false, downloading: true, timedOut: true, started: true),
            .loadError,
            "Mid-session a fired timeout outranks the latch — the latch suppresses the takeover, never the failure."
        )
    }

    /// The pre-playback rule this fix must NOT disturb: a healthy multi-minute
    /// download outranks the 30s timeout, so a slow download never shows an error.
    /// An earlier revision reordered the checks globally and broke exactly this.
    func testPrePlayback_downloadStillOutranksTheTimeout() {
        XCTAssertEqual(
            state(loaded: false, downloading: true, timedOut: true, started: false),
            .downloading,
            "Pre-playback, a download in flight is healthy progress — it must not surface as a load error."
        )
    }

    func testLoadedPlayer_showsNothing_regardlessOfSessionPhase() {
        for started in [true, false] {
            XCTAssertEqual(state(loaded: true, downloading: true, timedOut: true, started: started), .hidden)
        }
    }

    /// Full enumeration: 2^4 input combinations at `forceSkeletons: false`, plus the
    /// override. States x events, not sampled scenarios — CLAUDE.md's rule exists
    /// because the cell that ships is the one nobody sampled.
    func testLoadingOverlayState_fullTable() {
        var seen: [Overlay: Int] = [:]
        for loaded in [true, false] {
            for downloading in [true, false] {
                for timedOut in [true, false] {
                    for started in [true, false] {
                        let got = state(loaded: loaded, downloading: downloading, timedOut: timedOut, started: started)
                        let want: Overlay
                        if loaded { want = .hidden }
                        else if started { want = timedOut ? .loadError : .awaitingReload }
                        else if downloading { want = .downloading }
                        else if timedOut { want = .loadError }
                        else { want = .skeleton }
                        XCTAssertEqual(got, want,
                                       "cell (loaded:\(loaded) downloading:\(downloading) timedOut:\(timedOut) started:\(started))")
                        seen[got, default: 0] += 1
                    }
                }
            }
        }
        XCTAssertEqual(seen.count, 5, "every state must be reachable from some cell — an unreachable state is dead code pretending to be a guard: \(seen)")
        XCTAssertEqual(seen.values.reduce(0, +), 16)
    }

    func testForceSkeletonsOverridesEveryCell() {
        for loaded in [true, false] {
            for started in [true, false] {
                XCTAssertEqual(
                    state(loaded: loaded, downloading: true, timedOut: true, started: started, force: true),
                    .skeleton,
                    "the QA inspection override must win everywhere, or it cannot inspect the state it exists to inspect"
                )
            }
        }
    }

    /// The arming rule is what closes F1, so it is asserted rather than left inside a
    /// `.onChange` closure where nothing could reach it.
    func testArmingSet_awaitingReloadArmsTheTimer() {
        XCTAssertTrue(V.stateArmsLoadTimeout(.awaitingReload),
                      "F1: if `.awaitingReload` stops arming, `.loadError` becomes unreachable for the rest of the session and a dead player shows the patron nothing.")
        XCTAssertTrue(V.stateArmsLoadTimeout(.skeleton))
        XCTAssertTrue(V.stateArmsLoadTimeout(.downloading))
        XCTAssertFalse(V.stateArmsLoadTimeout(.hidden),
                       "a loaded player must CANCEL, not arm — otherwise a completed seek leaves a live timer that fires against healthy state")
        XCTAssertFalse(V.stateArmsLoadTimeout(.loadError),
                       "already surfaced; re-arming would stack a second error")
    }

    /// Every state is covered by the arming rule — a state added later without a
    /// decision here silently inherits `false` and takes its failure path with it.
    func testArmingSet_coversEveryState() {
        let all: [V.LoadingOverlayState] = [.hidden, .downloading, .loadError, .skeleton, .awaitingReload]
        let arming = all.filter(V.stateArmsLoadTimeout)
        XCTAssertEqual(Set(arming), Set([.skeleton, .downloading, .awaitingReload]),
                       "arming set changed — confirm the new membership is deliberate, because this is the rule that keeps `.loadError` reachable")
    }

}

// MARK: - PP-5205 — the chapter name and the timecodes share one observed source

/// The name between the two chapter timecodes now reads `progress.chapterTitle`,
/// the same observed object the timecodes read, so the three cannot disagree about
/// which chapter is displayed and cannot repaint on different ticks. It previously
/// read `AudiobookSessionManager.currentChapter` — a cache on an object this view
/// does not observe (`audiobookSession` is a plain `let`), written only from
/// position events, which during a seek have stopped.
///
/// Only the FALLBACK is a decision, and it is the one that can regress: inverting
/// it pins the book's title over every chapter name for the whole session.
@MainActor
final class AudiobookMorphingPlayerChapterTitleTests: XCTestCase {

    func testChapterDisplayTitle_prefersTheChapterName() {
        XCTAssertEqual(
            AudiobookMorphingPlayerView.chapterDisplayTitle(
                chapterTitle: "Chapter 42", bookTitle: "The Eye of the Bedlam Bride"
            ),
            "Chapter 42"
        )
    }

    func testChapterDisplayTitle_beforeTheFirstTick_showsTheBookTitle() {
        XCTAssertEqual(
            AudiobookMorphingPlayerView.chapterDisplayTitle(
                chapterTitle: "", bookTitle: "The Eye of the Bedlam Bride"
            ),
            "The Eye of the Bedlam Bride",
            "a blank row reads as a broken player, not as one still loading"
        )
    }

    func testChapterDisplayTitle_withNeither_isEmptyRatherThanPlaceholder() {
        XCTAssertEqual(
            AudiobookMorphingPlayerView.chapterDisplayTitle(chapterTitle: "", bookTitle: nil),
            ""
        )
    }
}
