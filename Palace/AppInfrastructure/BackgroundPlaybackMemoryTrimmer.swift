//
//  BackgroundPlaybackMemoryTrimmer.swift
//  Palace
//
//  Releases memory that only screens use while the app is in the background
//  and an audiobook is playing (PP-5581).
//

import Combine
import Foundation
import UIKit

/// Trims once per background period, when the app is in the background and
/// playback is on, whichever comes first; a playback start from the lock
/// screen counts. In the foreground it never trims, so nothing on screen
/// changes. Returning to the foreground after a trim runs `restore`.
@MainActor
final class BackgroundPlaybackMemoryTrimmer {
    /// Stages a return to the foreground redraws from without a placeholder or
    /// a fetch: feeds the screens already hold, and the memory layer of disk
    /// caches. Not book cells or decoded images: new cells would start as
    /// placeholders and the decoded-image release slows decoding for 60 s, so
    /// every visible cover would flash. Not the LCP decrypt cache, which feeds
    /// the player, nor downloads, disk or network responses.
    static let stages: Set<MemoryReleaseStage> = [.catalogFeeds, .cachedData]

    private var inBackground: Bool
    private var playing = false
    private var trimmedThisPeriod = false
    private let trim: @MainActor () -> Void
    private let restore: @MainActor () -> Void
    private var subscriptions = Set<AnyCancellable>()

    /// Notifications and `isPlaying` must arrive on the main thread, as UIKit
    /// and the session manager send them.
    init(
        center: NotificationCenter = .default,
        isPlaying: AnyPublisher<Bool, Never>,
        startsInBackground: Bool,
        trim: @escaping @MainActor () -> Void,
        restore: @escaping @MainActor () -> Void
    ) {
        inBackground = startsInBackground
        self.trim = trim
        self.restore = restore
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.didEnterBackground() } }
            .store(in: &subscriptions)
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.willEnterForeground() } }
            .store(in: &subscriptions)
        isPlaying
            .sink { [weak self] playing in MainActor.assumeIsolated { self?.playbackChanged(playing) } }
            .store(in: &subscriptions)
    }

    private func didEnterBackground() {
        inBackground = true
        trimIfNeeded()
    }

    private func willEnterForeground() {
        inBackground = false
        guard trimmedThisPeriod else { return }
        trimmedThisPeriod = false
        restore()
    }

    private func playbackChanged(_ isPlaying: Bool) {
        playing = isPlaying
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        guard inBackground, playing, !trimmedThisPeriod else { return }
        trimmedThisPeriod = true
        trim()
    }
}
