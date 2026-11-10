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
    /// Whether `state` means audio is coming out. Loading and paused do not.
    nonisolated static func isPlaying(_ state: AudiobookSessionState) -> Bool {
        if case .playing = state { return true }
        return false
    }

    /// The session's playing state, current value first, then each change.
    static func isAudioPlaying(from session: AudiobookSessionManaging) -> AnyPublisher<Bool, Never> {
        session.playbackStatePublisher
            .map(isPlaying)
            .prepend(session.isPlaying)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Emits once each time the app stops being visible, and on every
    /// `.telemetryUpload` tick while the app is visible or audio plays. Paused
    /// in the background no timer is armed; the next visible tick sends.
    /// The visibility at subscription is skipped, so a launch in the
    /// background does not count as going to the background.
    static func triggers(
        from policy: ActivityPolicy,
        isAudioPlaying: AnyPublisher<Bool, Never>
    ) -> AnyPublisher<Void, Never> {
        let ticks = policy.ticks(for: .telemetryUpload)
        let scheduledSends = Publishers.CombineLatest(
            policy.statePublisher.map(ActivityRules.isVisible),
            isAudioPlaying
        )
        .map { isVisible, isPlaying in isVisible || isPlaying }
        .removeDuplicates()
        .map { shouldTick -> AnyPublisher<Date, Never> in
            shouldTick ? ticks : Empty().eraseToAnyPublisher()
        }
        .switchToLatest()

        return Publishers.Merge(
            scheduledSends.map { _ in () },
            policy.visibilityChanges.filter { !$0 }.map { _ in () }
        )
        .eraseToAnyPublisher()
    }
}
