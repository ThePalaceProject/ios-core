//
//  AudioSessionActivator.swift
//  Palace
//
//  Bounded async retry-with-backoff for activating the audio session.
//  On a cold CarPlay connect `AVAudioSession.setActive(true)` can transiently
//  fail (OSStatus 561015905, or -50 very early); a single failed attempt left
//  the session inactive and OpenAccessPlayer then failed with `.playerNotReady`
//  (Crashlytics d45f5aa9). The retry is async because it runs on the main actor
//  during launch, where a synchronous sleep would block for up to ~1s.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import Foundation

// MARK: - AudioSessionActivator

/// Bounded, async retry-with-backoff for activating the audio session.
///
/// The activation primitives are injected as closures so the retry loop is
/// testable without a real `AVAudioSession`: production binds the closures to
/// `AVAudioSession.sharedInstance()` + `Task.sleep`; tests bind recording
/// stubs that fail a scripted number of times before succeeding.
///
/// Internal — no consumer outside the audiobook playback bootstrap needs it,
/// so it adds no public API surface.
struct AudioSessionActivator {

    // MARK: - Outcome

    /// Terminal result of an activation attempt sequence.
    enum Outcome: Equatable {
        /// Activation succeeded; `attempts` is the number of `setActive`
        /// calls it took (1 = first try).
        case activated(attempts: Int)
        /// Skipped because another app was already playing audio — Palace
        /// should not steal the session in that case.
        case skippedOtherAudioPlaying
        /// Activation never succeeded; `attempts` is how many were made and
        /// `lastErrorCode` is the final activation error's OSStatus.
        case failed(attempts: Int, lastErrorCode: Int)
    }

    // MARK: - Configuration

    /// Maximum number of `setActive` attempts. Bounded — there is no
    /// unbounded retry. Default 3.
    let maxAttempts: Int
    /// Base backoff in seconds for the first retry; grows exponentially.
    let baseBackoff: TimeInterval
    /// Upper clamp on a single backoff interval, so a few retries never sum
    /// to a perceptible stall.
    let backoffCap: TimeInterval

    // MARK: - Injected seams

    /// Whether another app currently owns audio playback.
    let isOtherAudioPlaying: () -> Bool
    /// Performs the activation; throws on refusal.
    let setActive: () throws -> Void
    /// Suspends for the supplied number of seconds (the backoff).
    let sleep: (TimeInterval) async -> Void

    init(
        maxAttempts: Int = 3,
        baseBackoff: TimeInterval = 0.05,
        backoffCap: TimeInterval = 0.5,
        isOtherAudioPlaying: @escaping () -> Bool,
        setActive: @escaping () throws -> Void,
        sleep: @escaping (TimeInterval) async -> Void
    ) {
        self.maxAttempts = maxAttempts
        self.baseBackoff = baseBackoff
        self.backoffCap = backoffCap
        self.isOtherAudioPlaying = isOtherAudioPlaying
        self.setActive = setActive
        self.sleep = sleep
    }

    // MARK: - Pure classification / scheduling

    /// OSStatus codes that warrant a retry — transient activation refusals
    /// seen during a CarPlay cold launch. Anything else is treated as
    /// terminal and is NOT retried (fail fast).
    ///
    /// - `561015905` — observed in Crashlytics d45f5aa9 for this crash.
    /// - `-50` (paramErr) — early-launch window before scenes connect.
    /// - `cannotStartPlaying` / `cannotInterruptOthers` — the AVAudioSession
    ///   activation-contention codes.
    private static let retriableCodes: Set<Int> = [
        561015905,
        -50,
        Int(AVAudioSession.ErrorCode.cannotStartPlaying.rawValue),
        Int(AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue)
    ]

    /// Pure predicate: should an activation failure with this OSStatus be
    /// retried?
    static func isRetriable(errorCode: Int) -> Bool {
        retriableCodes.contains(errorCode)
    }

    /// Pure backoff schedule: exponential (`base * 2^(attempt-1)`) clamped to
    /// `cap`. `attempt` is 1-based (the first retry uses attempt 1).
    static func backoff(forAttempt attempt: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let raw = base * pow(2.0, Double(exponent))
        return min(raw, cap)
    }

    // MARK: - Activation loop

    /// Runs the bounded activation loop. `@MainActor` because
    /// `AVAudioSession` activation must happen on the main thread (see the
    /// `AudiobookSamplePlayer` -50 note); production drives this from a
    /// `Task { @MainActor }` so the synchronous CarPlay `didConnect` path is
    /// never blocked.
    @MainActor
    func activate() async -> Outcome {
        if isOtherAudioPlaying() {
            return .skippedOtherAudioPlaying
        }

        var lastErrorCode = 0
        for attempt in 1...max(1, maxAttempts) {
            do {
                try setActive()
                return .activated(attempts: attempt)
            } catch {
                let code = (error as NSError).code
                lastErrorCode = code

                // Terminal error → fail fast, no backoff, no further attempts.
                guard Self.isRetriable(errorCode: code) else {
                    return .failed(attempts: attempt, lastErrorCode: code)
                }

                // Bounded: never sleep after the final attempt.
                if attempt == max(1, maxAttempts) {
                    break
                }

                await sleep(Self.backoff(forAttempt: attempt, base: baseBackoff, cap: backoffCap))
            }
        }

        return .failed(attempts: max(1, maxAttempts), lastErrorCode: lastErrorCode)
    }
}
