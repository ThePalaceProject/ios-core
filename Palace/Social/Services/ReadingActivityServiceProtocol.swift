//
//  ReadingActivityServiceProtocol.swift
//  Palace
//
//  Created for Social Features — activity service contract.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Contract for recording and querying reading activity events.
protocol ReadingActivityServiceProtocol {

    /// Publisher that emits the full activity list whenever it changes.
    var activitiesPublisher: AnyPublisher<[ReadingActivity], Never> { get }

    /// Records a new activity event.
    func recordActivity(_ activity: ReadingActivity)

    /// Returns all activities in reverse-chronological order.
    func allActivities() -> [ReadingActivity]

    /// Returns activities filtered by type, reverse-chronological.
    func activities(ofType type: ReadingActivity.ActivityType) -> [ReadingActivity]

    /// Returns the total number of recorded activities.
    func activityCount() -> Int
}
