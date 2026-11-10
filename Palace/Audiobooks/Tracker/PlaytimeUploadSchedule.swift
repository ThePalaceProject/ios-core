//
//  PlaytimeUploadSchedule.swift
//  Palace
//
//  When the shared play-time uploader sends its queue (PP-5508).
//

import Combine
import Foundation

@MainActor
enum PlaytimeUploadSchedule {
    /// Emits on every `.telemetryUpload` tick and once each time the app
    /// stops being visible. The value at subscription is skipped, so a launch
    /// in the background does not count as going to the background.
    static func triggers(from policy: ActivityPolicy) -> AnyPublisher<Void, Never> {
        Publishers.Merge(
            policy.ticks(for: .telemetryUpload).map { _ in () },
            policy.visibilityChanges.filter { !$0 }.map { _ in () }
        )
        .eraseToAnyPublisher()
    }
}
