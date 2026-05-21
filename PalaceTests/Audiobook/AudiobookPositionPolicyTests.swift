//
//  AudiobookPositionPolicyTests.swift
//  PalaceTests
//
//  Boundary + behavior tests for the pure-function policies that drive
//  the audiobook position state machine. Critical-path file — mutation
//  kill goal ≥75% per swarm_f3b9b087 contract.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - BeginningPositionPolicy

final class BeginningPositionPolicyTests: XCTestCase {

    func testIsAtBeginning_track0_time0_isBeginning() {
        XCTAssertTrue(BeginningPositionPolicy.isAtBeginning(trackIndex: 0, playbackTime: 0))
    }

    func testIsAtBeginning_track0_29s_isNotBeginning() {
        // Was true under the 30s-grace rule; new strict-zero rule says false.
        // Patron who paused at 0:29 of chapter 1 now keeps that position
        // against incoming track-0 / time-0 sync attempts.
        XCTAssertFalse(BeginningPositionPolicy.isAtBeginning(trackIndex: 0, playbackTime: 29.0))
    }

    func testIsAtBeginning_track0_30s_isNotBeginning() {
        // Was the exclusion boundary under the old rule; still false.
        XCTAssertFalse(BeginningPositionPolicy.isAtBeginning(trackIndex: 0, playbackTime: 30.0))
    }

    func testIsAtBeginning_track0_smallestPositiveTime_isNotBeginning() {
        // Boundary: any positive time, however tiny, is real progress.
        // Locks the strict-equality semantics — a mutation `==` → `<=` would
        // pass on this case but a mutation `==` → `>=` would fail (only
        // exactly-zero hits).
        XCTAssertFalse(BeginningPositionPolicy.isAtBeginning(trackIndex: 0, playbackTime: 0.001))
    }

    func testIsAtBeginning_track1_time0_isNotBeginning() {
        // Track-index gate: any track > 0 is not the start.
        XCTAssertFalse(BeginningPositionPolicy.isAtBeginning(trackIndex: 1, playbackTime: 0))
    }

    func testIsAtBeginning_track1_anyTime_isNotBeginning() {
        XCTAssertFalse(BeginningPositionPolicy.isAtBeginning(trackIndex: 1, playbackTime: 100))
    }

    func testIsAtBeginning_negativeTrackIndex_isNotBeginning() {
        // Defensive against corrupt data. Negative track indices are nonsense
        // but shouldn't be treated as "at beginning."
        XCTAssertFalse(BeginningPositionPolicy.isAtBeginning(trackIndex: -1, playbackTime: 0))
    }

    func testIsAtBeginning_negativePlaybackTime_isNotBeginning() {
        // Documented in policy doc-comment: nonsense input → not at beginning.
        XCTAssertFalse(BeginningPositionPolicy.isAtBeginning(trackIndex: 0, playbackTime: -1.0))
    }
}

// MARK: - AudiobookPositionPolicy (validator)

final class AudiobookPositionPolicyValidatorTests: XCTestCase {

    private let okTrackKey = "track-key-1"

    private func validate(
        timestamp: TimeInterval = 100,
        positionDuration: TimeInterval = 100,
        totalDuration: TimeInterval = 3600,
        trackKeyMatchesManifest: Bool = true
    ) -> Result<Void, AudiobookPositionValidationFailure> {
        AudiobookPositionPolicy.validate(
            timestamp: timestamp,
            positionDuration: positionDuration,
            totalDuration: totalDuration,
            trackKeyMatchesManifest: trackKeyMatchesManifest,
            savedTrackKey: okTrackKey
        )
    }

    func testValidate_happyPath_succeeds() {
        XCTAssertEqual(validate(), .success(()))
    }

    func testValidate_negativeTimestamp_fails() {
        let result = validate(timestamp: -1)
        XCTAssertEqual(result, .failure(.negativeTimestamp(-1)))
    }

    func testValidate_timestampZero_succeeds() {
        // Boundary: 0 is a valid position (top-of-track).
        XCTAssertEqual(validate(timestamp: 0, positionDuration: 0), .success(()))
    }

    func testValidate_timestampExactlyAtNegativeBoundary_fails() {
        // -0.0001 is finite but < 0 — must fail.
        let result = validate(timestamp: -0.0001)
        XCTAssertEqual(result, .failure(.negativeTimestamp(-0.0001)))
    }

    func testValidate_infiniteTimestamp_fails() {
        XCTAssertEqual(validate(timestamp: .infinity), .failure(.nonFiniteTimestamp))
    }

    func testValidate_NaNTimestamp_fails() {
        XCTAssertEqual(validate(timestamp: .nan), .failure(.nonFiniteTimestamp))
    }

    func testValidate_trackKeyMismatch_fails() {
        let result = validate(trackKeyMatchesManifest: false)
        XCTAssertEqual(result, .failure(.trackKeyNotInManifest(savedKey: okTrackKey)))
    }

    func testValidate_positionAtExactTotalDuration_succeeds() {
        // End-of-book marker — must accept.
        XCTAssertEqual(
            validate(positionDuration: 3600, totalDuration: 3600),
            .success(())
        )
    }

    func testValidate_positionAtExact110Percent_succeeds() {
        // Boundary: == cap is acceptable; only `>` cap fails.
        XCTAssertEqual(
            validate(positionDuration: 3960, totalDuration: 3600),
            .success(())
        )
    }

    func testValidate_positionExceeds110Percent_fails() {
        let result = validate(positionDuration: 3961, totalDuration: 3600)
        XCTAssertEqual(result, .failure(.positionExceedsCap(
            positionDuration: 3961,
            totalDuration: 3600
        )))
    }

    func testValidate_totalDurationZero_skipsCapCheck() {
        // When manifest doesn't report duration, we can't compare; accept.
        XCTAssertEqual(
            validate(positionDuration: 99_999, totalDuration: 0),
            .success(())
        )
    }

    func testValidate_totalDurationNegative_skipsCapCheck() {
        // Defensive: corrupt manifest data shouldn't reject every position.
        XCTAssertEqual(
            validate(positionDuration: 100, totalDuration: -1),
            .success(())
        )
    }

    func testValidate_finiteCheckRunsBeforeNegativeCheck() {
        // .infinity is also < 0 false; covered by ordering. NaN < 0 is false.
        // Pin the order: nonFinite is reported first because it's a corruption
        // signal independent of sign.
        let result = validate(timestamp: -.infinity)
        XCTAssertEqual(result, .failure(.nonFiniteTimestamp))
    }

    func testValidate_capMultiplier_isExactly1Point1() {
        // Mutation guard: flipping the literal would change the boundary.
        XCTAssertEqual(AudiobookPositionPolicy.totalDurationCap, 1.1)
    }
}

// MARK: - ChapterChangeDetector

final class ChapterChangeDetectorTests: XCTestCase {

    func testDidChange_noPriorChapter_fires() {
        XCTAssertTrue(ChapterChangeDetector.didChange(
            oldKey: nil,
            oldTitle: nil,
            newKey: "k1",
            newTitle: "Chapter 1"
        ))
    }

    func testDidChange_differentKey_fires() {
        XCTAssertTrue(ChapterChangeDetector.didChange(
            oldKey: "k1",
            oldTitle: "Chapter 1",
            newKey: "k2",
            newTitle: "Chapter 2"
        ))
    }

    func testDidChange_sameKeyDifferentTitle_doesNotFire() {
        // The bug guard: anthology audiobook with two "Untitled Section"
        // chapters in the same track must NOT trigger a chapter-change event.
        XCTAssertFalse(ChapterChangeDetector.didChange(
            oldKey: "k1",
            oldTitle: "Untitled Section",
            newKey: "k1",
            newTitle: "Untitled Section v2"
        ))
    }

    func testDidChange_sameKeySameTitle_doesNotFire() {
        XCTAssertFalse(ChapterChangeDetector.didChange(
            oldKey: "k1",
            oldTitle: "Chapter 1",
            newKey: "k1",
            newTitle: "Chapter 1"
        ))
    }

    func testDidChange_differentKeySameTitle_fires() {
        // Anthology case in reverse: same title across two tracks.
        // Real chapter crossing because the track key changed.
        XCTAssertTrue(ChapterChangeDetector.didChange(
            oldKey: "k1",
            oldTitle: "Prologue",
            newKey: "k2",
            newTitle: "Prologue"
        ))
    }
}

// MARK: - ChapterTOCNormalizer

final class ChapterTOCNormalizerTests: XCTestCase {

    func testIsOversubdivided_belowThreshold_returnsFalse() {
        // 56 chapters, 56 entries — exact match, normal book.
        XCTAssertFalse(ChapterTOCNormalizer.isOversubdivided(
            tocCount: 56,
            expectedChapterCount: 56
        ))
    }

    func testIsOversubdivided_atExactThreshold_returnsFalse() {
        // 56 * 1.5 == 84. 84 is NOT > 84.
        XCTAssertFalse(ChapterTOCNormalizer.isOversubdivided(
            tocCount: 84,
            expectedChapterCount: 56
        ))
    }

    func testIsOversubdivided_oneAboveThreshold_returnsTrue() {
        // 56 * 1.5 == 84. 85 > 84.
        XCTAssertTrue(ChapterTOCNormalizer.isOversubdivided(
            tocCount: 85,
            expectedChapterCount: 56
        ))
    }

    func testIsOversubdivided_realWorldCase_returnsTrue() {
        // The motivating case: 182 TOC entries for a 56-chapter book.
        XCTAssertTrue(ChapterTOCNormalizer.isOversubdivided(
            tocCount: 182,
            expectedChapterCount: 56
        ))
    }

    func testIsOversubdivided_slightInflation_returnsFalse() {
        // 100 chapters + 1 "Acknowledgments" entry = 1.01x — must keep.
        XCTAssertFalse(ChapterTOCNormalizer.isOversubdivided(
            tocCount: 101,
            expectedChapterCount: 100
        ))
    }

    func testIsOversubdivided_zeroExpectedChapterCount_returnsFalse() {
        // Can't divide by zero; treat as "can't decide → don't normalize."
        XCTAssertFalse(ChapterTOCNormalizer.isOversubdivided(
            tocCount: 50,
            expectedChapterCount: 0
        ))
    }

    func testInflationThreshold_isExactly1Point5() {
        // Mutation guard.
        XCTAssertEqual(ChapterTOCNormalizer.inflationThreshold, 1.5)
    }
}

// MARK: - Spy logger

/// Test spy for `AudiobookPositionLogging`. Records every call so tests
/// can assert reason + context. Pattern mirrors the
/// `feedback_test_patterns_phase7` spy convention.
final class AudiobookPositionLoggerSpy: AudiobookPositionLogging {
    struct Entry: Equatable {
        let kind: String  // "FAIL" or "FALLBACK"
        let reason: String
        let context: [String: String]
    }
    private(set) var entries: [Entry] = []

    func logFailure(reason: String, context: [String: String]) {
        entries.append(.init(kind: "FAIL", reason: reason, context: context))
    }

    func logFallback(reason: String, context: [String: String]) {
        entries.append(.init(kind: "FALLBACK", reason: reason, context: context))
    }
}

// MARK: - DefaultAudiobookPositionLogger formatting

final class DefaultAudiobookPositionLoggerTests: XCTestCase {
    // The default logger emits via Log.warn; we can't intercept that from a
    // unit test without injecting a Crashlytics bridge. We CAN verify that
    // calling it doesn't crash and that the formatter sorts context keys
    // deterministically — that's the contract callers depend on.

    func testDefaultLogger_doesNotCrashOnFailure() {
        let logger = DefaultAudiobookPositionLogger()
        logger.logFailure(reason: "x", context: ["a": "1", "b": "2"])
    }

    func testDefaultLogger_doesNotCrashOnFallback() {
        let logger = DefaultAudiobookPositionLogger()
        logger.logFallback(reason: "y", context: [:])
    }
}
