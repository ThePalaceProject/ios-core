//
//  AppAdvancedSettingsView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//
//  App-level "Advanced" screen (PP-4788). Surfaces the SUPPORT-tier developer
//  content — Send Error Logs (from DEVELOPER TOOLS) and the DATA & RESET section
//  (Clear Cached Data / Reset This Library / Full Reset) — as an ALWAYS-VISIBLE
//  screen, split out of the engineering-gated Testing screen.
//
//  Named `AppAdvancedSettingsView` to avoid a collision with the account-level
//  `AdvancedSettingsView` (Palace/Settings/AdvancedSettingsView.swift). Shares
//  the row builders + action code with `DeveloperSettingsView` via the common
//  `DeveloperSettingsViewModel`, so there is no duplicated action logic.
//
//  Wired into `TPPSettingsView` as the always-visible "Advanced" section (no
//  gesture required), so support can direct patrons to Send Error Logs / Data &
//  Reset without the hidden version long-press.
//

import SwiftUI
import PalaceUIKit

struct AppAdvancedSettingsView: View {
    @StateObject private var viewModel: DeveloperSettingsViewModel

    init(viewModel: DeveloperSettingsViewModel = DeveloperSettingsViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            developerToolsSection
            dataAndResetSection
        }
        .listStyle(GroupedListStyle())
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadEnhancedLoggingStatus()
        }
    }

    private func present(_ action: (UIViewController) -> Void) {
        guard let vc = DeveloperSettingsPresenter.topViewController() else { return }
        action(vc)
    }

    // MARK: - Developer Tools (support subset: Send Error Logs)

    @ViewBuilder private var developerToolsSection: some View {
        Section(header: Text("Developer Tools")) {
            DevDisclosureValueRow(
                title: "Send Error Logs",
                // "🔍 Enhanced" in green when enhanced monitoring is on — matches
                // the async detail-label update in `cellForSendErrorLogs`.
                value: viewModel.isEnhancedLoggingEnabled ? "🔍 Enhanced" : "",
                valueColor: .green
            ) {
                present { viewModel.sendErrorLogs(from: $0) }
            }
        }
    }

    // MARK: - Data & Reset

    @ViewBuilder private var dataAndResetSection: some View {
        Section(header: Text("Data & Reset")) {
            DevActionRow(title: "Clear Cached Data") {
                present { viewModel.clearCachedData(from: $0) }
            }
            DevSubtitleRow(
                title: "Reset This Library",
                titleColor: .red,
                subtitle: "Signs out & deletes this library's downloads, bookmarks, saved login. Other libraries unaffected."
            ) {
                present { viewModel.confirmResetThisLibrary(from: $0) }
            }
            DevSubtitleRow(
                title: "Full Reset (All Libraries)",
                titleColor: .red,
                subtitle: "For a stuck app. Signs out of ALL libraries & re-activates DRM device-wide. Use only if a single-library reset didn't fix it."
            ) {
                present { viewModel.confirmFullReset(from: $0) }
            }
        }
    }
}
