//
//  PlaybackSpeedSheet.swift
//  Palace
//
//  The audiobook player's stepped playback-speed picker, lifted out of
//  `AudiobookMorphingPlayerView.swift`. It shares no state with the player
//  beyond the `PlaybackRate` binding it is handed, so it moves whole.
//
//  The extraction is what `scripts/check-file-size-ceiling.sh` asks for when a
//  change grows a capped hub: the gate has no upward re-baseline, so the
//  accessibility work in the same PR pays for its lines by taking this cluster
//  out rather than by raising the number.
//
//  `internal` rather than `private` only because it now lives in its own file;
//  nothing outside `AudiobookMorphingPlayerView` constructs it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import PalaceAudiobookToolkit
import SwiftUI

/// Stepped playback-speed picker ported into the app from the toolkit's
/// internal `SpeedSliderSheet` (0.5×–3.0× slider + ± steppers + preset chips).
/// The toolkit view is module-internal, so its behavior is re-implemented here
/// against the public `PlaybackRate` API (`presets`, `nearest`, `convert`,
/// `displayLabel`).
@MainActor
struct PlaybackSpeedSheet: View {
    @Binding var playbackRate: PlaybackRate

    @State private var sliderValue: Double = 1.0

    private let step: Double = 0.05
    private let minRate: Double = 0.5
    private let maxRate: Double = 3.0

    private var speedLabel: String {
        PlaybackRate.nearest(to: Float(sliderValue)).displayLabel
    }
    private var atMinimum: Bool { sliderValue <= minRate }
    private var atMaximum: Bool { sliderValue >= maxRate }

    var body: some View {
        VStack(spacing: 28) {
            headerRow
            sliderRow
            presetChips
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.Generic.playbackSpeed)
        .onAppear { sliderValue = Double(PlaybackRate.convert(rate: playbackRate)) }
        .onChange(of: sliderValue) { _, newValue in
            let nearest = PlaybackRate.nearest(to: Float(newValue))
            if nearest != playbackRate {
                playbackRate = nearest
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }

    private var headerRow: some View {
        HStack {
            // This row is collapsed into a single element below, so neither
            // Text is an accessibility element of its own: the header trait
            // A11Y.SWIFTUI.HEADING_STRUCTURE asks for here would never reach
            // VoiceOver. The one element reads "Playback speed: 1.5x".
            // accesslint:disable A11Y.SWIFTUI.HEADING_STRUCTURE
            Text(Strings.Generic.playbackSpeed)
                .font(.headline)
            // accesslint:enable A11Y.SWIFTUI.HEADING_STRUCTURE
            Spacer()
            Text(speedLabel)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.Generic.playbackSpeedValue(speedLabel))
    }

    private var sliderRow: some View {
        HStack(spacing: 16) {
            stepButton(systemName: "minus", label: Strings.Generic.decreaseSpeed, isDisabled: atMinimum, action: stepDown)
            Slider(value: $sliderValue, in: minRate...maxRate, step: step)
                .tint(.accentColor)
                .accessibilityLabel(Strings.Generic.playbackSpeed)
                .accessibilityValue(speedLabel)
            stepButton(systemName: "plus", label: Strings.Generic.increaseSpeed, isDisabled: atMaximum, action: stepUp)
        }
    }

    private func stepButton(systemName: String, label: String, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // accesslint:disable A11Y.SWIFTUI.FIXED_FONT - glyph geometry inside a fixed 40pt circle
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.secondary.opacity(isDisabled ? 0.05 : 0.15)))
                // Keep the 40pt circle, widen the hit region to the 44pt
                // minimum (WCAG 2.5.5), matching the mini-player's close button.
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            // accesslint:enable A11Y.SWIFTUI.FIXED_FONT
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }

    private var presetChips: some View {
        HStack(spacing: 8) {
            ForEach(PlaybackRate.presets, id: \.rawValue) { preset in
                presetChip(for: preset)
            }
        }
        .accessibilityLabel(Strings.Generic.playbackSpeed)
    }

    private func presetChip(for preset: PlaybackRate) -> some View {
        let multiplier = PlaybackRate.convert(rate: preset)
        let isSelected = abs(sliderValue - Double(multiplier)) < 0.001
        return Button {
            withAnimation(.easeOut(duration: 0.1)) { sliderValue = Double(multiplier) }
        } label: {
            Text(preset.displayLabel)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .lineLimit(1)
                // Six chips share one row, so past roughly AX2 the label shrinks
                // rather than truncating or pushing its neighbours off-screen.
                .minimumScaleFactor(0.7)
                .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.primary : Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.displayLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func stepDown() {
        withAnimation(.easeOut(duration: 0.1)) {
            sliderValue = max(minRate, ((sliderValue - step) * 100).rounded() / 100)
        }
    }
    private func stepUp() {
        withAnimation(.easeOut(duration: 0.1)) {
            sliderValue = min(maxRate, ((sliderValue + step) * 100).rounded() / 100)
        }
    }
}
