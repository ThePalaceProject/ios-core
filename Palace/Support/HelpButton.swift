//
//  HelpButton.swift
//  Palace
//
//  Shared, flag-gated "Get Help" affordance. One monochrome question-mark
//  glyph that presents the triage-bot chat (`TriageBotSupportView`) as a sheet,
//  reused across its entry points (book detail, sign-in).
//  Settings has its own row (`TPPSettingsView.supportSection`) but resolves
//  visibility through the SAME `HelpEntryPointPolicy`, so all entry points
//  appear and vanish together with the master kill-switch (AC-14).
//
//  Monochrome by design — CLAUDE.md "Palace chrome is monochrome": the glyph is
//  `.foregroundStyle(.primary)`, never a `.tint`/`.blue`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct HelpButton: View {
    /// Which surface is hosting this button. Drives the visibility policy and a
    /// stable accessibility identifier.
    let entryPoint: HelpEntryPoint

    @State private var showHelp = false

    /// Resolve visibility through the shared pure policy so the kill-switch is
    /// the single source of truth (and unit-tested in `HelpEntryPointPolicyTests`).
    /// Reading the flag at body-eval time mirrors how
    /// `TPPSettingsView.supportSection` resolves its row.
    private var isVisible: Bool {
        HelpEntryPointPolicy.shouldShowHelp(
            at: entryPoint,
            triageBotEnabled: RemoteFeatureFlags.shared.isTriageBotEnabled
        )
    }

    var body: some View {
        if isVisible {
            Button {
                showHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("help.button.\(entryPoint.rawValue)")
            .accessibilityLabel("Get Help — chat with our support bot")
            .sheet(isPresented: $showHelp) {
                TriageBotSupportView()
            }
        }
    }
}
#endif
