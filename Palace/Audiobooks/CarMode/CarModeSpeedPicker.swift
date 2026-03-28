//
//  CarModeSpeedPicker.swift
//  Palace
//
//  Speed selection overlay for car mode.
//  Large vertical list of speed options with haptic feedback.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

// MARK: - CarModeSpeedPicker

public struct CarModeSpeedPicker: View {

    let currentSpeed: Double
    let onSelect: (PlaybackSpeed) -> Void

    @Environment(\.dismiss) private var dismiss

    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)

    public var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(PlaybackSpeed.quickPicks) { speed in
                            speedRow(speed)
                                .id(speed.id)
                        }

                        Divider()
                            .padding(.vertical, 8)

                        Text("All Speeds")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)

                        ForEach(PlaybackSpeed.allOptions) { speed in
                            if !PlaybackSpeed.quickPicks.contains(speed) {
                                speedRow(speed)
                                    .id(speed.id)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
                .onAppear {
                    // Scroll to current speed
                    let closestId = closestSpeedId()
                    proxy.scrollTo(closestId, anchor: .center)
                }
            }
            .navigationTitle("Playback Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 18, weight: .semibold))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Speed Row

    private func speedRow(_ speed: PlaybackSpeed) -> some View {
        let isSelected = abs(speed.rate - currentSpeed) < 0.05

        return Button(action: {
            impactFeedback.impactOccurred()
            onSelect(speed)
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(speed.compactLabel)
                        .font(.system(size: 24, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? .yellow : .white)

                    if let name = speed.presetName {
                        Text(name)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(isSelected ? .yellow.opacity(0.8) : .white.opacity(0.6))
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.yellow)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.white.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(speed.displayLabel)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Sets playback speed to \(speed.compactLabel)")
    }

    private func closestSpeedId() -> Double {
        let all = PlaybackSpeed.quickPicks
        return all.min(by: { abs($0.rate - currentSpeed) < abs($1.rate - currentSpeed) })?.id ?? 1.0
    }
}
