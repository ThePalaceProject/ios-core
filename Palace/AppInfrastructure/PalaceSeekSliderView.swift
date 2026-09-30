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
/// `DragGesture(minimumDistance: 0)` continuously tracks the finger via a
/// `tempValue`, and on release the position is committed once through `onChange`
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

    @State private var tempValue: Double?
    @State private var isDragging: Bool = false
    @State private var isCommitting: Bool = false
    /// Where the displayed position was when the current hold began; the hold
    /// releases only on a live value nearer the target than half the move.
    @State private var commitOrigin: Double = 0
    /// Identifies the latest commit, so only its safety timer can release.
    @State private var commitGeneration: Int = 0

    private let trackRest: CGFloat = 4
    private let trackActive: CGFloat = 6
    private let thumbRest: CGFloat = 8
    private let thumbActive: CGFloat = 14
    private let hitHeight: CGFloat = 44

    private var currentTrackHeight: CGFloat { isDragging ? trackActive : trackRest }
    private var currentThumbSize: CGFloat { isDragging ? thumbActive : thumbRest }

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
                        if !isDragging {
                            withAnimation(.easeOut(duration: 0.15)) { isDragging = true }
                        }
                        let newValue = max(0, min(1, Double(gesture.location.x / width)))
                        tempValue = newValue
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.2)) { isDragging = false }
                        if let finalValue = tempValue {
                            commit(finalValue, from: value)
                        }
                    }
            )
            // Release the committed-position hold once live playback progress
            // has caught up to the seek target (the async seek has landed and
            // the player is now republishing from the new position). Guarded on
            // `isCommitting` so idle ticks never touch `tempValue`.
            .onChange(of: value) { newValue in
                guard isCommitting, let target = tempValue else { return }
                if Self.holdReleases(live: newValue, target: target, origin: commitOrigin) {
                    tempValue = nil
                    isCommitting = false
                }
            }
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
        tempValue ?? value
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
        let origin = displayValue
        tempValue = target
        commit(target, from: origin)
    }

    /// Commits a seek to `finalValue`: the end of a drag and a VoiceOver step
    /// both land here.
    private func commit(_ finalValue: Double, from origin: Double) {
        commitGeneration += 1
        let generation = commitGeneration
        commitOrigin = origin
        isCommitting = true
        value = finalValue
        // Subtle completion haptic on seek commit (toolkit parity).
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onChange(finalValue)
        // HOLD the committed thumb position until the LIVE
        // playback value converges to the seek target (see
        // `.onChange(of: value)` below). Unlike the toolkit —
        // whose binding is not a high-frequency player mirror —
        // our `value` reads `progress.playbackProgress`, which
        // the player republishes every tick. A fixed 0.1s clear
        // let a STALE pre-seek tick overwrite the optimistic
        // `value = finalValue` before the async seek landed, so
        // the thumb snapped back to the old position while time
        // moved forward. We instead keep `tempValue` until the
        // seek propagates, with a safety timeout so a failed /
        // silent seek can never wedge the thumb.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if isCommitting && commitGeneration == generation {
                tempValue = nil
                isCommitting = false
            }
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        CGFloat(displayValue) * totalWidth
    }

    private func thumbOffset(in totalWidth: CGFloat) -> CGFloat {
        CGFloat(displayValue) * (totalWidth - currentThumbSize)
    }
}
