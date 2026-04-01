//
//  CarModeSleepTimerPicker.swift
//  Palace
//
//  Sleep timer selection overlay for car mode.
//  Large buttons for preset durations, plus cancel option when timer is active.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

// MARK: - CarModeSleepTimerPicker

public struct CarModeSleepTimerPicker: View {

    let timerState: SleepTimerState
    let onSelect: (SleepTimerOption) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)

    public var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                // Active timer indicator
                if timerState.isActive {
                    activeTimerBanner
                        .padding(.top, 16)
                }

                // Timer options
                VStack(spacing: 12) {
                    ForEach(SleepTimerOption.allCases) { option in
                        timerOptionButton(option)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, timerState.isActive ? 8 : 24)

                // Cancel button when timer is active
                if timerState.isActive {
                    cancelButton
                        .padding(.top, 16)
                }

                Spacer()
            }
            .navigationTitle("Sleep Timer")
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

    // MARK: - Active Timer Banner

    private var activeTimerBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.fill")
                .font(.system(size: 24))
                .foregroundColor(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("Timer Active")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Text(timerState.buttonLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.yellow)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.1))
        )
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep timer active, \(timerState.buttonLabel) remaining")
    }

    // MARK: - Timer Option Button

    private func timerOptionButton(_ option: SleepTimerOption) -> some View {
        Button(action: {
            impactFeedback.impactOccurred()
            onSelect(option)
        }) {
            HStack {
                Image(systemName: option == .endOfChapter ? "text.badge.checkmark" : "clock")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 32)

                Text(option.displayName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.1))
            )
            .contentShape(Rectangle())
        }
        .accessibilityLabel(option.displayName)
        .accessibilityHint("Sets sleep timer to \(option.displayName)")
    }

    // MARK: - Cancel Button

    private var cancelButton: some View {
        Button(action: {
            impactFeedback.impactOccurred()
            onCancel()
        }) {
            HStack {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 22))

                Text("Cancel Timer")
                    .font(.system(size: 22, weight: .medium))
            }
            .foregroundColor(.red)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.red.opacity(0.15))
            )
        }
        .padding(.horizontal, 20)
        .accessibilityLabel("Cancel sleep timer")
    }
}
