//
//  ActivityFeedViewModel.swift
//  Palace
//
//  Created for Social Features — manages the activity feed timeline.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// ViewModel for the reading activity feed.
@MainActor
final class ActivityFeedViewModel: ObservableObject {

    // MARK: - Published State

    @Published var activities: [ReadingActivity] = []
    @Published var filterType: ReadingActivity.ActivityType?

    // MARK: - Dependencies

    private let activityService: ReadingActivityServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(activityService: ReadingActivityServiceProtocol) {
        self.activityService = activityService

        activityService.activitiesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshActivities()
            }
            .store(in: &cancellables)

        refreshActivities()
    }

    // MARK: - Actions

    func setFilter(_ type: ReadingActivity.ActivityType?) {
        filterType = type
        refreshActivities()
    }

    func clearFilter() {
        filterType = nil
        refreshActivities()
    }

    // MARK: - Grouping

    /// Grouped activities for display: "Today", "Yesterday", "This Week", "Earlier".
    var groupedActivities: [(String, [ReadingActivity])] {
        let calendar = Calendar.current
        let now = Date()

        var today: [ReadingActivity] = []
        var yesterday: [ReadingActivity] = []
        var thisWeek: [ReadingActivity] = []
        var earlier: [ReadingActivity] = []

        for activity in activities {
            if calendar.isDateInToday(activity.timestamp) {
                today.append(activity)
            } else if calendar.isDateInYesterday(activity.timestamp) {
                yesterday.append(activity)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      activity.timestamp > weekAgo {
                thisWeek.append(activity)
            } else {
                earlier.append(activity)
            }
        }

        var groups: [(String, [ReadingActivity])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !earlier.isEmpty { groups.append(("Earlier", earlier)) }
        return groups
    }

    // MARK: - Private

    private func refreshActivities() {
        if let type = filterType {
            activities = activityService.activities(ofType: type)
        } else {
            activities = activityService.allActivities()
        }
    }
}
