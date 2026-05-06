//
//  OfflineQueueBadge.swift
//  Palace
//
//  A small badge showing pending offline action count.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import SwiftUI

/// A small badge overlay showing the number of pending offline actions.
struct OfflineQueueBadge: View {
    @StateObject private var viewModel: OfflineQueueBadgeViewModel

    init(service: OfflineQueueService = .shared) {
        _viewModel = StateObject(wrappedValue: OfflineQueueBadgeViewModel(service: service))
    }

    var body: some View {
        if viewModel.count > 0 {
            ZStack {
                Circle()
                    .fill(viewModel.hasFailed ? Color.orange : Color.accentColor)
                    .frame(width: 18, height: 18)

                Text("\(viewModel.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
            .accessibilityLabel("\(viewModel.count) pending offline actions")
        }
    }
}

@MainActor
final class OfflineQueueBadgeViewModel: ObservableObject {
    @Published var count: Int = 0
    @Published var hasFailed: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init(service: OfflineQueueService = .shared) {
        service.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.count = status.totalActive
                self?.hasFailed = status.failedCount > 0
            }
            .store(in: &cancellables)
    }
}
