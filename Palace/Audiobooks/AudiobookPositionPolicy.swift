//
//  AudiobookPositionPolicy.swift
//  Palace
//
//  Pure-function policies for audiobook position state. Extracted so each
//  rule (is-at-beginning, raw-position validation, chapter-change detection,
//  TOC normalization) can be unit-tested without instantiating the
//  PalaceAudiobookToolkit Audiobook / TrackPosition / Chapter types — those
//  live in the submodule and aren't economical to wire up in unit tests.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging
// Exception to this file's toolkit-free rule: `ChapterNavigationPolicy` calls one
// pure String comparison (`positionUpdateIsForNavigationTarget`) so both players
// share a single copy of the navigation-hold rule (PP-5205).
import PalaceAudiobookToolkit

// MARK: - Beginning-position predicate

/// Decision: is the *incoming* (just-played-from-app) position effectively
/// "the very beginning of the book"?
///
/// Strict zero (`trackIndex == 0 && playbackTime == 0`), not a grace window: a
/// patron who paused at 0:25 of chapter 1 has real progress. Stale-overwrite
/// protection belongs to the timestamp check in `syncListeningPositionToServer`.
public enum BeginningPositionPolicy {

    /// Returns true when the position is at the absolute start: track index 0
    /// with playback time exactly 0. Any non-zero playback time on track 0 is
    /// treated as real progress.
    ///
    /// - Parameters:
    ///   - trackIndex: zero-based index of the current track within the manifest.
    ///   - playbackTime: elapsed seconds within the current track. May be any
    ///     finite double; negative values are treated as "not at beginning"
    ///     because they're nonsense and we don't want to suppress an overwrite
    ///     based on a malformed input.
    /// - Returns: `true` iff `trackIndex == 0 && playbackTime == 0`.
    public static func isAtBeginning(trackIndex: Int, playbackTime: TimeInterval) -> Bool {
        return trackIndex == 0 && playbackTime == 0
    }
}

// MARK: - Raw-position validator

/// Validation outcome for a candidate `TrackPosition` reconstructed from a
/// locally-saved bookmark. Each failure variant carries enough context for
/// the `[AUDIOPOS]` log line to be diagnostic without leaking PII.
public enum AudiobookPositionValidationFailure: Error, Equatable {
    /// `position.timestamp < 0` — never a real playback offset.
    case negativeTimestamp(TimeInterval)
    /// `position.timestamp.isNaN || .isInfinite` — corrupt serialized state.
    case nonFiniteTimestamp
    /// The saved `position.track.key` is not present in the manifest. Most
    /// common when the book's manifest URL changed across re-fulfillment
    /// (LCP refresh, distributor swap) and the registry's saved key is stale.
    case trackKeyNotInManifest(savedKey: String)
    /// The computed `positionDuration` exceeds `totalDuration * 1.1` — likely
    /// a stale position from a book that has since been re-cut shorter.
    case positionExceedsCap(positionDuration: TimeInterval, totalDuration: TimeInterval)
}

/// Decision: should we trust this reconstructed position?
///
/// The policy intentionally accepts `positionDuration == totalDuration`
/// (the end-of-book marker that the player itself produces on completion)
/// and `positionDuration <= totalDuration * 1.1` (a 10% slop for floating
/// point drift across manifest re-cuts). Anything beyond the 1.1× cap is
/// almost certainly stale — better to drop to start than seek past the end.
///
/// `totalDuration <= 0` is treated as a non-failing edge case: the manifest
/// didn't report a duration, so we can't validate against it. We return
/// success and let the player's own seek-guard handle out-of-range seeks.
public enum AudiobookPositionPolicy {

    /// The cap multiplier.
    public static let totalDurationCap: Double = 1.1

    /// Validates a raw-position 5-tuple. Returns `.success(())` when the
    /// position is acceptable; `.failure(reason)` otherwise.
    ///
    /// - Parameters:
    ///   - timestamp: the position's `timestamp` (seconds into the current track).
    ///   - positionDuration: the position's `durationToSelf()` — elapsed
    ///     audiobook seconds from the manifest start to this position.
    ///   - totalDuration: the manifest's total track duration.
    ///   - trackKeyMatchesManifest: did `tracks.track(forKey:)` succeed?
    ///   - savedTrackKey: the key the bookmark claimed; used only for logging
    ///     when `trackKeyMatchesManifest == false`.
    public static func validate(
        timestamp: TimeInterval,
        positionDuration: TimeInterval,
        totalDuration: TimeInterval,
        trackKeyMatchesManifest: Bool,
        savedTrackKey: String
    ) -> Result<Void, AudiobookPositionValidationFailure> {
        if !timestamp.isFinite {
            return .failure(.nonFiniteTimestamp)
        }
        if timestamp < 0 {
            return .failure(.negativeTimestamp(timestamp))
        }
        if !trackKeyMatchesManifest {
            return .failure(.trackKeyNotInManifest(savedKey: savedTrackKey))
        }
        if totalDuration > 0 && positionDuration > totalDuration * totalDurationCap {
            return .failure(.positionExceedsCap(
                positionDuration: positionDuration,
                totalDuration: totalDuration
            ))
        }
        return .success(())
    }
}

// MARK: - Chapter-change detector

/// Decision: when did the listener move into a different chapter?
///
/// Fires on a track-key change only. Comparing titles as well fired spuriously
/// on anthologies whose adjacent chapters share a title, and when the toolkit
/// briefly reports a different title for the same key during a seek.
public enum ChapterChangeDetector {

    /// Returns true when the new chapter represents a real crossing.
    public static func didChange(
        oldKey: String?,
        oldTitle: String?,
        newKey: String,
        newTitle: String
    ) -> Bool {
        // First-emit case: no prior chapter → fire.
        guard let oldKey else { return true }
        return oldKey != newKey
    }
}

// MARK: - TOC normalization

/// Decision: when the manifest's table of contents is densely populated with
/// subsections (e.g. 182 entries for a 56-chapter book), the UI risks
/// showing "Chapter 32 / Section 4 / paragraph 2" instead of just chapters.
///
/// Heuristic: when `tocCount > expectedChapterCount * inflationThreshold`,
/// we treat the TOC as oversubdivided. The actual collapsing happens at the
/// call site (it needs the toolkit's `Chapter` type); this helper just owns
/// the decision predicate so the threshold (1.5×) is testable.
///
/// Why 1.5×: observed oversubdivided manifests run ~3× (56 chapters, 182
/// entries), while legitimate ones sit near 1.1×.
public enum ChapterTOCNormalizer {

    /// Inflation multiplier above which a TOC is considered oversubdivided.
    public static let inflationThreshold: Double = 1.5

    /// Returns true when the TOC has more entries than
    /// `expectedChapterCount * 1.5`.
    ///
    /// - Parameters:
    ///   - tocCount: number of entries in the table-of-contents flat list.
    ///   - expectedChapterCount: the metadata-reported chapter count, or the
    ///     toolkit's track count as a stand-in. Must be > 0 to evaluate;
    ///     if 0, we can't compare and return false.
    public static func isOversubdivided(tocCount: Int, expectedChapterCount: Int) -> Bool {
        guard expectedChapterCount > 0 else { return false }
        return Double(tocCount) > Double(expectedChapterCount) * inflationThreshold
    }
}

// MARK: - Open-audiobook gate/teardown decision

/// Pure decision for the two policy questions the session manager answers
/// when re-entering playback:
///
///   * `persistFinalPositionOnTeardown` — when `openAudiobook` is called
///     while a prior session for the SAME book identifier is still active
///     (typical when a user returns + re-borrows + taps Listen), the
///     prior session's teardown must NOT save its live position to the
///     registry. Otherwise the stale offset gets written into the freshly-
///     borrowed registry record and the new open seeks there.
///     (HelpSpot 17988.)
///
///   * `bypassReadinessGate` — `LCPStreamingPlayer.isLoaded` only flips
///     to true once `AVPlayer.timeControlStatus == .playing`, which
///     requires `play()` to have been called. A pre-play readiness gate
///     therefore deadlocks LCP. The toolkit has its own internal 30s
///     load timeout that surfaces `.failed`, so the gate's hang-
///     detection role is already covered for LCP. Bypass on this path.
///     (HelpSpot 17981 / 17989 / 18002.)
public struct PlaybackOpenDecision: Equatable {
    public let bypassReadinessGate: Bool
    public let persistFinalPositionOnTeardown: Bool
}

public enum PlaybackOpenPolicy {
    /// - Parameters:
    ///   - isReBorrowOfSameBook: `currentBook?.identifier == book.identifier`
    ///     at the moment `openAudiobook` is entered. True implies the user
    ///     is re-opening the same book — possibly after a return + reborrow
    ///     cycle that the session manager has no other signal for.
    ///   - hasDecryptor: `loaded.decryptor != nil` on the freshly-loaded
    ///     audiobook. True implies LCP (via `LCPAdapter`); false implies
    ///     Findaway / Overdrive / OpenAccess / BearerToken.
    public static func decide(
        isReBorrowOfSameBook: Bool,
        hasDecryptor: Bool
    ) -> PlaybackOpenDecision {
        PlaybackOpenDecision(
            bypassReadinessGate: hasDecryptor,
            persistFinalPositionOnTeardown: !isReBorrowOfSameBook
        )
    }

    /// Production call-site adapter for the LCP-bypass decision: folds the
    /// `decryptor != nil` predicate into the decision so it is unit-testable.
    public static func decideForLoad(decryptor: AnyObject?) -> PlaybackOpenDecision {
        decide(isReBorrowOfSameBook: false, hasDecryptor: decryptor != nil)
    }
}

// MARK: - Position diagnostics logger

/// Logging seam for the audiobook position pipeline. Production binds to
/// `PalaceLogging.Log.warn(#file, ...)` which routes to Crashlytics in
/// release builds (see `Log.swift`). Tests bind a spy.
///
/// The `[AUDIOPOS]` grep marker mirrors the `[FCM_REG]` pattern from
/// `NotificationService.swift` — every line emitted via this logger has
/// the marker so support can grep the crashlog for one keyword and see
/// the full position-restoration story for the session.
public protocol AudiobookPositionLogging {
    /// Emits a `[AUDIOPOS] FAIL: <reason>` line at warn level.
    func logFailure(reason: String, context: [String: String])
    /// Emits a `[AUDIOPOS] FALLBACK: <reason>` line at warn level when a
    /// stale-but-usable bookmark is preferred over returning nil.
    func logFallback(reason: String, context: [String: String])
}

/// Default logger: `Log.warn` with the `[AUDIOPOS]` prefix and a context dump.
public struct DefaultAudiobookPositionLogger: AudiobookPositionLogging {
    public init() {}

    public func logFailure(reason: String, context: [String: String]) {
        Log.warn(#file, Self.format(prefix: "[AUDIOPOS] FAIL", reason: reason, context: context))
    }

    public func logFallback(reason: String, context: [String: String]) {
        Log.warn(#file, Self.format(prefix: "[AUDIOPOS] FALLBACK", reason: reason, context: context))
    }

    private static func format(prefix: String, reason: String, context: [String: String]) -> String {
        let ctxString = context
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        if ctxString.isEmpty {
            return "\(prefix): \(reason)"
        }
        return "\(prefix): \(reason) \(ctxString)"
    }
}


// MARK: - Chapter navigation (PP-5205)

/// How an EXPLICIT chapter selection interacts with the reactive chapter cache.
///
/// `AudiobookSessionManager.currentChapter` is written only from position
/// updates, so without this a chapter tap left the label on the previous chapter
/// until the seek settled, while the timecodes had already moved.
///
/// Two rules, deliberately separate, because the reactive and explicit paths want
/// opposite answers on the same input.
enum ChapterNavigationPolicy {

    /// What a reactive chapter update may do, given an in-flight explicit selection.
    enum ReactiveUpdate: Equatable {
        /// A position for some OTHER track while a selection is in flight — the old
        /// playhead still ticking. Change nothing, and keep holding.
        case ignore
        /// The selection landed on the chapter already displayed. Release the hold,
        /// publish nothing.
        case releaseHold
        /// Apply the new chapter and release any hold.
        case applyAndRelease
    }

    static func reactiveUpdate(
        navigationTargetTrackKey: String?,
        currentKey: String?,
        currentTitle: String?,
        newKey: String,
        newTitle: String
    ) -> ReactiveUpdate {
        guard AudiobookPlaybackModel.positionUpdateIsForNavigationTarget(
            incomingTrackKey: newKey,
            navigationTargetTrackKey: navigationTargetTrackKey
        ) else {
            return .ignore
        }
        return ChapterChangeDetector.didChange(
            oldKey: currentKey,
            oldTitle: currentTitle,
            newKey: newKey,
            newTitle: newTitle
        ) ? .applyAndRelease : .releaseHold
    }

    /// Whether tapping a table-of-contents row must publish a chapter change now.
    ///
    /// Deliberately NOT `ChapterChangeDetector.didChange`. That rule suppresses
    /// same-track / different-title pairs so an anthology does not announce a
    /// crossing mid-track — correct when the signal is a playhead drifting forward,
    /// and wrong here: the patron tapped a different row, and a label that does not
    /// move reads as a tap that did nothing.
    static func selectionNeedsImmediatePublish(
        currentKey: String?,
        currentTitle: String?,
        selectedKey: String,
        selectedTitle: String
    ) -> Bool {
        currentKey != selectedKey || currentTitle != selectedTitle
    }
}
