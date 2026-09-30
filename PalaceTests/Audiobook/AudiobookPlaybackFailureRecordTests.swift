//
//  AudiobookPlaybackFailureRecordTests.swift
//  PalaceTests
//
//  PP-5242: the Crashlytics record for an audiobook `.playbackFailed` must carry
//  the cause AVFoundation moves into `NSUnderlyingError`, the content source the
//  player was reading from, whether the failure was at the start of a track, and
//  must not be re-sent for repeats of the same failure.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit
import PalaceBookModel

// MARK: - Record builder: underlying chain, content source, track start

final class PlaybackFailureRecordCauseTests: XCTestCase {

    /// The shape AVFoundation hands back when an `AVAssetResourceLoader`
    /// delegate fails a request with `NSError(domain: "LCPResourceLoader", code: X)`:
    /// the top-level domain is replaced, the original code survives only as an
    /// `NSOSStatusErrorDomain` underlying error.
    private func avFoundationWrappedLoaderError(originalCode: Int) -> NSError {
        let osStatus = NSError(domain: NSOSStatusErrorDomain, code: originalCode)
        return NSError(
            domain: AVFoundationErrorDomainName,
            code: -11800,
            userInfo: [NSUnderlyingErrorKey: osStatus]
        )
    }

    private let AVFoundationErrorDomainName = "AVFoundationErrorDomain"

    private func record(
        _ error: Error?,
        position: TrackPosition? = nil,
        contentSource: AudiobookContentSource = .unknown,
        secondsSincePreviousFailureForBook: TimeInterval? = nil
    ) -> [String: Any] {
        AudiobookSessionManager.buildPlaybackFailureRecord(
            error: error,
            position: position,
            bookId: "book-1",
            contentSource: contentSource,
            secondsSincePreviousFailureForBook: secondsSincePreviousFailureForBook
        ).userInfo
    }

    private func position(at timestamp: Double) throws -> TrackPosition {
        let manifest = try Manifest.from(jsonFileName: ManifestJSON.snowcrash.rawValue, bundle: Bundle(for: type(of: self)))
        let tracks = Tracks(manifest: manifest, audiobookID: "PP5242", token: nil)
        let track = try XCTUnwrap(tracks.tracks.first)
        return TrackPosition(track: track, timestamp: timestamp, tracks: tracks)
    }

    func testRecord_AVFoundationWrappedLoaderError_KeepsTheOriginalCodeFromTheUnderlyingError() {
        let info = record(avFoundationWrappedLoaderError(originalCode: 12345))

        XCTAssertEqual(info["underlyingDomain"] as? String, "AVFoundationErrorDomain",
                       "the existing top-level key must keep its meaning for current dashboards")
        XCTAssertEqual(info["underlyingCode"] as? Int, -11800)
        XCTAssertEqual(info["underlyingErrorDomain"] as? String, NSOSStatusErrorDomain)
        XCTAssertEqual(info["underlyingErrorCode"] as? Int, 12345,
                       "the loader's original code is only recoverable from NSUnderlyingError")
    }

    func testRecord_TimeoutRewrittenToURLDomain_StillRecordsTheUnderlyingOSStatus() {
        // A loader code of -1001 comes back as NSURLErrorDomain -1001; the
        // underlying OSStatus is what distinguishes it from a real URL timeout.
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -1001)]
        )
        let info = record(error)

        XCTAssertEqual(info["underlyingErrorDomain"] as? String, NSOSStatusErrorDomain)
        XCTAssertEqual(info["underlyingErrorCode"] as? Int, -1001)
    }

    func testRecord_TwoLevelChain_RecordsBothLevelsInOrder() {
        let innermost = NSError(domain: "CoreMediaErrorDomain", code: -12873)
        let middle = NSError(domain: NSOSStatusErrorDomain, code: -11849,
                             userInfo: [NSUnderlyingErrorKey: innermost])
        let top = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                          userInfo: [NSUnderlyingErrorKey: middle])
        let info = record(top)

        XCTAssertEqual(info["underlyingErrorDomain"] as? String, NSOSStatusErrorDomain)
        XCTAssertEqual(info["underlyingErrorCode"] as? Int, -11849)
        XCTAssertEqual(info["underlyingErrorDomain2"] as? String, "CoreMediaErrorDomain")
        XCTAssertEqual(info["underlyingErrorCode2"] as? Int, -12873)
        XCTAssertNil(info["underlyingErrorDomain3"], "the chain ended at two levels")
    }

    func testRecord_NoUnderlyingError_AddsNoUnderlyingErrorKeys() {
        let info = record(NSError(domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer", code: 2))

        XCTAssertNil(info["underlyingErrorDomain"])
        XCTAssertNil(info["underlyingErrorCode"])
        XCTAssertNil(info["underlyingErrorDomain2"])
    }

    func testRecord_NilError_AddsNoUnderlyingErrorKeys() {
        let info = record(nil)
        XCTAssertNil(info["underlyingErrorDomain"])
        XCTAssertNil(info["underlyingErrorCode"])
    }

    func testRecord_ChainDeeperThanThree_StopsAtThreeLevels() {
        var chain = NSError(domain: "level5", code: 5)
        for level in stride(from: 4, through: 0, by: -1) {
            chain = NSError(domain: "level\(level)", code: level,
                            userInfo: [NSUnderlyingErrorKey: chain])
        }
        let info = record(chain)

        XCTAssertEqual(info["underlyingErrorDomain"] as? String, "level1")
        XCTAssertEqual(info["underlyingErrorDomain2"] as? String, "level2")
        XCTAssertEqual(info["underlyingErrorDomain3"] as? String, "level3")
        XCTAssertEqual(info["underlyingErrorCode3"] as? Int, 3)
        XCTAssertNil(info["underlyingErrorDomain4"], "depth is bounded at three")
        XCTAssertNil(info["underlyingErrorCode4"])
    }

    func testRecord_ContentSource_IsRecordedAsItsRawValue() {
        XCTAssertEqual(record(nil, contentSource: .lcpStreamed)["contentSource"] as? String, "lcpStreamed")
        XCTAssertEqual(record(nil, contentSource: .findaway)["contentSource"] as? String, "findaway")
        XCTAssertEqual(record(nil)["contentSource"] as? String, "unknown")
    }

    func testRecord_PositionAtZero_IsAtTrackStart() throws {
        XCTAssertEqual(record(nil, position: try position(at: 0))["atTrackStart"] as? String, "true")
    }

    func testRecord_PositionPastZero_IsNotAtTrackStart() throws {
        XCTAssertEqual(record(nil, position: try position(at: 12.5))["atTrackStart"] as? String, "false")
    }

    func testRecord_PositionJustPastZero_IsNotAtTrackStart() throws {
        XCTAssertEqual(record(nil, position: try position(at: 0.001))["atTrackStart"] as? String, "false")
    }

    func testRecord_NilPosition_IsAtTrackStart() {
        let fields = record(nil, position: nil)
        XCTAssertEqual(fields["atTrackStart"] as? String, "true",
                       "no position means playback never reached a point inside a track")
        // `atTrackStart` cannot separate "failed at 0.0" from "no position data"
        // — both are true. `trackPosition` is the only thing that does, so a
        // reader depends on it being present. Pinned here rather than left to
        // the reader to notice.
        XCTAssertEqual(fields["trackPosition"] as? String, "unknown",
                       "the only field that distinguishes a nil position from a genuine 0.0")
    }

    func testRecord_SecondsSincePreviousFailure_IsRecordedInMilliseconds() {
        XCTAssertEqual(record(nil, secondsSincePreviousFailureForBook: 0.8)["msSincePreviousFailureForBook"] as? Int, 800)
    }

    func testRecord_NoPreviousFailure_OmitsTheInterval() {
        XCTAssertNil(record(nil)["msSincePreviousFailureForBook"])
    }

    func testRecord_NewKeysDoNotChangeTheRecordDomainOrCode() {
        let built = AudiobookSessionManager.buildPlaybackFailureRecord(
            error: avFoundationWrappedLoaderError(originalCode: 7),
            position: nil, bookId: "b", contentSource: .lcpLocal,
            secondsSincePreviousFailureForBook: 1
        )
        XCTAssertEqual(built.domain, "org.thepalaceproject.palace.audiobookPlayback")
        XCTAssertEqual(built.code, -11800)
    }
}

// MARK: - Repeat suppression

final class PlaybackFailureRecordDeduplicatorTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let window = PlaybackFailureRecordDeduplicator.repeatWindow

    func testRepeatWindow_IsSixtySeconds() {
        // Pinned because the justification (a 30s field re-report cadence)
        // depends on the window exceeding it.
        XCTAssertEqual(window, 60)
    }

    func testFirstFailure_IsRecorded_WithNoPreviousInterval() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        let decision = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        XCTAssertTrue(decision.shouldRecord)
        XCTAssertNil(decision.secondsSincePreviousFailureForBook)
    }

    /// The case the key exists for. AVFoundation reports almost every
    /// resource-loader failure as `AVFoundationErrorDomain -11800`, so keying on
    /// the top level alone would suppress the second of two genuinely different
    /// causes on the same book and never read its chain — worse than today,
    /// where both arrive generically.
    func testSameTopLevelDifferentUnderlyingCause_AreBothRecorded() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        let first = dedupe.evaluate(
            bookId: "a", domain: "AVFoundationErrorDomain", code: -11800,
            underlyingDomain: "NSOSStatusErrorDomain", underlyingCode: -12881, at: t0
        )
        let second = dedupe.evaluate(
            bookId: "a", domain: "AVFoundationErrorDomain", code: -11800,
            underlyingDomain: "NSURLErrorDomain", underlyingCode: -1009,
            at: t0.addingTimeInterval(5)
        )
        XCTAssertTrue(first.shouldRecord)
        XCTAssertTrue(second.shouldRecord, "a different underlying cause is a different failure")
    }

    /// And the suppression still works when the chain matches too — otherwise
    /// the key would never collapse anything under AVFoundation.
    func testSameTopLevelSameUnderlyingCause_IsSuppressed() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(
            bookId: "a", domain: "AVFoundationErrorDomain", code: -11800,
            underlyingDomain: "NSOSStatusErrorDomain", underlyingCode: -12881, at: t0
        )
        let repeated = dedupe.evaluate(
            bookId: "a", domain: "AVFoundationErrorDomain", code: -11800,
            underlyingDomain: "NSOSStatusErrorDomain", underlyingCode: -12881,
            at: t0.addingTimeInterval(5)
        )
        XCTAssertFalse(repeated.shouldRecord)
    }

    /// An error with no chain and one with a chain are not the same failure,
    /// even when their top level matches.
    func testChainPresentVersusAbsent_AreDistinctKeys() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        let withChain = dedupe.evaluate(
            bookId: "a", domain: "d", code: 1,
            underlyingDomain: "u", underlyingCode: 9, at: t0.addingTimeInterval(1)
        )
        XCTAssertTrue(withChain.shouldRecord)
    }

    func testSameKeyWithinWindow_IsSuppressed() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        XCTAssertFalse(dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0.addingTimeInterval(30)).shouldRecord)
    }

    func testBurstInTheSameInstant_RecordsOnlyTheFirst() {
        // One device logged 50 records in 47ms.
        var dedupe = PlaybackFailureRecordDeduplicator()
        let recorded = (0..<50).filter { i in
            dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0.addingTimeInterval(Double(i) * 0.001)).shouldRecord
        }
        XCTAssertEqual(recorded, [0])
    }

    func testSameKeyJustInsideWindow_IsSuppressed() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        XCTAssertFalse(dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0.addingTimeInterval(window - 0.001)).shouldRecord)
    }

    func testSameKeyAtOrAfterWindow_IsRecordedAgain() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        XCTAssertTrue(dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0.addingTimeInterval(window)).shouldRecord)
    }

    func testPeriodicReReport_StaysSuppressedWhileItKeepsArriving() {
        // Field shape: the same failure re-reported every 30s. A window measured
        // from the FIRST record would let every other report through; measured
        // from the latest occurrence, the run is recorded once.
        var dedupe = PlaybackFailureRecordDeduplicator()
        let recorded = (0..<10).filter { i in
            dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0.addingTimeInterval(Double(i) * 30)).shouldRecord
        }
        XCTAssertEqual(recorded, [0])
    }

    func testSameKeyAfterQuietPeriod_IsRecordedAgain() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0.addingTimeInterval(30))
        XCTAssertTrue(dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0.addingTimeInterval(30 + window)).shouldRecord)
    }

    func testDifferentBook_IsRecorded() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        XCTAssertTrue(dedupe.evaluate(bookId: "b", domain: "d", code: 1, at: t0.addingTimeInterval(1)).shouldRecord)
    }

    func testDifferentCode_SameBook_IsRecorded() {
        // The -11819 → code 2 follow-up: recorded, not suppressed. The interval
        // lets a reader identify it as a follow-up without hiding it.
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "AVFoundationErrorDomain", code: -11819, at: t0)
        let followUp = dedupe.evaluate(bookId: "a", domain: "OpenAccessPlayer", code: 2, at: t0.addingTimeInterval(0.8))
        XCTAssertTrue(followUp.shouldRecord)
        XCTAssertEqual(try XCTUnwrap(followUp.secondsSincePreviousFailureForBook), 0.8, accuracy: 0.0001)
    }

    func testDifferentDomain_SameCode_IsRecorded() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d1", code: 1, at: t0)
        XCTAssertTrue(dedupe.evaluate(bookId: "a", domain: "d2", code: 1, at: t0.addingTimeInterval(1)).shouldRecord)
    }

    func testPreviousFailureExactlyOneWindowAgo_DoesNotSetTheInterval() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        XCTAssertNil(dedupe.evaluate(bookId: "a", domain: "d", code: 2, at: t0.addingTimeInterval(window)).secondsSincePreviousFailureForBook)
    }

    func testPreviousFailureOfAnotherBook_DoesNotSetTheInterval() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        XCTAssertNil(dedupe.evaluate(bookId: "b", domain: "d", code: 2, at: t0.addingTimeInterval(1)).secondsSincePreviousFailureForBook)
    }

    func testPreviousFailureOutsideWindow_DoesNotSetTheInterval() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        XCTAssertNil(dedupe.evaluate(bookId: "a", domain: "d", code: 2, at: t0.addingTimeInterval(window + 1)).secondsSincePreviousFailureForBook)
    }

    func testIntervalIsMeasuredFromTheMostRecentFailure_IncludingSuppressedOnes() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0)
        _ = dedupe.evaluate(bookId: "a", domain: "d", code: 1, at: t0.addingTimeInterval(10))
        let next = dedupe.evaluate(bookId: "a", domain: "d", code: 2, at: t0.addingTimeInterval(12))
        XCTAssertEqual(try XCTUnwrap(next.secondsSincePreviousFailureForBook), 2, accuracy: 0.0001)
    }

    func testExpiredEntries_ArePruned() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        for i in 0..<20 {
            _ = dedupe.evaluate(bookId: "book-\(i)", domain: "d", code: i, at: t0)
        }
        _ = dedupe.evaluate(bookId: "late", domain: "d", code: 0, at: t0.addingTimeInterval(window + 1))
        XCTAssertEqual(dedupe.trackedKeyCount, 1, "entries older than the window must not accumulate for the life of the process")
    }

    // MARK: Composition: what actually reaches the sink

    func testRecordToSend_SuppressedRepeat_ReturnsNil() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11819)
        let first = AudiobookSessionManager.playbackFailureRecordToSend(
            error: error, position: nil, bookId: "a", contentSource: .lcpLocal,
            deduplicator: &dedupe, now: t0)
        let second = AudiobookSessionManager.playbackFailureRecordToSend(
            error: error, position: nil, bookId: "a", contentSource: .lcpLocal,
            deduplicator: &dedupe, now: t0.addingTimeInterval(1))

        XCTAssertEqual(first?.userInfo["contentSource"] as? String, "lcpLocal")
        XCTAssertNil(second, "a repeat within the window must not be sent")
    }

    /// Through the real send path, not the deduplicator directly.
    ///
    /// The three key tests above drive `evaluate` with explicit underlying
    /// arguments, so they pass whether or not anything threads the chain into
    /// it — nulling the wiring in `playbackFailureRecordToSend` left all of them
    /// green. This asserts the wiring: two AVFoundation errors identical at the
    /// top level and different underneath, both of which must reach the sink.
    func testRecordToSend_SameTopLevelDifferentCause_BothReachTheSink() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        let staleTrack = NSError(
            domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSOSStatusErrorDomain", code: -12881)]
        )
        let offline = NSError(
            domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSURLErrorDomain", code: -1009)]
        )
        let first = AudiobookSessionManager.playbackFailureRecordToSend(
            error: staleTrack, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0)
        let second = AudiobookSessionManager.playbackFailureRecordToSend(
            error: offline, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0.addingTimeInterval(2))

        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "a different cause under the same -11800 is a different failure")
        XCTAssertEqual(second?.userInfo["underlyingErrorCode"] as? Int, -1009,
                       "and the second record carries its own cause, not the first's")
    }

    /// Domain alone must discriminate, asserted through the producer.
    ///
    /// `testDifferentDomain_SameCode_IsRecorded` covers this at `evaluate`, but
    /// it passes explicit `domain:`/`code:` arguments, so it holds whether or
    /// not the producer threads the real ones. Replacing
    /// `domain: nsError?.domain` with a constant left the whole suite green.
    /// Same shape as the underlying-cause gap fixed earlier, one field over.
    func testRecordToSend_SameCodeDifferentDomain_BothReachTheSink() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        let avf = NSError(domain: "AVFoundationErrorDomain", code: -11800)
        let url = NSError(domain: "NSURLErrorDomain", code: -11800)
        let first = AudiobookSessionManager.playbackFailureRecordToSend(
            error: avf, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0)
        let second = AudiobookSessionManager.playbackFailureRecordToSend(
            error: url, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0.addingTimeInterval(2))
        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "same code in a different domain is a different failure")
    }

    /// And code alone, likewise through the producer: replacing
    /// `code: nsError?.code` with a constant also left the suite green.
    func testRecordToSend_SameDomainDifferentCode_BothReachTheSink() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        let unknown = NSError(domain: "AVFoundationErrorDomain", code: -11800)
        let notReady = NSError(domain: "AVFoundationErrorDomain", code: -11819)
        let first = AudiobookSessionManager.playbackFailureRecordToSend(
            error: unknown, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0)
        let second = AudiobookSessionManager.playbackFailureRecordToSend(
            error: notReady, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0.addingTimeInterval(2))
        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "a different code in the same domain is a different failure")
    }

    /// The cause's two fields, separately. `SameTopLevelDifferentCause` varies the
    /// cause in domain AND code at once, so it holds when either field alone is a
    /// constant — the other still tells the two failures apart. These two vary one
    /// field at a time, which is what pins each of them individually.
    func testRecordToSend_SameUnderlyingCodeDifferentUnderlyingDomain_BothReachTheSink() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        let osStatus = NSError(
            domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSOSStatusErrorDomain", code: -12881)]
        )
        let url = NSError(
            domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSURLErrorDomain", code: -12881)]
        )
        let first = AudiobookSessionManager.playbackFailureRecordToSend(
            error: osStatus, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0)
        let second = AudiobookSessionManager.playbackFailureRecordToSend(
            error: url, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0.addingTimeInterval(2))
        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "the same cause code in a different cause domain is a different failure")
    }

    func testRecordToSend_SameUnderlyingDomainDifferentUnderlyingCode_BothReachTheSink() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        let mediaReset = NSError(
            domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSOSStatusErrorDomain", code: -12881)]
        )
        let decodeFailed = NSError(
            domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSOSStatusErrorDomain", code: -12911)]
        )
        let first = AudiobookSessionManager.playbackFailureRecordToSend(
            error: mediaReset, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0)
        let second = AudiobookSessionManager.playbackFailureRecordToSend(
            error: decodeFailed, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0.addingTimeInterval(2))
        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "a different cause code in the same cause domain is a different failure")
    }

    /// The other side: identical top level AND identical cause still collapses,
    /// or the key would never suppress anything under AVFoundation.
    func testRecordToSend_SameTopLevelSameCause_IsStillSuppressed() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        let error = NSError(
            domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSOSStatusErrorDomain", code: -12881)]
        )
        _ = AudiobookSessionManager.playbackFailureRecordToSend(
            error: error, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0)
        let repeated = AudiobookSessionManager.playbackFailureRecordToSend(
            error: error, position: nil, bookId: "a", contentSource: .lcpStreamed,
            deduplicator: &dedupe, now: t0.addingTimeInterval(2))
        XCTAssertNil(repeated)
    }

    func testRecordToSend_FollowUpWithDifferentCode_CarriesTheInterval() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        _ = AudiobookSessionManager.playbackFailureRecordToSend(
            error: NSError(domain: "AVFoundationErrorDomain", code: -11819), position: nil,
            bookId: "a", contentSource: .openAccess, deduplicator: &dedupe, now: t0)
        let followUp = AudiobookSessionManager.playbackFailureRecordToSend(
            error: NSError(domain: "OpenAccessPlayer", code: 2), position: nil,
            bookId: "a", contentSource: .openAccess, deduplicator: &dedupe, now: t0.addingTimeInterval(0.5))

        XCTAssertEqual(followUp?.code, 2)
        XCTAssertEqual(followUp?.userInfo["msSincePreviousFailureForBook"] as? Int, 500)
    }

    func testRecordToSend_NilErrorRepeats_AreSuppressedAsOneKey() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        XCTAssertNotNil(AudiobookSessionManager.playbackFailureRecordToSend(
            error: nil, position: nil, bookId: "a", contentSource: .unknown, deduplicator: &dedupe, now: t0))
        XCTAssertNil(AudiobookSessionManager.playbackFailureRecordToSend(
            error: nil, position: nil, bookId: "a", contentSource: .unknown, deduplicator: &dedupe, now: t0.addingTimeInterval(1)))
    }

    func testRecordToSend_NilBookId_IsNotSuppressedAgainstAnotherBook() {
        var dedupe = PlaybackFailureRecordDeduplicator()
        let error = NSError(domain: "d", code: 1)
        _ = AudiobookSessionManager.playbackFailureRecordToSend(
            error: error, position: nil, bookId: "a", contentSource: .unknown, deduplicator: &dedupe, now: t0)
        XCTAssertNotNil(AudiobookSessionManager.playbackFailureRecordToSend(
            error: error, position: nil, bookId: nil, contentSource: .unknown, deduplicator: &dedupe, now: t0.addingTimeInterval(1)))
    }
}

// MARK: - Content source classification

final class AudiobookContentSourceTests: XCTestCase {

    private func book(
        type: String,
        indirect: [TPPOPDSIndirectAcquisition] = [],
        distributor: String? = nil
    ) -> TPPBook {
        TPPBook(
            acquisitions: [TPPOPDSAcquisition(
                relation: .generic,
                type: type,
                hrefURL: URL(string: "https://example.test/fulfill")!,
                indirectAcquisitions: indirect,
                availability: TPPOPDSAcquisitionAvailabilityUnlimited()
            )],
            authors: [], categoryStrings: [], distributor: distributor,
            identifier: UUID().uuidString, imageURL: nil, imageThumbnailURL: nil,
            published: Date(), publisher: "Test", subtitle: nil, summary: nil,
            title: "Fixture", updated: Date(), annotationsURL: nil, analyticsURL: nil,
            alternateURL: nil, relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil, contributors: [:],
            bookDuration: nil, imageCache: MockImageCache()
        )
    }

    private func classify(
        _ book: TPPBook?,
        hasDecryptor: Bool = false,
        lcpContentIsLocal: Bool = false,
        overdriveKey: String? = "Overdrive"
    ) -> AudiobookContentSource {
        AudiobookContentSource.classify(
            book: book,
            hasDecryptor: hasDecryptor,
            lcpContentIsLocal: lcpContentIsLocal,
            overdriveDistributorKey: overdriveKey
        )
    }

    func testNoBook_IsUnknown() {
        XCTAssertEqual(classify(nil, hasDecryptor: true, lcpContentIsLocal: true), .unknown)
    }

    func testDecryptorWithLocalContent_IsLCPLocal() {
        XCTAssertEqual(classify(book(type: DistributorType.ReadiumLCP.rawValue), hasDecryptor: true, lcpContentIsLocal: true), .lcpLocal)
    }

    func testDecryptorWithoutLocalContent_IsLCPStreamed() {
        XCTAssertEqual(classify(book(type: DistributorType.ReadiumLCP.rawValue), hasDecryptor: true, lcpContentIsLocal: false), .lcpStreamed)
    }

    func testLocalContentWithoutDecryptor_IsNotLCP() {
        // A downloaded open-access package is also "local"; only the decryptor
        // makes it LCP.
        XCTAssertEqual(classify(book(type: DistributorType.OpenAccessAudiobook.rawValue), lcpContentIsLocal: true), .openAccess)
    }

    func testOverdriveDistributor_IsOverdrive() {
        XCTAssertEqual(classify(book(type: DistributorType.OverdriveAudiobook.rawValue, distributor: "Overdrive")), .overdrive)
    }

    func testOverdriveDistributor_MatchesCaseInsensitively() {
        XCTAssertEqual(classify(book(type: DistributorType.OverdriveAudiobook.rawValue, distributor: "OVERDRIVE")), .overdrive)
    }

    func testOverdriveDistributor_WithoutAKey_IsNotOverdrive() {
        // Palace-noDRM has no OverDrive support and passes no key.
        XCTAssertEqual(classify(book(type: DistributorType.OverdriveAudiobook.rawValue, distributor: "Overdrive"), overdriveKey: nil), .openAccess)
    }

    func testOtherDistributor_IsNotOverdrive() {
        XCTAssertEqual(classify(book(type: DistributorType.OpenAccessAudiobook.rawValue, distributor: "Biblioboard")), .openAccess)
    }

    func testDecryptorWinsOverOverdriveDistributor() {
        XCTAssertEqual(classify(book(type: DistributorType.ReadiumLCP.rawValue, distributor: "Overdrive"), hasDecryptor: true, lcpContentIsLocal: true), .lcpLocal)
    }

    func testFindawayDirectAcquisition_IsFindaway() {
        XCTAssertEqual(classify(book(type: DistributorType.Findaway.rawValue)), .findaway)
    }

    func testFindawayUnderAnOPDSCatalogAcquisition_IsFindaway() {
        let leaf = TPPOPDSIndirectAcquisition(type: ContentTypeFindaway, indirectAcquisitions: [])
        XCTAssertEqual(classify(book(type: DistributorType.OPDSCatalog.rawValue, indirect: [leaf])), .findaway)
    }

    func testFindawayUnderAnOPDSPublicationAcquisition_IsFindaway() {
        // The `/groups/` JSON feed shape.
        let leaf = TPPOPDSIndirectAcquisition(type: ContentTypeFindaway, indirectAcquisitions: [])
        XCTAssertEqual(classify(book(type: ContentTypeOPDSPublication, indirect: [leaf])), .findaway)
    }

    func testNonFindawayIndirectAcquisition_IsOpenAccess() {
        let leaf = TPPOPDSIndirectAcquisition(type: ContentTypeOpenAccessAudiobook, indirectAcquisitions: [])
        XCTAssertEqual(classify(book(type: DistributorType.OPDSCatalog.rawValue, indirect: [leaf])), .openAccess)
    }

    func testOverdriveWinsOverFindawayAcquisition() {
        XCTAssertEqual(classify(book(type: DistributorType.Findaway.rawValue, distributor: "Overdrive")), .overdrive)
    }

    func testBearerTokenAudiobook_IsOpenAccess() {
        XCTAssertEqual(classify(book(type: DistributorType.BearerToken.rawValue)), .openAccess)
    }
}

// MARK: - Open failures

/// The open-failure non-fatal (`BookService.showAudiobookTryAgainError`) is a
/// fixed domain/code with no cause. These pin the metadata the session manager
/// now hands it: which loader step failed, the error that step carried, and the
/// content source.
/// Covers the conjunction that a surviving mutant exposed: with `&&` changed to
/// `||`, every LCP book reported `.lcpLocal` and the streamed/local split — the
/// most valuable distinction in this field, with streaming at 100% in
/// production — silently disappeared, and the whole suite stayed green. The
/// file-exists side is injected here because the production one reads
/// `AppContainer.production()` and cannot be driven from a unit test.
@MainActor
final class LCPStreamedVersusLocalTests: XCTestCase {

    private func lcpBook() -> TPPBook {
        TPPBook(
            acquisitions: [TPPOPDSAcquisition(
                relation: .generic,
                type: "application/audiobook+lcp",
                hrefURL: URL(string: "https://example.test/fulfill")!,
                indirectAcquisitions: [],
                availability: TPPOPDSAcquisitionAvailabilityUnlimited()
            )],
            authors: [], categoryStrings: [], distributor: nil,
            identifier: "lcp-book", imageURL: nil, imageThumbnailURL: nil,
            published: Date(), publisher: "Test", subtitle: nil, summary: nil,
            title: "Fixture", updated: Date(), annotationsURL: nil, analyticsURL: nil,
            alternateURL: nil, relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil, contributors: [:],
            bookDuration: nil, imageCache: MockImageCache()
        )
    }

    func testDecryptorPresentAndContentOnDisk_IsLocal() {
        let source = AudiobookSessionManager.contentSource(
            for: lcpBook(), isLCP: true, contentIsLocal: { _ in true }
        )
        XCTAssertEqual(source, .lcpLocal)
    }

    /// The arm `||` would have erased.
    func testDecryptorPresentButContentNotOnDisk_IsStreamed() {
        let source = AudiobookSessionManager.contentSource(
            for: lcpBook(), isLCP: true, contentIsLocal: { _ in false }
        )
        XCTAssertEqual(source, .lcpStreamed,
                       "an LCP book whose .lcpa is not on disk is streaming, not local")
    }

    /// And with no decryptor the file-exists answer must not matter — this is
    /// the case the original `||` argument covered, kept so the pair is complete.
    func testNoDecryptor_IsNotLCPRegardlessOfDisk() {
        for onDisk in [true, false] {
            let source = AudiobookSessionManager.contentSource(
                for: lcpBook(), isLCP: false, contentIsLocal: { _ in onDisk }
            )
            XCTAssertNotEqual(source, .lcpLocal)
            XCTAssertNotEqual(source, .lcpStreamed)
        }
    }
}

final class AudiobookOpenFailureMetadataTests: XCTestCase {

    private func metadata(_ error: AudiobookLoadError, source: AudiobookContentSource = .lcpStreamed) -> [String: Any] {
        AudiobookSessionManager.openFailureMetadata(loadError: error, contentSource: source)
    }

    func testLoadErrorWithoutPayload_RecordsItsCaseName() {
        XCTAssertEqual(metadata(.manifestFetchFailed)["loadError"] as? String, "manifestFetchFailed")
        XCTAssertEqual(metadata(.lcpInstantiationFailed)["loadError"] as? String, "lcpInstantiationFailed")
    }

    func testLoadErrorWithPayload_RecordsTheCaseNameWithoutThePayload() {
        let error = AudiobookLoadError.lcpDecryptionFailed(underlying: NSError(domain: "x", code: 1))
        XCTAssertEqual(metadata(error)["loadError"] as? String, "lcpDecryptionFailed")
    }

    func testContentSource_IsRecorded() {
        XCTAssertEqual(metadata(.manifestParseFailed, source: .findaway)["contentSource"] as? String, "findaway")
    }

    func testUnderlyingErrorAndItsChain_AreRecorded() {
        let root = NSError(domain: NSOSStatusErrorDomain, code: -12873)
        let cause = NSError(domain: "ReadiumLCP", code: 7, userInfo: [NSUnderlyingErrorKey: root, "httpStatusCode": 403])
        let info = metadata(.lcpDecryptionFailed(underlying: cause))

        XCTAssertEqual(info["underlyingDomain"] as? String, "ReadiumLCP")
        XCTAssertEqual(info["underlyingCode"] as? Int, 7)
        XCTAssertEqual(info["httpStatusCode"] as? Int, 403)
        XCTAssertEqual(info["underlyingErrorDomain"] as? String, NSOSStatusErrorDomain)
        XCTAssertEqual(info["underlyingErrorCode"] as? Int, -12873)
    }

    func testEveryCaseThatCarriesAnError_ExposesIt() {
        let e = NSError(domain: "cause", code: 42)
        let carrying: [AudiobookLoadError] = [
            .tokenRefreshFailed(underlying: e),
            .lcpDecryptionFailed(underlying: e),
            .licenseDownloadFailed(underlying: e),
            .licenseSaveFailed(underlying: e),
            .vendorKeyUpdateFailed(underlying: e),
            .manifestDecodingFailed(underlying: e),
        ]
        for error in carrying {
            XCTAssertEqual(metadata(error)["underlyingCode"] as? Int, 42, "\(error) must expose its underlying error")
        }
    }

    func testCaseWithNilUnderlying_RecordsNoCause() {
        let info = metadata(.tokenRefreshFailed(underlying: nil))
        XCTAssertNil(info["underlyingDomain"])
        XCTAssertNil(info["underlyingCode"])
    }

    func testCaseWithoutAnError_RecordsNoCause() {
        XCTAssertNil(metadata(.missingFulfillURL)["underlyingDomain"])
    }

    func testFactoryFailure_RecordsTheManifestType() {
        XCTAssertEqual(metadata(.factoryFailed(manifestType: "findaway"))["manifestType"] as? String, "findaway")
        XCTAssertNil(metadata(.factoryFailed(manifestType: nil))["manifestType"])
    }
}

// MARK: - Bound content source lookup

final class BoundContentSourceLookupTests: XCTestCase {

    func testFailureForTheBoundBook_UsesTheBoundSource() {
        XCTAssertEqual(AudiobookSessionManager.contentSource(bound: ("a", .lcpLocal), failingBookId: "a"), .lcpLocal)
    }

    func testFailureForAnotherBook_IsUnknown() {
        XCTAssertEqual(AudiobookSessionManager.contentSource(bound: ("a", .lcpLocal), failingBookId: "b"), .unknown)
    }

    func testNothingBound_IsUnknown() {
        XCTAssertEqual(AudiobookSessionManager.contentSource(bound: nil, failingBookId: "a"), .unknown)
    }
}
