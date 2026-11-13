//
//  PalaceSeekSliderView.swift
//  Palace
//
//  The audiobook seek scrubber used by `AudiobookMorphingPlayerView`, with its
//  VoiceOver adjustable action (PP-5280).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit
import PalaceUtilities

/// The audiobook seek scrubber, ported verbatim from the toolkit's
/// `PlaybackSliderView` (`AudiobookPlayerView.swift`): a thin rounded track that
/// grows on touch, with a circular thumb that scales up while dragging. It is
/// ADAPTIVE-colored (`Color(.systemGray4)` track, `Color(.label)` fill + thumb),
/// so it renders correctly in both light and dark appearance.
///
/// Behavior: `value` reflects live playback when idle (display-only fallback);
/// on touch the thumb/track grow (`withAnimation(.easeOut)`), a
/// `DragGesture(minimumDistance: 0)` continuously tracks the finger in a
/// `SeekSliderHold`, and on release the position is committed once through `onChange`
/// (plus a light seek-commit haptic). The caller supplies `accessibilityLabel`
/// at the call site.
///
/// VoiceOver (PP-5280): the slider is adjustable. A swipe up or down moves the
/// position by `forwardStepSeconds` / `backStepSeconds` of the chapter,
/// clamped to its start and end, and commits through the same path as the end
/// of a drag, so the player seeks. `spokenValue` renders the value VoiceOver
/// reads for the displayed position.
@MainActor
struct PalaceSeekSliderView: View {
    @Binding var value: Double
    var onChange: (_ value: Double) -> Void
    /// Chapter length in seconds; converts the step to a chapter fraction.
    var chapterDuration: TimeInterval = 0
    var forwardStepSeconds: Int = AudiobookSkipIntervalSettings.defaultInterval
    var backStepSeconds: Int = AudiobookSkipIntervalSettings.defaultInterval
    var spokenValue: (Double) -> String = { "\(Int($0 * 100))%" }

    enum StepDirection { case forward, back }

    /// Whether a live playback value shows the seek has landed. The tolerance
    /// is 1% of the chapter, capped at half the distance moved, so a stale tick
    /// from the old position cannot release the hold on a small move (a 30 s
    /// step is under 1% of any chapter over 50 minutes).
    nonisolated static func holdReleases(live: Double, target: Double, origin: Double) -> Bool {
        abs(live - target) <= min(0.01, abs(target - origin) / 2)
    }

    /// Step used when the chapter length is not known yet: 5% of the chapter.
    nonisolated static let fallbackStepFraction = 0.05

    /// The chapter fraction one VoiceOver step moves to from `position`.
    nonisolated static func steppedPosition(
        from position: Double,
        direction: StepDirection,
        stepSeconds: Int,
        chapterDuration: TimeInterval
    ) -> Double {
        let step = chapterDuration.isFinite && chapterDuration > 0
            ? Double(max(stepSeconds, 0)) / chapterDuration
            : fallbackStepFraction
        let target = direction == .forward ? position + step : position - step
        return min(max(target, 0), 1)
    }

    @State private var hold = SeekSliderHold()

    private let trackRest: CGFloat = 4
    private let trackActive: CGFloat = 6
    private let thumbRest: CGFloat = 8
    private let thumbActive: CGFloat = 14
    private let hitHeight: CGFloat = 44

    private var currentTrackHeight: CGFloat { hold.isDragging ? trackActive : trackRest }
    private var currentThumbSize: CGFloat { hold.isDragging ? thumbActive : thumbRest }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color(.systemGray4))
                    .frame(height: currentTrackHeight)

                // Progress fill
                Capsule()
                    .fill(Color(.label))
                    .frame(
                        width: max(currentTrackHeight, progressWidth(in: width)),
                        height: currentTrackHeight
                    )

                // Thumb
                Circle()
                    .fill(Color(.label))
                    .frame(width: currentThumbSize, height: currentThumbSize)
                    .offset(x: thumbOffset(in: width))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !hold.isDragging {
                            withAnimation(.easeOut(duration: 0.15)) { hold.beginDrag() }
                        }
                        hold.drag(to: max(0, min(1, Double(gesture.location.x / width))))
                    }
                    .onEnded { _ in
                        let commit = withAnimation(.easeOut(duration: 0.2)) {
                            hold.endDrag(live: value)
                        }
                        if let commit { send(commit) }
                    }
            )
            // A live playback value that reaches the held target releases the
            // hold (the async seek has landed and the player is republishing
            // from the new position).
            .onChange(of: value) { hold.liveTick($0) }
        }
        .frame(height: hitHeight)
        .accessibilityValue(spokenValue(displayValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(.forward)
            case .decrement: step(.back)
            @unknown default: break
            }
        }
    }

    private var displayValue: Double {
        hold.displayed(live: value)
    }

    /// One VoiceOver step from the displayed position, so repeated swipes
    /// accumulate while the previous seek is still landing.
    private func step(_ direction: StepDirection) {
        let target = Self.steppedPosition(
            from: displayValue,
            direction: direction,
            stepSeconds: direction == .forward ? forwardStepSeconds : backStepSeconds,
            chapterDuration: chapterDuration
        )
        if let commit = hold.step(to: target, live: value) { send(commit) }
    }

    /// Sends the seek `hold` just committed: the end of a drag and a VoiceOver
    /// step both land here.
    private func send(_ commit: SeekSliderHold.Commit) {
        value = commit.target
        // Subtle completion haptic on seek commit (toolkit parity).
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onChange(commit.target)
        // `value` reads `progress.playbackProgress`, which the player
        // republishes every tick, so the hold keeps the committed position
        // until the live value converges on it. The timer releases a hold the
        // live value never reaches (a failed or silent seek).
        DispatchQueue.main.asyncAfter(deadline: .now() + SeekSliderHold.safetyTimeout) {
            hold.timerFired(generation: commit.generation)
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        CGFloat(displayValue) * totalWidth
    }

    private func thumbOffset(in totalWidth: CGFloat) -> CGFloat {
        CGFloat(displayValue) * (totalWidth - currentThumbSize)
    }
}

/// The scrubber's position hold, kept out of the view so every transition can
/// be driven without a gesture. `heldPosition` is what the thumb shows in
/// place of the live value: the finger's position while dragging, and the
/// committed target until playback reaches it.
struct SeekSliderHold: Equatable {
    /// How long a commit holds the target when the live value never reaches it.
    static let safetyTimeout: TimeInterval = 2.0

    /// A seek to send: where to, and which commit's safety timer may release it.
    struct Commit: Equatable {
        let target: Double
        let generation: Int
    }

    /// One phase at a time, so a drag cannot coexist with a pending hold that a
    /// tick or a timer would release out from under the finger (PP-5293).
    enum Phase: Equatable {
        case idle
        /// The finger is down; `position` is nil only before its first report.
        case dragging(position: Double?)
        /// `target` is shown until live playback reaches it. `origin` is where
        /// the displayed position was, so the release rule can size the move.
        case holding(target: Double, origin: Double)
    }

    private(set) var phase: Phase = .idle
    /// Identifies the latest commit, so only its safety timer can release.
    private(set) var generation = 0

    var heldPosition: Double? {
        switch phase {
        case .idle: return nil
        case .dragging(let position): return position
        case .holding(let target, _): return target
        }
    }

    var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    func displayed(live: Double) -> Double {
        heldPosition ?? live
    }

    /// The finger went down. It takes over from any pending hold, keeping the
    /// thumb where the hold had it until the finger's position arrives.
    mutating func beginDrag() {
        phase = .dragging(position: heldPosition)
    }

    mutating func drag(to position: Double) {
        phase = .dragging(position: position)
    }

    /// The finger lifted. Returns the seek to send, or nil when no drag with a
    /// position is in progress.
    mutating func endDrag(live: Double) -> Commit? {
        guard case .dragging(let position) = phase else { return nil }
        phase = .idle
        guard let position else { return nil }
        return commit(position, from: live)
    }

    /// A VoiceOver step to `target`, from the displayed position. Ignored while
    /// a finger is down, since the lift commits the finger's position.
    mutating func step(to target: Double, live: Double) -> Commit? {
        guard !isDragging else { return nil }
        return commit(target, from: displayed(live: live))
    }

    mutating func liveTick(_ live: Double) {
        guard case .holding(let target, let origin) = phase,
              PalaceSeekSliderView.holdReleases(live: live, target: target, origin: origin) else { return }
        phase = .idle
    }

    mutating func timerFired(generation fired: Int) {
        guard case .holding = phase, generation == fired else { return }
        phase = .idle
    }

    private mutating func commit(_ target: Double, from origin: Double) -> Commit {
        generation += 1
        phase = .holding(target: target, origin: origin)
        return Commit(target: target, generation: generation)
    }
}
