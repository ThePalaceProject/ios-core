//
//  AccessibilitySettingsView.swift
//  Palace
//
//  App-specific accessibility settings panel.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import SwiftUI

@MainActor
final class AccessibilitySettingsViewModel: ObservableObject {
    @Published var preferences: AccessibilityPreferences = .default
    @Published var isLoading = true

    private let service: AccessibilityService
    private var cancellables = Set<AnyCancellable>()

    init(service: AccessibilityService = .shared) {
        self.service = service

        service.preferencesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in
                self?.preferences = prefs
                self?.isLoading = false
            }
            .store(in: &cancellables)
    }

    func loadPreferences() {
        Task {
            let prefs = await service.currentPreferences()
            self.preferences = prefs
            self.isLoading = false
        }
    }

    func savePreferences() {
        Task {
            await service.updatePreferences(preferences)
        }
    }

    func updateVerbosity(_ verbosity: AnnouncementVerbosity) {
        preferences.verbosity = verbosity
        savePreferences()
    }

    func toggleReducedMotion() {
        preferences.reducedMotion.toggle()
        savePreferences()
    }

    func toggleHighContrast() {
        preferences.highContrastBoost.toggle()
        savePreferences()
    }

    func toggleButtonShapes() {
        preferences.buttonShapesEnabled.toggle()
        savePreferences()
    }

    func toggleHapticFeedback() {
        preferences.hapticFeedbackEnabled.toggle()
        savePreferences()
    }

    func toggleCustomRotor() {
        preferences.customRotorActionsEnabled.toggle()
        savePreferences()
    }
}

struct AccessibilitySettingsView: View {
    @StateObject private var viewModel: AccessibilitySettingsViewModel

    init(service: AccessibilityService = .shared) {
        _viewModel = StateObject(wrappedValue: AccessibilitySettingsViewModel(service: service))
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("These settings supplement your system accessibility preferences. They do not override system settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("VoiceOver Announcements") {
                Picker("Verbosity", selection: $viewModel.preferences.verbosity) {
                    ForEach(AnnouncementVerbosity.allCases, id: \.self) { level in
                        VStack(alignment: .leading) {
                            Text(level.displayName)
                        }
                        .tag(level)
                    }
                }
                .onChange(of: viewModel.preferences.verbosity) { newValue in
                    viewModel.updateVerbosity(newValue)
                }

                Text(viewModel.preferences.verbosity.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Custom Rotor Actions", isOn: Binding(
                    get: { viewModel.preferences.customRotorActionsEnabled },
                    set: { _ in viewModel.toggleCustomRotor() }
                ))

                Text("Adds rotor actions for jumping between chapters and bookmarks.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Motion & Animation") {
                Toggle("Reduce App Animations", isOn: Binding(
                    get: { viewModel.preferences.reducedMotion },
                    set: { _ in viewModel.toggleReducedMotion() }
                ))

                Text("Reduces animations beyond the system Reduce Motion setting.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Haptic Feedback", isOn: Binding(
                    get: { viewModel.preferences.hapticFeedbackEnabled },
                    set: { _ in viewModel.toggleHapticFeedback() }
                ))
            }

            Section("Visual") {
                Toggle("High Contrast Boost", isOn: Binding(
                    get: { viewModel.preferences.highContrastBoost },
                    set: { _ in viewModel.toggleHighContrast() }
                ))

                Text("Increases contrast beyond the system setting for better readability.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Button Shapes", isOn: Binding(
                    get: { viewModel.preferences.buttonShapesEnabled },
                    set: { _ in viewModel.toggleButtonShapes() }
                ))

                Text("Shows outlines around interactive elements.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Preview") {
                AccessibilityPreviewView(preferences: viewModel.preferences)
            }
        }
        .navigationTitle("Accessibility")
        .onAppear {
            viewModel.loadPreferences()
        }
    }
}

/// A preview showing how the current accessibility preferences affect the UI.
private struct AccessibilityPreviewView: View {
    let preferences: AccessibilityPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sample Book Title")
                .font(.headline)
                .foregroundColor(preferences.highContrastBoost ? .primary : .primary.opacity(0.87))

            Text("By Sample Author")
                .font(.subheadline)
                .foregroundColor(preferences.highContrastBoost ? .secondary : .secondary.opacity(0.8))

            Button(action: {}) {
                Text("Borrow")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(preferences.buttonShapesEnabled ? 4 : 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: preferences.buttonShapesEnabled ? 4 : 8)
                            .stroke(preferences.buttonShapesEnabled ? Color.primary : Color.clear, lineWidth: preferences.buttonShapesEnabled ? 2 : 0)
                    )
            }
            .accessibilityLabel("Borrow sample book")
        }
        .padding(.vertical, 8)
        .animation(preferences.reducedMotion ? nil : .default, value: preferences)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of accessibility settings")
    }
}
