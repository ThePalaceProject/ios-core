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

@MainActor
final class BackgroundPlaybackMemoryTrimmer {
    /// The release stages a trim runs.
    static let stages: Set<MemoryReleaseStage> = []

    init(
        center: NotificationCenter = .default,
        isPlaying: AnyPublisher<Bool, Never>,
        startsInBackground: Bool,
        trim: @escaping @MainActor () -> Void,
        restore: @escaping @MainActor () -> Void
    ) {}
}
