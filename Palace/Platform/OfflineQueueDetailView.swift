//
//  OfflineQueueDetailView.swift
//  Palace
//
//  Detailed view of pending and failed offline actions.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import SwiftUI

@MainActor
final class OfflineQueueDetailViewModel: ObservableObject {
    @Published var pendingActions: [OfflineAction] = []
    @Published var failedActions: [OfflineAction] = []
    @Published var isProcessing = false

    private let service: OfflineQueueService
    private var cancellables = Set<AnyCancellable>()

    init(service: OfflineQueueService = .shared) {
        self.service = service

        service.actionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadActions()
            }
            .store(in: &cancellables)

        service.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isProcessing = status.processingCount > 0
            }
            .store(in: &cancellables)
    }

    func loadActions() {
        Task {
            let pending = await service.actions(withState: .pending)
            let failed = await service.actions(withState: .failed)
            let processing = await service.isProcessing()
            self.pendingActions = pending
            self.failedActions = failed
            self.isProcessing = processing
        }
    }

    func retryAction(_ id: UUID) {
        Task {
            await service.retry(id)
            loadActions()
        }
    }

    func cancelAction(_ id: UUID) {
        Task {
            await service.cancel(id)
            loadActions()
        }
    }

    func clearAllFailed() {
        Task {
            await service.clearFailed()
            loadActions()
        }
    }

    func retryAll() {
        Task {
            for action in failedActions {
                await service.retry(action.id)
            }
            loadActions()
        }
    }
}

struct OfflineQueueDetailView: View {
    @StateObject private var viewModel: OfflineQueueDetailViewModel

    init(service: OfflineQueueService = .shared) {
        _viewModel = StateObject(wrappedValue: OfflineQueueDetailViewModel(service: service))
    }

    var body: some View {
        List {
            if viewModel.isProcessing {
                Section {
                    HStack {
                        ProgressView()
                        Text("Processing actions...")
                            .foregroundColor(.secondary)
                    }
                }
            }

            if !viewModel.pendingActions.isEmpty {
                Section("Pending") {
                    ForEach(viewModel.pendingActions) { action in
                        OfflineActionRow(action: action)
                            .swipeActions(edge: .trailing) {
                                Button("Cancel", role: .destructive) {
                                    viewModel.cancelAction(action.id)
                                }
                            }
                    }
                }
            }

            if !viewModel.failedActions.isEmpty {
                Section {
                    ForEach(viewModel.failedActions) { action in
                        OfflineActionRow(action: action)
                            .swipeActions(edge: .trailing) {
                                Button("Cancel", role: .destructive) {
                                    viewModel.cancelAction(action.id)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if action.canRetry {
                                    Button("Retry") {
                                        viewModel.retryAction(action.id)
                                    }
                                    .tint(.accentColor)
                                }
                            }
                    }
                } header: {
                    Text("Failed")
                } footer: {
                    HStack {
                        Button("Retry All") {
                            viewModel.retryAll()
                        }
                        Spacer()
                        Button("Clear All", role: .destructive) {
                            viewModel.clearAllFailed()
                        }
                    }
                    .font(.caption)
                }
            }

            if viewModel.pendingActions.isEmpty && viewModel.failedActions.isEmpty && !viewModel.isProcessing {
                Section {
                    Text("No pending offline actions")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle("Offline Queue")
        .onAppear {
            viewModel.loadActions()
        }
    }
}

private struct OfflineActionRow: View {
    let action: OfflineAction

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(action.displayDescription)
                .font(.body)

            HStack {
                Image(systemName: stateIcon)
                    .foregroundColor(stateColor)
                    .font(.caption)

                Text(stateDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if action.retryCount > 0 {
                    Text("(\(action.retryCount)/\(action.maxRetries) retries)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if let error = action.errorMessage, action.state == .failed {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(action.displayDescription), \(stateDescription)")
    }

    private var stateIcon: String {
        switch action.state {
        case .pending: return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var stateColor: Color {
        switch action.state {
        case .pending: return .orange
        case .processing: return .accentColor
        case .failed: return .red
        case .completed: return .green
        }
    }

    private var stateDescription: String {
        switch action.state {
        case .pending: return "Waiting to sync"
        case .processing: return "Syncing..."
        case .failed: return "Failed"
        case .completed: return "Completed"
        }
    }
}
