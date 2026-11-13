//
//  AppAdvancedSettingsView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//
//  App-level "Advanced" screen (PP-4788): Send Error Logs and Data & Reset,
//  always visible so support can direct patrons here without the hidden
//  Testing-screen gesture. Shares actions with `DeveloperSettingsView` via
//  `DeveloperSettingsViewModel`. Named to avoid colliding with the account-level
//  `AdvancedSettingsView`.
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
