//
//  AudiobookAudioWaitPhase.swift
//  Palace
//
//  What the player shows while a patron waits for audio after playback has
//  begun: a chapter change, a skip into another chapter, or a scrub. PP-5399.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation

extension AudiobookMorphingPlayerView {

    /// How long the current wait for audio has run, as the controls show it.
    enum AudioWaitPhase: Equatable {
        /// No wait, or one too short to notice.
        case none
        /// The touched control shows it is working.
        case busy
        /// Long enough that silence reads as a hang, so it is said in words.
        case slow
    }

    nonisolated static let audioWaitBusyThreshold: TimeInterval = 0.6
    nonisolated static let audioWaitSlowThreshold: TimeInterval = 8

    /// Whether the patron is waiting for audio.
    ///
    /// Neither input is enough alone. A chapter change unloads the player until
    /// its seek lands, and the streaming player then marks itself loaded on a
    /// fixed delay whether or not audio plays; AVFoundation's own waiting state
    /// covers that second stretch. Before the first playback the loading overlay
    /// already shows the wait.
    nonisolated static func isAwaitingAudio(
        hasStartedPlayback: Bool,
        isLoaded: Bool,
        transportIsWaitingForData: Bool
    ) -> Bool {
        hasStartedPlayback && (!isLoaded || transportIsWaitingForData)
    }

    /// The phase of a wait that has run for `elapsed`, or `.none` when there is
    /// no wait.
    nonisolated static func audioWaitPhase(waitingFor elapsed: TimeInterval?) -> AudioWaitPhase {
        guard let elapsed, elapsed >= audioWaitBusyThreshold else { return .none }
        return elapsed >= audioWaitSlowThreshold ? .slow : .busy
    }

    /// One sample of the wait: when it began, and the phase to show. A wait
    /// keeps the start it already has, so the phase can grow, and ends the
    /// moment the player stops waiting, so nothing is left on screen after it.
    nonisolated static func nextAudioWait(
        startedAt: Date?,
        waiting: Bool,
        now: Date
    ) -> (startedAt: Date?, phase: AudioWaitPhase) {
        guard waiting else { return (nil, .none) }
        let start = startedAt ?? now
        return (start, audioWaitPhase(waitingFor: now.timeIntervalSince(start)))
    }
}
