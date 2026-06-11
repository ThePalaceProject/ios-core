//
//  AudioSessionActivatorTests.swift
//  PalaceTests
//
//  WS-2 — CarPlay OpenAccess `.playerNotReady` crash (Crashlytics d45f5aa9).
//
//  Red-first tests for the bounded async retry-with-backoff that activates
//  the audio session during a CarPlay cold launch. The crash happens when a
//  single `AVAudioSession.setActive` refusal leaves the session inactive, so
//  the toolkit's OpenAccessPlayer reports not-ready and the CarPlay play
//  command hits `.playerNotReady`. `AudioSessionActivator` retries the
//  activation a bounded number of times before giving up, so the session has
//  time to become active before the play command is issued.
//
//  These tests drive the activator with injected closures (no real
//  AVAudioSession, no real sleeps) so every branch — first-try success,
//  transient-then-success, persistent-transient bounded at the cap,
//  non-retriable fail-fast, and the other-audio-playing skip — is exercised
//  deterministically and CI-safe.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import XCTest
@testable import Palace

@MainActor
final class AudioSessionActivatorTests: XCTestCase {

    /// Records calls made by the activator so each test can assert how many
    /// `setActive` attempts and `sleep` backoffs happened, and with what
    /// backoff durations.
    private final class Recorder {
        var setActiveCalls = 0
        var sleepDurations: [TimeInterval] = []
    }

    /// Builds an activator whose `setActive` throws the supplied errors (one
    /// per call, in order) and then succeeds once the error list is
    /// exhausted. A `nil` element means "succeed on this call".
    private func makeActivator(
        recorder: Recorder,
        maxAttempts: Int = 3,
        baseBackoff: TimeInterval = 0.05,
        backoffCap: TimeInterval = 0.5,
        otherAudioPlaying: Bool = false,
        failures: [NSError?]
    ) -> AudioSessionActivator {
        AudioSessionActivator(
            maxAttempts: maxAttempts,
            baseBackoff: baseBackoff,
            backoffCap: backoffCap,
            isOtherAudioPlaying: { otherAudioPlaying },
            setActive: {
                let index = recorder.setActiveCalls
                recorder.setActiveCalls += 1
                if index < failures.count, let error = failures[index] {
                    throw error
                }
                // No error queued for this call → activation succeeded.
            },
            sleep: { duration in
                recorder.sleepDurations.append(duration)
            }
        )
    }

    /// A retriable (transient) activation error — the code observed in
    /// Crashlytics d45f5aa9.
    private func transientError() -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: 561015905, userInfo: nil)
    }

    /// A terminal/non-retriable error the activator should NOT retry.
    private func terminalError() -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: 2003329396, userInfo: nil)
    }

    // MARK: - activate() outcomes

    func testActivate_succeedsFirstTry_returnsActivatedOneAttempt_noSleep() async {
        let recorder = Recorder()
        let activator = makeActivator(recorder: recorder, failures: [])

        let outcome = await activator.activate()

        XCTAssertEqual(outcome, .activated(attempts: 1))
        XCTAssertEqual(recorder.setActiveCalls, 1, "should activate exactly once on first-try success")
        XCTAssertTrue(recorder.sleepDurations.isEmpty, "no backoff sleep when activation succeeds immediately")
    }

    func testActivate_transientThenSuccess_retriesWithBackoff() async {
        let recorder = Recorder()
        // Fail twice (transient), succeed on the third attempt.
        let activator = makeActivator(
            recorder: recorder,
            failures: [transientError(), transientError()]
        )

        let outcome = await activator.activate()

        XCTAssertEqual(outcome, .activated(attempts: 3))
        XCTAssertEqual(recorder.setActiveCalls, 3, "two transient failures then a success = 3 attempts")
        // One backoff per retry (after attempt 1 and attempt 2); none after the success.
        XCTAssertEqual(recorder.sleepDurations.count, 2, "one backoff sleep per retry")
        // Exponential growth: attempt-2 backoff > attempt-1 backoff.
        XCTAssertEqual(recorder.sleepDurations[0], 0.05, accuracy: 0.0001)
        XCTAssertEqual(recorder.sleepDurations[1], 0.10, accuracy: 0.0001)
    }

    func testActivate_persistentTransient_isBoundedAtMaxAttempts() async {
        let recorder = Recorder()
        // Always throws transient — must stop at maxAttempts, never loop forever.
        let activator = makeActivator(
            recorder: recorder,
            maxAttempts: 4,
            failures: Array(repeating: transientError(), count: 10)
        )

        let outcome = await activator.activate()

        XCTAssertEqual(outcome, .failed(attempts: 4, lastErrorCode: 561015905))
        XCTAssertEqual(recorder.setActiveCalls, 4, "bounded at maxAttempts")
        XCTAssertEqual(recorder.sleepDurations.count, 3, "no backoff sleep after the final (failing) attempt")
    }

    func testActivate_nonRetriableError_failsImmediately_noRetry_noSleep() async {
        let recorder = Recorder()
        let activator = makeActivator(
            recorder: recorder,
            failures: [terminalError(), transientError(), transientError()]
        )

        let outcome = await activator.activate()

        XCTAssertEqual(outcome, .failed(attempts: 1, lastErrorCode: 2003329396))
        XCTAssertEqual(recorder.setActiveCalls, 1, "terminal error must not be retried")
        XCTAssertTrue(recorder.sleepDurations.isEmpty, "no backoff before a fail-fast terminal error")
    }

    func testActivate_otherAudioPlaying_skipsWithoutActivating() async {
        let recorder = Recorder()
        let activator = makeActivator(
            recorder: recorder,
            otherAudioPlaying: true,
            failures: []
        )

        let outcome = await activator.activate()

        XCTAssertEqual(outcome, .skippedOtherAudioPlaying)
        XCTAssertEqual(recorder.setActiveCalls, 0, "must not activate while other audio is playing")
        XCTAssertTrue(recorder.sleepDurations.isEmpty)
    }

    // MARK: - isRetriable (pure)

    func testIsRetriable_transientActivationCodes_areRetriable() {
        XCTAssertTrue(AudioSessionActivator.isRetriable(errorCode: 561015905),
                      "the d45f5aa9 Crashlytics code must be retriable")
        XCTAssertTrue(AudioSessionActivator.isRetriable(errorCode: -50),
                      "paramErr (-50) in the early-launch window must be retriable")
        XCTAssertTrue(AudioSessionActivator.isRetriable(errorCode: Int(AVAudioSession.ErrorCode.cannotStartPlaying.rawValue)))
        XCTAssertTrue(AudioSessionActivator.isRetriable(errorCode: Int(AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue)))
    }

    func testIsRetriable_terminalCodes_areNotRetriable() {
        XCTAssertFalse(AudioSessionActivator.isRetriable(errorCode: 2003329396),
                       "an unrelated/terminal OSStatus must not be retried")
        XCTAssertFalse(AudioSessionActivator.isRetriable(errorCode: 0))
    }

    // MARK: - backoff (pure)

    func testBackoff_isExponential_andClampedToCap() {
        XCTAssertEqual(AudioSessionActivator.backoff(forAttempt: 1, base: 0.05, cap: 0.5), 0.05, accuracy: 0.0001)
        XCTAssertEqual(AudioSessionActivator.backoff(forAttempt: 2, base: 0.05, cap: 0.5), 0.10, accuracy: 0.0001)
        XCTAssertEqual(AudioSessionActivator.backoff(forAttempt: 3, base: 0.05, cap: 0.5), 0.20, accuracy: 0.0001)
        // attempt 5 would be 0.05 * 16 = 0.8 > cap → clamped.
        XCTAssertEqual(AudioSessionActivator.backoff(forAttempt: 5, base: 0.05, cap: 0.5), 0.50, accuracy: 0.0001)
    }
}
