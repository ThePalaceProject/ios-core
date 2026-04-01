//
//  AppHealthView.swift
//  Palace
//
//  Developer-facing health dashboard for performance, cache, and queue status.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

struct AppHealthView: View {
    @StateObject private var viewModel = AppHealthViewModel()

    var body: some View {
        List {
            if viewModel.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading health data...")
                        Spacer()
                    }
                }
            } else {
                // Group metrics by category
                let grouped = Dictionary(grouping: viewModel.metrics, by: \.category)
                let sortedKeys = grouped.keys.sorted()

                ForEach(sortedKeys, id: \.self) { category in
                    Section(category) {
                        ForEach(grouped[category] ?? []) { item in
                            HealthMetricRow(item: item)
                        }
                    }
                }

                if let report = viewModel.performanceReport {
                    Section("Performance Summary") {
                        Text(report.summary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button("Refresh") {
                        viewModel.loadData()
                    }
                }
            }
        }
        .navigationTitle("App Health")
        .onAppear {
            viewModel.loadData()
        }
        .refreshable {
            viewModel.loadData()
        }
    }
}

private struct HealthMetricRow: View {
    let item: HealthMetricItem

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(item.name)
                .font(.body)

            Spacer()

            Text(item.value)
                .font(.body.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name): \(item.value)")
    }

    private var statusColor: Color {
        switch item.status {
        case .good: return .green
        case .warning: return .orange
        case .error: return .red
        case .info: return .blue
        }
    }
}
