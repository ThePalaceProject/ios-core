//
//  DeveloperSettingsView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//
//  SwiftUI reimplementation of `TPPDeveloperSettingsTableViewController` (the
//  "Testing" screen). Feature-for-feature, pixel-for-pixel port. Only the
//  ENGINEERING-tier sections live here; the SUPPORT-tier content (Send Error
//  Logs + Data & Reset) moved to `AppAdvancedSettingsView` per PP-4788.
//
//  All state + actions live on the shared `DeveloperSettingsViewModel`, so the
//  Advanced screen reuses the exact same action code.
//

import SwiftUI
import PalaceUIKit

struct DeveloperSettingsView: View {
    typealias DisplayStrings = Strings.TPPDeveloperSettingsTableViewController

    @StateObject private var viewModel: DeveloperSettingsViewModel

    init(viewModel: DeveloperSettingsViewModel = DeveloperSettingsViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            // Engineering-tier runtime gate — MUST match the retired UIKit VC's
            // `visibleSections` filter (audience == .support || showEngineeringTools).
            // On a production App Store build (showEngineeringTools == false) these
            // sections are hidden, so a patron who trips the version long-press does
            // NOT see production-behavior-changing feature-flag toggles. The patron
            // functions (Send Error Logs, Data & Reset) live in the always-visible
            // Advanced menu, so nothing patron-facing is lost — the Testing screen
            // is simply empty on production. On DEBUG / simulator / TestFlight
            // (showEngineeringTools == true) all sections render.
            if viewModel.showEngineeringTools {
                librarySettingsSection
                triageBotSection
                featureFlagsSection
                libraryRegistryDebuggingSection
                developerToolsSection
                pushNotificationTestingSection
                #if DEBUG
                badgeTestingSection
                #endif
                errorSimulationSection
                #if DEBUG
                mockBackendSection
                resetAccountTestingSection
                #endif
            }
        }
        .listStyle(GroupedListStyle())
        .navigationBarTitle(DisplayStrings.developerSettingsTitle)
        .task {
            await viewModel.loadFCMToken()
        }
    }

    /// The presenter used by alert / action-sheet / mail actions.
    private func present(_ action: (UIViewController) -> Void) {
        guard let vc = DeveloperSettingsPresenter.topViewController() else { return }
        action(vc)
    }

    // MARK: - Library Settings

    @ViewBuilder private var librarySettingsSection: some View {
        Section(header: Text("Library Settings")) {
            DevToggleRow(title: "Enable Hidden Libraries", isOn: $viewModel.useBetaLibraries)
            DevToggleRow(title: "Enter LCP Passphrase Manually", isOn: $viewModel.enterLCPPassphraseManually)
        }
    }

    // MARK: - Triage Bot

    @ViewBuilder private var triageBotSection: some View {
        Section(header: Text("Triage Bot")) {
            DevToggleRow(title: "Enabled (master)", isOn: $viewModel.triageBotEnabled)
            DevToggleRow(title: "Ticket Submission (Email)", isOn: $viewModel.triageBotTicketSubmissionEnabled)
            DevToggleRow(title: "AI Fallback (Claude)", isOn: $viewModel.triageBotAIFallbackEnabled)
            #if DEBUG
            DevToggleRow(title: "Force Submit Failure (debug)", isOn: $viewModel.triageBotForceSubmitFailure)
            #endif
            DevDisclosureValueRow(
                title: "Anthropic API Key",
                value: viewModel.anthropicKeyStatus
            ) {
                present { viewModel.presentAnthropicKeyEntry(from: $0) }
            }
        }
    }

    // MARK: - Developer Tools (engineering)

    /// Engineering-tier Developer Tools. Only "Email Audiobook Logs" remains here;
    /// the patron-facing "Send Error Logs" moved to the always-visible Advanced
    /// screen (PP-4788). Preserves the original DEVELOPER TOOLS section so the
    /// audiobook-logs export isn't lost in the migration.
    @ViewBuilder private var developerToolsSection: some View {
        Section(header: Text("Developer Tools")) {
            DevDisclosureValueRow(title: "Email Audiobook Logs", value: "") {
                present { viewModel.emailAudiobookLogs(from: $0) }
            }
        }
    }

    // MARK: - Feature Flags

    @ViewBuilder private var featureFlagsSection: some View {
        Section(header: Text("Feature Flags")) {
            DevToggleRow(title: "In-App Playback Navigation", isOn: $viewModel.inAppPlaybackNavEnabled)
            DevToggleRow(title: "Force Rating Prompt Eligible", isOn: $viewModel.appRatingForceEligible)
            DevActionRow(title: "Trigger Rating Prompt Now", color: .blue) {
                viewModel.triggerRatingPromptNow()
            }
            DevActionRow(title: "Reset Rating State", color: .red) {
                present { viewModel.resetRatingState(from: $0) }
            }
        }
    }

    // MARK: - Library Registry Debugging

    @ViewBuilder private var libraryRegistryDebuggingSection: some View {
        Section(header: Text("Library Registry Debugging")) {
            DevRegistryDebuggingRow(
                input: $viewModel.customRegistryInput,
                onClear: { present { viewModel.clearCustomRegistry(from: $0) } },
                onSet: { present { viewModel.setCustomRegistry(from: $0) } }
            )
        }
    }

    // MARK: - Push Notification Testing

    @ViewBuilder private var pushNotificationTestingSection: some View {
        Section(header: Text("Push Notification Testing")) {
            DevMonospaceValueRow(title: "FCM Token", value: viewModel.fcmToken)
                // Tapping the FCM row copies the token (verbatim from the UIKit
                // `.pushNotificationTesting` row-0 handler).
                .contentShape(Rectangle())
                .onTapGesture { present { viewModel.copyFCMToken(from: $0) } }
            DevSubtitleDisclosureRow(
                title: "Send Hold Available",
                subtitle: "Schedules a test notification with delay"
            ) {
                present { viewModel.scheduleTestNotification(type: .holdAvailable, from: $0) }
            }
            DevSubtitleDisclosureRow(
                title: "Send Loan Expiry Warning",
                subtitle: "Schedules a test notification with delay"
            ) {
                present { viewModel.scheduleTestNotification(type: .loanExpiry, from: $0) }
            }
        }
    }

    // MARK: - Badge Testing (DEBUG)

    #if DEBUG
    @ViewBuilder private var badgeTestingSection: some View {
        Section(header: Text("Badge Testing")) {
            DevToggleRow(title: "Enable Badge Logging", isOn: $viewModel.badgeLoggingEnabled)
            DevDisclosureValueRow(
                title: "Test Holds Configuration",
                value: viewModel.testHoldsConfiguration.displayName,
                valueColor: viewModel.testHoldsConfiguration == .none ? .secondary : .blue
            ) {
                present { viewModel.showTestHoldsPicker(from: $0) }
            }
        }
    }
    #endif

    // MARK: - Error Simulation

    @ViewBuilder private var errorSimulationSection: some View {
        Section(header: Text("Error Simulation (Testing)")) {
            DevDisclosureValueRow(
                title: "Simulate Borrow Error",
                value: viewModel.simulatedBorrowError.displayName,
                valueColor: viewModel.simulatedBorrowError == .none ? .secondary : .orange
            ) {
                present { viewModel.showErrorSimulationPicker(from: $0) }
            }
            DevDisclosureValueRow(
                title: "Simulate Sync Failure",
                value: viewModel.simulatedSyncFailure.displayName,
                valueColor: viewModel.simulatedSyncFailure == .none ? .secondary : .red
            ) {
                present { viewModel.showSyncFailurePicker(from: $0) }
            }
            #if DEBUG
            DevActionRow(title: "Preview Error Details View", color: .blue) {
                present { viewModel.showPreviewErrorDetails(from: $0) }
            }
            #endif
        }
    }

    // MARK: - Mock Backend (DEBUG)

    #if DEBUG
    @ViewBuilder private var mockBackendSection: some View {
        Section(header: Text("Mock Backend")) {
            MockBackendRow()
        }
    }
    #endif

    // MARK: - Reset Account Testing (DEBUG, PP-4282)

    #if DEBUG
    @ViewBuilder private var resetAccountTestingSection: some View {
        Section(header: Text("Reset Account Testing (PP-4282)")) {
            DevSubtitleDisclosureRow(
                title: "1. Simulate Stuck State",
                subtitle: "Marks current account as if push-reg silently failed and SAML credentials went stale. Then go tap Reset Account."
            ) {
                present { viewModel.simulateResetAccountStuckState(from: $0) }
            }
            DevSubtitleDisclosureRow(
                title: "2. Inspect Account State",
                subtitle: "Shows current values for everything Reset Account touches. Use after Simulate (state should look broken) and after Reset (state should look clean)."
            ) {
                present { viewModel.inspectResetAccountState(from: $0) }
            }
            DevSubtitleDisclosureRow(
                title: "3. Set One-Shot Ephemeral Flag",
                subtitle: "Manually sets the next-OIDC-session-ephemeral flag without running a full Reset. Lets you verify the OIDC consume path independently."
            ) {
                present { viewModel.setNextOIDCEphemeralFlagForTesting(from: $0) }
            }
        }
    }
    #endif
}

// MARK: - Mock Backend row

#if DEBUG
/// The Mock Backend disclosure row. Observes `MockBackendService.shared` so the
/// title/subtitle reflect the active scenario (green title when active), then
/// pushes `MockBackendPickerView` via a NavigationLink. Verbatim rendering of
/// `cellForMockBackend`.
private struct MockBackendRow: View {
    @ObservedObject private var service = MockBackendService.shared

    var body: some View {
        NavigationLink {
            MockBackendPickerView()
                .navigationTitle("Mock Backend")
        } label: {
            if service.isActive, let scenario = service.currentScenario {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mock Backend: \(scenario.displayName)")
                        .palaceFont(.body)
                        .foregroundStyle(.green)
                    Text("Active — \(scenario.routes.count) routes")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mock Backend")
                        .palaceFont(.body)
                    Text("Tap to configure")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
