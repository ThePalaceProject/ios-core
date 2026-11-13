//
//  TriageBotSupportView.swift
//  Palace
//
//  SwiftUI host for the triage bot. Wraps the package's SupportChatView in a
//  NavigationStack so it can be pushed from Settings, presented as a sheet
//  from a Help button, or shown full-screen — caller's choice.
//

#if canImport(UIKit)
import SwiftUI
import TriageBotUI

/// Builds the view model in `body`, at navigation time, rather than in a
/// failable init. A failable init ran on every evaluation of the Settings
/// section and could return nil after a background/foreground cycle, which
/// removed the Settings row. A nil factory result now shows an error state.
struct TriageBotSupportView: View {
    /// Handed to the factory so the bot's flag reads use the injected provider.
    @Environment(\.appContainer) private var appContainer

    var body: some View {
        if let viewModel = TriageBotFactory.makeViewModel(featureFlags: appContainer.featureFlags) as? TriageBotViewModel {
            SupportChatView(viewModel: viewModel)
        } else {
            UnavailableView()
        }
    }
}

/// Shown when the factory returns nil at navigation time (e.g. catalog load failed).
private struct UnavailableView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                // The heading below carries the same message; announcing the
                // glyph as well would say it twice.
                .accessibilityHidden(true)
            Text("Get Help is temporarily unavailable")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Please force-quit and reopen Palace, then try again. If the problem persists, email support@thepalaceproject.org.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .navigationTitle("Get Help")
        .navigationBarTitleDisplayMode(.inline)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
