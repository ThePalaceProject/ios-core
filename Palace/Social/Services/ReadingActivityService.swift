//
//  ReadingActivityService.swift
//  Palace
//
//  Created for Social Features — local activity feed persistence.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Records reading activities locally with automatic pruning at 500 events.
final class ReadingActivityService: ReadingActivityServiceProtocol {

    // MARK: - Storage

    private let userDefaults: UserDefaults
    private static let storageKey = "palace.social.readingActivities"

    /// Maximum number of events to keep before pruning oldest entries.
    static let maxEvents = 500

    // MARK: - Combine

    private let activitiesSubject: CurrentValueSubject<[ReadingActivity], Never>

    var activitiesPublisher: AnyPublisher<[ReadingActivity], Never> {
        activitiesSubject.eraseToAnyPublisher()
    }

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let loaded = Self.load(from: userDefaults)
        self.activitiesSubject = CurrentValueSubject(loaded)
    }

    // MARK: - Recording

    func recordActivity(_ activity: ReadingActivity) {
        var activities = activitiesSubject.value
        activities.append(activity)

        // Prune oldest events if over limit
        if activities.count > Self.maxEvents {
            activities.sort { $0.timestamp > $1.timestamp }
            activities = Array(activities.prefix(Self.maxEvents))
        }

        save(activities)
    }

    // MARK: - Queries

    func allActivities() -> [ReadingActivity] {
        activitiesSubject.value.sorted { $0.timestamp > $1.timestamp }
    }

    func activities(ofType type: ReadingActivity.ActivityType) -> [ReadingActivity] {
        allActivities().filter { $0.type == type }
    }

    func activityCount() -> Int {
        activitiesSubject.value.count
    }

    // MARK: - Persistence

    private func save(_ activities: [ReadingActivity]) {
        activitiesSubject.send(activities)
        guard let data = try? JSONEncoder().encode(activities) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from userDefaults: UserDefaults) -> [ReadingActivity] {
        guard let data = userDefaults.data(forKey: storageKey),
              let activities = try? JSONDecoder().decode([ReadingActivity].self, from: data) else {
            return []
        }
        return activities
    }
}
