//
//  OfflineQueueStatusView.swift
//  Palace
//
//  Banner view showing pending offline actions.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import SwiftUI

@MainActor
final class OfflineQueueStatusViewModel: ObservableObject {
    @Published var status: OfflineQueueStatus = .empty
    @Published var isVisible = false

    private let service: OfflineQueueService
    private var cancellables = Set<AnyCancellable>()

    init(service: OfflineQueueService = .shared) {
        self.service = service

        service.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.status = status
                self?.isVisible = status.hasActions
            }
            .store(in: &cancellables)
    }

    func loadStatus() {
        Task {
            let s = await service.currentStatus()
            self.status = s
            self.isVisible = s.hasActions
        }
    }
}

/// A compact banner showing the offline queue status.
struct OfflineQueueStatusView: View {
    @StateObject private var viewModel: OfflineQueueStatusViewModel
    var onTap: (() -> Void)?

    init(service: OfflineQueueService = .shared, onTap: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: OfflineQueueStatusViewModel(service: service))
        self.onTap = onTap
    }

    var body: some View {
        if viewModel.isVisible {
            Button(action: { onTap?() }) {
                HStack(spacing: 8) {
                    if viewModel.status.processingCount > 0 {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: statusIcon)
                            .foregroundColor(statusColor)
                    }

                    Text(viewModel.status.summary)
                        .font(.caption)
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(statusBackgroundColor)
                .cornerRadius(8)
            }
            .accessibilityLabel("Offline queue: \(viewModel.status.summary)")
            .accessibilityHint("Tap to view details")
            .onAppear {
                viewModel.loadStatus()
            }
        }
    }

    private var statusIcon: String {
        if viewModel.status.failedCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        return "arrow.triangle.2.circlepath"
    }

    private var statusColor: Color {
        if viewModel.status.failedCount > 0 {
            return .orange
        }
        return .accentColor
    }

    private var statusBackgroundColor: Color {
        if viewModel.status.failedCount > 0 {
            return Color.orange.opacity(0.1)
        }
        return Color.accentColor.opacity(0.1)
    }
}
