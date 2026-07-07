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

/// **DEFER factory construction to navigation time.**
///
/// Chaos-qa F-005 (2026-05-29) showed that the previous shape — a failable
/// `init?()` that runs `TriageBotFactory.makeViewModel()` on every
/// SwiftUI evaluation of the Settings supportSection — could intermittently
/// return nil after backgrounding / re-foregrounding the app, causing the
/// Settings row to silently disappear.
///
/// New shape: the wrapper has a non-failing init. It calls the factory
/// inside `body`, where the construction happens only when the user
/// actually navigates here. If the factory returns nil at that moment, the
/// user sees an explicit error state — not a disappeared Settings row.
struct TriageBotSupportView: View {
    var body: some View {
        if let viewModel = TriageBotFactory.makeViewModel() as? TriageBotViewModel {
            SupportChatView(viewModel: viewModel)
        } else {
            UnavailableView()
        }
    }
}

/// Shown only when the factory returns nil at navigation time (catalog
/// load failed, etc.). Honest about the problem; gives the user a clear
/// next step rather than a silent failure.
private struct UnavailableView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Get Help is temporarily unavailable")
                .font(.headline)
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
