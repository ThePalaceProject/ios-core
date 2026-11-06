//
//  AudiobookPlayerProgressLeaves.swift
//  Palace
//
//  The parts of the audiobook player that follow the playback tick (four times
//  a second). Each observes `AudiobookPlaybackProgress` itself, so a tick
//  re-evaluates these views and not the whole player (PP-5505).
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import PalaceAudiobookToolkit
import SwiftUI

/// The values the progress views show, pure so each rule can fail a test.
@MainActor
enum AudiobookPlayerProgressText {

    /// Chapter-relative progress clamped to 0…1; drives the scrubber so its thumb
    /// matches `seekWithSlider`'s chapter scale.
    static func clampedChapterProgress(_ chapterProgress: Double) -> Double {
        chapterProgress.isFinite ? min(max(chapterProgress, 0), 1) : 0
    }

    /// Length of the current chapter in seconds (elapsed + remaining).
    static func chapterDuration(offset: TimeInterval, timeLeft: TimeInterval) -> TimeInterval {
        max(0, offset) + max(0, timeLeft)
    }

    /// Chapter elapsed timecode; mirrors toolkit `playheadOffsetText`.
    static func elapsedText(offset: TimeInterval) -> String {
        AudiobookMorphingPlayerView.formatTime(offset)
    }

    /// Chapter time-left timecode; mirrors toolkit `timeLeftText`.
    static func remainingText(timeLeft: TimeInterval) -> String {
        "-" + AudiobookMorphingPlayerView.formatTime(max(0, timeLeft))
    }

    /// Spoken value for the seek slider at chapter fraction `fraction`: percent
    /// through the chapter plus the chapter elapsed timecode. At the live
    /// position it reads the live timecode; after a VoiceOver step it reads the
    /// step's target, so the value matches where the seek is going before
    /// playback catches up. Until the chapter length is known it reads the
    /// percentage alone.
    static func seekAccessibilityValue(
        fraction: Double,
        liveFraction: Double,
        chapterDuration: TimeInterval,
        liveElapsed: String
    ) -> String {
        let percent = "\(Int(fraction * 100))%"
        guard chapterDuration > 0 else { return percent }
        let elapsed = abs(fraction - liveFraction) < 0.000_001
            ? liveElapsed
            : AudiobookMorphingPlayerView.formatTime((fraction * chapterDuration).rounded())
        return "\(percent), \(elapsed)"
    }

    /// Whole-book remaining ("18 hr 06 min remaining"), straight from the
    /// playhead rather than from a progress fraction: the scrubber is chapter
    /// scoped, so `total * fraction` would leap whenever it moved.
    static func wholeBookRemaining(position: TrackPosition?, rate: PlaybackRate) -> String {
        guard let position else { return "" }
        let bookTimeRemaining = position.tracks.totalDuration - position.durationToSelf()
        return AudiobookMorphingPlayerView.wholeBookRemainingText(bookTimeRemaining: bookTimeRemaining, rate: rate)
    }
}

/// Scrubber with the chapter title between the elapsed and remaining timecodes.
struct AudiobookPlayerSeekBar: View {
    @ObservedObject var progress: AudiobookPlaybackProgress
    let audioWaitPhase: AudiobookMorphingPlayerView.AudioWaitPhase
    let bookTitle: String?
    let forwardStepSeconds: Int
    let backStepSeconds: Int
    let onSeek: (Double) -> Void

    private var chapterProgress: Double {
        AudiobookPlayerProgressText.clampedChapterProgress(progress.chapterProgress)
    }

    private var chapterDuration: TimeInterval {
        AudiobookPlayerProgressText.chapterDuration(offset: progress.chapterOffset, timeLeft: progress.chapterTimeLeft)
    }

    private var elapsed: String { AudiobookPlayerProgressText.elapsedText(offset: progress.chapterOffset) }
    private var remaining: String { AudiobookPlayerProgressText.remainingText(timeLeft: progress.chapterTimeLeft) }

    /// The name and the timecodes read the same object, so they cannot show
    /// different chapters after a chapter selection (PP-5205).
    private var chapterTitle: String {
        AudiobookMorphingPlayerView.chapterDisplayTitle(chapterTitle: progress.chapterTitle, bookTitle: bookTitle)
    }

    var body: some View {
        VStack(spacing: 4) {
            PalaceSeekSliderView(
                value: Binding(
                    // Chapter-relative, to match the chapter-scoped seek. The
                    // `set` is a no-op: the seek commits via `onChange` and the
                    // slider holds the thumb while dragging.
                    get: { chapterProgress },
                    set: { _ in }
                ),
                onChange: onSeek,
                // PP-5280: VoiceOver swipes step by the patron's skip intervals.
                chapterDuration: chapterDuration,
                forwardStepSeconds: forwardStepSeconds,
                backStepSeconds: backStepSeconds,
                spokenValue: {
                    AudiobookPlayerProgressText.seekAccessibilityValue(
                        fraction: $0,
                        liveFraction: chapterProgress,
                        chapterDuration: chapterDuration,
                        liveElapsed: elapsed
                    )
                }
            )
            .accessibilityLabel(Strings.Generic.playbackPosition)
            // The title is centered in the full row width so it stays put as the
            // flanking timecodes change width; the times pin to the edges.
            ZStack {
                // Dimmed while the chapter it names is not yet playing; on a long
                // wait it says so instead (PP-5399).
                Text(audioWaitPhase == .slow ? Strings.Generic.audiobookLoading : chapterTitle)
                    .font(.subheadline).fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 64)
                    .opacity(audioWaitPhase == .none ? 1 : 0.5)
                HStack(spacing: 8) {
                    Text(elapsed)
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityLabel(Strings.Generic.timeElapsedLabel(elapsed))
                    Spacer(minLength: 8)
                    Text(remaining)
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityLabel(Strings.Generic.timeRemainingLabel(remaining))
                }
            }
        }
    }
}

/// "N min remaining" under the title, at the patron's speed (PP-4971).
struct AudiobookPlayerBookRemainingText: View {
    @ObservedObject var progress: AudiobookPlaybackProgress
    let rate: PlaybackRate

    var body: some View {
        let remaining = AudiobookPlayerProgressText.wholeBookRemaining(position: progress.currentLocation, rate: rate)
        if !remaining.isEmpty {
            Text(remaining)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, 2)
        }
    }
}

/// The sleep control's moon and countdown. The countdown is read off the
/// session, which does not publish it, so it is refreshed by the playback tick.
struct AudiobookPlayerSleepTimerLabel: View {
    @ObservedObject var progress: AudiobookPlaybackProgress
    let session: AudiobookSessionManaging
    let metrics: AudiobookMorphingPlayerView.ControlMetrics
    let glyph: CGFloat
    let diameter: CGFloat
    let background: Color

    var body: some View {
        let isActive = session.sleepTimerIsActive
        HStack(spacing: metrics.narrow ? 4 : 6) {
            AudiobookMorphingPlayerView.abGlyph(AudiobookMorphingPlayerView.icSleep, size: glyph)
            if isActive {
                // accesslint:disable A11Y.SWIFTUI.FIXED_FONT - countdown inside the same fixed-height capsule as the row's other controls
                Text(AudiobookMorphingPlayerView.formatTime(session.sleepTimerRemaining))
                    .font(.system(size: metrics.fontSize, weight: .medium, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.6)
                // accesslint:enable A11Y.SWIFTUI.FIXED_FONT
            }
        }
        .padding(.horizontal, isActive ? metrics.chipPadH : 0)
        .frame(width: isActive ? nil : diameter, height: diameter)
        .background(background)
        .clipShape(Capsule())
        .contentShape(Capsule())
    }
}

/// Session state the player shows but the session does not publish.
struct AudiobookPlayerSessionPoll: Equatable {
    let isLoaded: Bool
    let transportIsWaitingForData: Bool
    let expectsSlowChapterStart: Bool

    @MainActor
    init(_ session: AudiobookSessionManaging) {
        isLoaded = session.isLoaded
        transportIsWaitingForData = session.transportIsWaitingForData
        expectsSlowChapterStart = session.expectsSlowChapterStart
    }

    init(isLoaded: Bool, transportIsWaitingForData: Bool, expectsSlowChapterStart: Bool) {
        self.isLoaded = isLoaded
        self.transportIsWaitingForData = transportIsWaitingForData
        self.expectsSlowChapterStart = expectsSlowChapterStart
    }
}

/// Re-reads the unpublished session state on each playback tick and reports
/// it only when it changes, so the loading overlay still follows `isLoaded`
/// without the player root observing the tick. Draws nothing.
struct AudiobookPlayerSessionPollWatcher: View {
    @ObservedObject var progress: AudiobookPlaybackProgress
    let read: () -> AudiobookPlayerSessionPoll
    let onChange: (AudiobookPlayerSessionPoll) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Any write to `progress` re-evaluates this body, which re-reads the session.
            .onChange(of: read()) { _, polled in onChange(polled) }
    }
}
