//
//  HelpButton.swift
//  Palace
//
//  Flag-gated "Get Help" button that presents the triage-bot chat as a sheet
//  (book detail, sign-in). Settings has its own row but uses the same
//  `HelpEntryPointPolicy`, so all entry points follow the kill-switch together.
//  Palace chrome is monochrome: the glyph uses `.primary`, never a tint.
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

    /// Feature-flag read seam, resolved from the environment.
    @Environment(\.appContainer) private var appContainer

    /// Resolved through the shared policy so the kill-switch is the single
    /// source of truth.
    private var isVisible: Bool {
        HelpEntryPointPolicy.shouldShowHelp(
            at: entryPoint,
            triageBotEnabled: appContainer.featureFlags.isTriageBotEnabled
        )
    }

    var body: some View {
        if isVisible {
            Button {
                showHelp = true
            } label: {
                // accesslint:disable A11Y.SWIFTUI.FIXED_FONT - sizes a decorative SF Symbol glyph inside a 44x44 button, not text, so Dynamic Type does not apply
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    // accesslint:enable A11Y.SWIFTUI.FIXED_FONT
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
