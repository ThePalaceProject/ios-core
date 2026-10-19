//
//  AudiobookLoadingOverlayState.swift
//  Palace
//
//  The loading overlay's state machine: which of the four presentations the
//  player shows before it is usable, and which of them arm the load timeout.
//  Pure statics over explicit inputs so the table can be asserted — an earlier
//  revision's arming rule lived inside a `.onChange` closure and could not be
//  enumerated at all.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation

extension AudiobookMorphingPlayerView {

    /// The four mutually-exclusive presentations of the loading overlay. Pulled
    /// out of `loadingOverlay`'s inline branching so the decision is a pure,
    /// unit-testable function (`loadingOverlayState`) instead of a tangle of
    /// view-side `if`s — matching the `nonisolated static` predicate pattern used
    /// across the audiobook session code.
    enum LoadingOverlayState: Equatable, CaseIterable {
        /// Player is loaded — no overlay.
        case hidden
        /// Content is still downloading (the pre-bind PP-4542 `.lcpa` wait, or a
        /// post-bind track download). Show a determinate "Downloading… NN%" state
        /// — NOT the shimmer skeleton (which is opaque and occluded the download
        /// bar, so a healthy multi-minute download read as a hang) and NOT the
        /// load-error overlay (a download in flight is not a load failure).
        case downloading
        /// The 30s load timeout fired while the player was neither loaded nor
        /// downloading — surface the error + retry.
        case loadError
        /// Brief "materializing" shimmer for the load window before we know
        /// whether content is downloading (or the toolkit is buffering a
        /// locally-present book). Also the QA `forceSkeletons` inspection state.
        case skeleton
        /// PP-5205: mid-session the player is momentarily not loaded — a cross-track
        /// seek, or iOS evicting the AVPlayer buffer on backgrounding. Draw NOTHING:
        /// the player underneath keeps its transport controls live. The load timer is
        /// still armed, so a genuine stall reaches `.loadError`.
        ///
        /// No spinner, deliberately. One was tried on-device and read as unexplained
        /// chrome beside working controls — it cannot say what it is waiting for, and
        /// for a downloaded book the honest answer ("re-queueing this track from
        /// streaming to local") is not something to put in front of a patron. If the
        /// wait is long enough to need explaining, that is the toolkit's lazy requeue
        /// to fix, not a spinner to add.
        case awaitingReload
    }

    /// Pure decision for which loading presentation to show. Kept free of view
    /// state so it can be unit-tested for every combination.
    ///
    /// `forceSkeletons` (the PP-4797 QA override, a compile-time `false` in
    /// release) always wins so the skeleton can be inspected on the sim — the
    /// real `!isLoaded` window is shorter than simdrive's observe latency.
    /// Otherwise: a loaded player shows nothing; an in-flight download shows the
    /// determinate downloading state (BEFORE the load-error check, so a slow
    /// download never trips the 30s error); a timed-out non-downloading load
    /// shows the error; everything else is the transient skeleton.
    /// PP-5205: `hasStartedPlayback` has NO default. A `= false` would let the call
    /// site compile unchanged and silently preserve the defect.
    ///
    /// Once playback has begun in this session, `isLoaded == false` means "changing
    /// tracks" or "buffer evicted", NOT "no player yet" —
    /// `LCPStreamingPlayer.play(at:)` drops it on every cross-track seek (`:204`,
    /// "Only show loading state for heavy operations"), and
    /// `AudiobookSessionPresenter:601` records iOS doing the same on backgrounding.
    /// Taking over the screen there replaced a playing book with a Downloading
    /// panel and read as though the audio had broken.
    ///
    /// Latched, not live: `isPlaying` would re-summon the takeover on every pause —
    /// the same mistake `AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar`
    /// documents one layer down and already avoids.
    ///
    /// `.awaitingReload` rather than `.hidden` is load-bearing. `loadingTimedOut` is
    /// armed only while the overlay state is a not-usable one, so returning `.hidden`
    /// would render `EmptyView`, never arm the timer, and make `.loadError`
    /// UNREACHABLE for the rest of the session — a dead player behind working-looking
    /// chrome, with no error and no Retry. The latch suppresses the takeover; it must
    /// never suppress the failure path.
    nonisolated static func loadingOverlayState(
        isLoaded: Bool,
        isDownloading: Bool,
        loadingTimedOut: Bool,
        hasStartedPlayback: Bool,
        expectsSlowStart: Bool,
        hasSeenDownloading: Bool,
        transportIsWaitingForData: Bool = false,
        forceSkeletons: Bool
    ) -> LoadingOverlayState {
        if forceSkeletons { return .skeleton }

        // MID-SESSION. Never take over the screen — but a genuine stall must still
        // reach the error, or the latch would hide the failure as well as the
        // takeover. Kept as its own branch rather than a reordering: an earlier
        // revision moved the timeout check above `isDownloading` globally and broke
        // the pre-playback rule that a healthy multi-minute download must not trip
        // the 30s error. `testLoadingOverlayState_downloadingBeatsSkeletonAndTimeout`
        // caught it.
        if hasStartedPlayback {
            guard !isLoaded else { return .hidden }
            return loadingTimedOut ? .loadError : .awaitingReload
        }

        // FIRST open. `isLoaded` is not "audio is coming out": several writers
        // in the streaming player set it to release the UI rather than because
        // a byte played, so hiding on it alone shows transport controls over
        // silence. `isWaitingForData` is AVFoundation's own answer
        // (`timeControlStatus == .waitingToPlayAtSpecifiedRate`), and the gap
        // between the two is the wait the patron sits through. Measured on
        // device 2026-10-19: 4.5 s to first byte, 5.4 s to audible.
        //
        // `.skeleton` rather than `.downloading`: the explanation has already
        // had its turn by now, and returning to it after the shimmer reads as
        // going backwards. `.skeleton` also arms the load timeout, so a start
        // that never becomes audible still reaches `.loadError`.
        if isLoaded {
            guard transportIsWaitingForData else { return .hidden }
            return loadingTimedOut ? .loadError : .skeleton
        }

        // PRE-PLAYBACK. The patron is genuinely blocked here, and a download in
        // flight is healthy progress that outranks the timeout.
        if isDownloading { return .downloading }
        if loadingTimedOut { return .loadError }

        // Before the download registers, `isDownloading` is still false, so a
        // start that the player already knows will be slow fell through to the
        // shimmer and was replaced about a tenth of a second later. Measured on
        // device 2026-10-19: one frame of skeleton, then 1.3 s of "Downloading
        // 0%". The explanation comes first, and the shimmer becomes what it
        // says it is — the brief hand-over before the player is usable.
        //
        // `hasSeenDownloading` ends it: once a download has been observed, this
        // window is over and the shimmer covers the remaining gap.
        if expectsSlowStart && !hasSeenDownloading { return .downloading }

        return .skeleton
    }

    /// Which states arm the load-error timer: the ones meaning "the player is not
    /// usable yet". Pure so the table can assert it — an arming rule that lives only
    /// inside a `.onChange` closure cannot be enumerated, and the cell that matters
    /// (`.awaitingReload` DOES arm) is the one that closes PP-5205's F1 hole.
    /// The download-seen latch: once true it stays true.
    ///
    /// One-way on purpose. A live `isDownloading` would re-open the
    /// pre-download window every time progress briefly reports nothing, which
    /// takes the screen back from the shimmer — the flicker the window exists
    /// to avoid. Expressed here rather than inside the view's `.onChange` so
    /// the one-way-ness can be asserted; an arming rule that lives only in a
    /// closure cannot be enumerated, which is what this file's header records.
    nonisolated static func hasSeenDownloading(previous: Bool, isDownloading: Bool) -> Bool {
        previous || isDownloading
    }

    /// Whether the download bar draws a fraction or just shows motion.
    ///
    /// A streamed open reports nothing for about a second before the first
    /// fraction arrives, and a determinate bar pinned at zero reads as a
    /// stalled download rather than one that has not started reporting yet.
    /// Non-positive covers the negative case too: the fraction comes from the
    /// download center and nothing promises it is in range.
    nonisolated static func downloadBarIsDeterminate(progress: Float) -> Bool {
        progress > 0
    }

    /// Which states arm the load-error timer: the ones meaning "the player is not
    /// usable yet". Pure so the table can assert it — an arming rule that lives only
    /// inside a `.onChange` closure cannot be enumerated, and the cell that matters
    /// (`.awaitingReload` DOES arm) is the one that closes PP-5205's F1 hole.
    nonisolated static func stateArmsLoadTimeout(_ state: LoadingOverlayState) -> Bool {
        loadTimeoutAction(for: state) == .arm
    }

    /// What reaching `state` must do to the load-error timer and its latch.
    ///
    /// One total function rather than two predicates consulted in sequence, so
    /// how timer and latch combine is exhaustive at compile time and a new
    /// overlay state is a build error rather than an inherited default.
    enum LoadTimeoutAction: Equatable { case arm, cancel, cancelAndClearLatch }

    nonisolated static func loadTimeoutAction(for state: LoadingOverlayState) -> LoadTimeoutAction {
        switch state {
        // Not usable yet: arm. `armLoadTimeout` resets the latch itself.
        case .skeleton, .downloading, .awaitingReload:
            return .arm
        // The player became usable, so a latched failure is genuinely over.
        case .hidden:
            return .cancelAndClearLatch
        // Cancel, but KEEP the latch — clearing here would flicker the error off the
        // frame it appeared on.
        case .loadError:
            return .cancel
        }
    }

}
