//
//  AudiobookPositionTraceReportTests.swift
//  PalaceTests
//
//  PP-4963 — exactly which fields leave the device.
//
//  The instrument ships ungated for codes 404, 406 and 407, and the claim that
//  justifies that is "no book, title, or patron identity reaches Crashlytics".
//  Until now the claim was screened for by substring: the payload was rendered
//  into one string and checked for "book", "title", "patron" and a few more.
//  A denylist passes for every field nobody thought to forbid, and it is
//  checked against a payload that is built and emitted in the same function, so
//  there was nothing to assert an exact shape against.
//
//  These pin the key SET of each of the five emitting cases, against
//  `saveReportPayload(for:context:)` and `gapReportPayload(for:)`. Adding
//  `"bookID"` — or `"deviceId"`, or anything else — to a payload fails a named
//  test rather than shipping.
//
//  Scoped claim, as everywhere else in this pack: this is what the TRACE adds.
//  `TPPErrorLogger.addAccountInfoToMetadata` attaches account name, UUID and
//  catalog URLs to every `logError(withCode:)`, and Crashlytics carries a
//  global md5(barcode) user id. Both are pre-existing and shared with shipped
//  code 403, and neither reaches book identity — so a patron's position in a
//  book stays unreconstructible, which is the property that justifies shipping
//  ungated. It is not an end-to-end anonymity claim.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AudiobookPositionTraceReportTests: XCTestCase {

    /// The counters every save finding carries. Named once so the three
    /// expected sets below differ only by the field each verdict adds.
    private let sharedKeys: Set<String> = [
        "applicationStateAtLastTick",
        "tickGapCount",
        "longestTickGapSeconds",
        "clockRegressionCount",
        "ticket"
    ]

    private func context(
        state: String = "background",
        gaps: Int = 0,
        longest: TimeInterval = 0,
        regressions: Int = 0
    ) -> PositionTraceContext {
        PositionTraceContext(
            applicationStateAtLastTick: state,
            tickGapCount: gaps,
            longestTickGap: longest,
            clockRegressionCount: regressions
        )
    }

    // MARK: - The save arm

    func testDryPayload_carriesExactlyTheSharedCountersAndTheDuration() throws {
        let payload = try XCTUnwrap(
            AudiobookPositionTraceRecorder.saveReportPayload(
                for: .dry(seconds: 10_800), context: context(gaps: 2, longest: 300)
            )
        )

        XCTAssertEqual(payload.code, .audiobookPositionSaveDry)
        XCTAssertEqual(
            Set(payload.metadata.keys), sharedKeys.union(["drySeconds"]),
            "code 404 ships ungated; a field added here reaches every patron's "
            + "Crashlytics without review"
        )
        XCTAssertEqual(payload.metadata["drySeconds"] as? Double, 10_800)
        XCTAssertEqual(payload.metadata["tickGapCount"] as? Int, 2)
        XCTAssertEqual(payload.metadata["longestTickGapSeconds"] as? Double, 300)
        XCTAssertEqual(payload.metadata["applicationStateAtLastTick"] as? String, "background")
        XCTAssertEqual(payload.metadata["ticket"] as? String, "PP-4963")
    }

    func testTickGapPayload_carriesExactlyTheSharedCountersAndTheGap() throws {
        let payload = try XCTUnwrap(
            AudiobookPositionTraceRecorder.saveReportPayload(
                for: .tickGap(seconds: 10_800), context: context(gaps: 7, longest: 10_800)
            )
        )

        XCTAssertEqual(payload.code, .audiobookPositionTickGap)
        XCTAssertEqual(Set(payload.metadata.keys), sharedKeys.union(["gapSeconds"]))
        XCTAssertEqual(payload.metadata["gapSeconds"] as? Double, 10_800)
        XCTAssertEqual(
            payload.metadata["tickGapCount"] as? Int, 7,
            "without the count, a pause and a stall are the same event across the fleet"
        )
    }

    func testClockRegressedPayload_carriesExactlyTheSharedCountersAndTheStep() throws {
        let payload = try XCTUnwrap(
            AudiobookPositionTraceRecorder.saveReportPayload(
                for: .clockRegressed(by: 1_800), context: context(regressions: 1)
            )
        )

        XCTAssertEqual(payload.code, .audiobookPositionClockRegressed)
        XCTAssertEqual(Set(payload.metadata.keys), sharedKeys.union(["regressedBySeconds"]))
        XCTAssertEqual(payload.metadata["regressedBySeconds"] as? Double, 1_800)
        XCTAssertEqual(payload.metadata["clockRegressionCount"] as? Int, 1)
    }

    /// The silent half of the partition, stated over the whole enum. The
    /// `switch` has no `default`, so a new verdict case stops this file
    /// compiling until someone says which side it is on — a list would simply
    /// be one short, and a case missing from a list reads exactly like a case
    /// that stays silent.
    func testSaveReportPayload_isNilForEveryVerdictThatIsNotAFinding() {
        let samples: [PositionSaveVerdict] = [
            .noPlayback,
            .playbackStale(sinceLastTick: 900),
            .saving(sinceLastSave: 5),
            .dry(seconds: 10_800),
            .tickGap(seconds: 10_800),
            .clockRegressed(by: 1_800)
        ]

        for verdict in samples {
            let expectedSilent: Bool
            switch verdict {
            case .noPlayback, .playbackStale, .saving:
                expectedSilent = true
            case .dry, .tickGap, .clockRegressed:
                expectedSilent = false
            }

            let payload = AudiobookPositionTraceRecorder.saveReportPayload(
                for: verdict, context: context()
            )
            XCTAssertEqual(
                payload == nil, expectedSilent,
                "\(verdict) is on the wrong side of the fleet partition"
            )
        }
    }

    // MARK: - The restore arm

    func testBehindPayload_carriesExactlyTheDurationAndTheTicket() throws {
        let payload = try XCTUnwrap(
            AudiobookPositionTraceRecorder.gapReportPayload(for: .behind(seconds: 10_800))
        )

        XCTAssertEqual(payload.code, .audiobookPositionRestoreGap)
        XCTAssertEqual(Set(payload.metadata.keys), ["behindSeconds", "ticket"])
        XCTAssertEqual(payload.metadata["behindSeconds"] as? Double, 10_800)
    }

    /// A track key is frequently the chapter title, which is book identity. The
    /// fixture key is written to read like one, so a payload that carried the
    /// key rather than its length fails on the key set AND on the value.
    func testUnresolvablePayload_carriesTheKeysLengthAndNeverTheKey() throws {
        let trackKey = "Chapter 14 — The Hound of the Baskervilles"
        let payload = try XCTUnwrap(
            AudiobookPositionTraceRecorder.gapReportPayload(
                for: .markerUnresolvable(trackKey: trackKey)
            )
        )

        XCTAssertEqual(payload.code, .audiobookPositionRestoreGap)
        XCTAssertEqual(Set(payload.metadata.keys), ["trackKeyLength", "ticket"])
        XCTAssertEqual(payload.metadata["trackKeyLength"] as? Int, trackKey.count)

        let rendered = payload.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        XCTAssertFalse(
            rendered.contains("Baskervilles"),
            "only the key's length may travel: \(rendered)"
        )
    }

    /// Same shape as the save arm — over the whole enum, no `default`.
    func testGapReportPayload_isNilForEveryVerdictThatIsNotAFinding() {
        let samples: [PositionRestoreGapVerdict] = [
            .noMarker,
            .markerForDifferentBook,
            .aligned(driftSeconds: 3),
            .ahead(seconds: 30),
            .behind(seconds: 10_800),
            .markerUnresolvable(trackKey: "k")
        ]

        for verdict in samples {
            let expectedSilent: Bool
            switch verdict {
            case .noMarker, .markerForDifferentBook, .aligned, .ahead:
                expectedSilent = true
            case .behind, .markerUnresolvable:
                expectedSilent = false
            }

            XCTAssertEqual(
                AudiobookPositionTraceRecorder.gapReportPayload(for: verdict) == nil,
                expectedSilent,
                "\(verdict) is on the wrong side of the fleet partition"
            )
        }
    }

    // MARK: - The emit still routes what the payload decides

    /// The split must not have moved the decision without moving the emit: a
    /// payload nobody sends is not a privacy guarantee, it is a dead function.
    func testCrashlyticsSaveReport_emitsThePayloadItBuilds() throws {
        var emitted: [(TPPErrorCode, String, [String: Any]?)] = []
        AudiobookPositionTraceRecorder.crashlyticsSaveReport(
            .dry(seconds: 10_800),
            context: context(gaps: 2, longest: 300),
            emit: { code, summary, metadata in emitted.append((code, summary, metadata)) }
        )

        let expected = try XCTUnwrap(
            AudiobookPositionTraceRecorder.saveReportPayload(
                for: .dry(seconds: 10_800), context: context(gaps: 2, longest: 300)
            )
        )
        XCTAssertEqual(emitted.count, 1)
        let sent = try XCTUnwrap(emitted.first)
        XCTAssertEqual(sent.0, expected.code)
        XCTAssertEqual(sent.1, expected.summary)
        XCTAssertEqual(Set(try XCTUnwrap(sent.2).keys), Set(expected.metadata.keys))
    }

    func testCrashlyticsGapReport_emitsThePayloadItBuilds() throws {
        var emitted: [(TPPErrorCode, String, [String: Any]?)] = []
        AudiobookPositionTraceRecorder.crashlyticsGapReport(
            .behind(seconds: 10_800),
            emit: { code, summary, metadata in emitted.append((code, summary, metadata)) }
        )

        let expected = try XCTUnwrap(
            AudiobookPositionTraceRecorder.gapReportPayload(for: .behind(seconds: 10_800))
        )
        XCTAssertEqual(emitted.count, 1)
        let sent = try XCTUnwrap(emitted.first)
        XCTAssertEqual(sent.0, expected.code)
        XCTAssertEqual(sent.1, expected.summary)
        XCTAssertEqual(Set(try XCTUnwrap(sent.2).keys), Set(expected.metadata.keys))
    }
}
