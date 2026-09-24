//
//  AudiobookPositionTraceSeamTests.swift
//  PalaceTests
//
//  PP-4963 — the three seams that connect the instrument to the app. Review
//  found all three untested: the policies were tabled against a hand-written
//  two-track stub, so the cross-track arithmetic behind the headline "three
//  hours behind" number was never exercised against a real manifest, and the
//  only production entry point (`observe`) had no coverage at all.
//
//  These use the real `Manifest` / `Tracks` / `AudiobookTableOfContents`
//  fixture, so a change in the toolkit's position arithmetic surfaces here
//  rather than in a device trace three hours later.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import UIKit
import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

final class AudiobookPositionTraceSeamTests: XCTestCase {

    private let bookIdentifier = "pp4963-audiobook"
    private var tracks: Tracks!
    private var toc: AudiobookTableOfContents!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let manifest = try Manifest.from(
            jsonFileName: ManifestJSON.snowcrash.rawValue,
            bundle: Bundle(for: type(of: self))
        )
        tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: nil)
        toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)

        // If the fixture were single-track the cross-track assertions below
        // would be vacuous — they would reduce to same-track subtraction.
        XCTAssertGreaterThanOrEqual(
            tracks.tracks.count, 3,
            "fixture must be multi-track or the cross-track cases prove nothing"
        )
    }

    override func tearDownWithError() throws {
        tracks = nil
        toc = nil
        try super.tearDownWithError()
    }

    // MARK: - The offset resolver, against a real manifest

    func testResolver_returnsNilForATrackTheManifestDoesNotContain() {
        let resolve = AudiobookPositionOffsets.resolver(for: toc)

        XCTAssertNil(
            resolve("a-track-key-that-is-not-in-this-manifest", 12),
            "an unlocatable key must return nil so the policy can report "
            + ".markerUnresolvable rather than silently reporting agreement"
        )
    }

    func testResolver_returnsZeroAtTheStartOfTheFirstTrack() throws {
        let first = try XCTUnwrap(tracks.tracks.first)
        let resolve = AudiobookPositionOffsets.resolver(for: toc)

        let offset = try XCTUnwrap(resolve(first.key, 0))
        XCTAssertEqual(offset, 0, accuracy: 0.001)
    }

    func testResolver_accumulatesEarlierTrackDurationsAcrossABoundary() throws {
        let first = try XCTUnwrap(tracks.tracks.first)
        let second = tracks.tracks[1]
        let resolve = AudiobookPositionOffsets.resolver(for: toc)

        let startOfSecond = try XCTUnwrap(resolve(second.key, 0))

        XCTAssertEqual(
            startOfSecond, first.duration, accuracy: 0.5,
            "the start of track 2 sits exactly one track-duration into the book; "
            + "same-track arithmetic would have returned 0 here"
        )
        XCTAssertGreaterThan(
            startOfSecond, 0,
            "a cross-track offset that collapses to zero is the defect this guards"
        )
    }

    // MARK: - The restore-gap overload used by the session manager

    /// `evaluateRestoreGap(restoredPosition:in:)` is the form
    /// `AudiobookSessionManager` actually calls; the tabled tests drive the
    /// resolver-taking form underneath it.
    func testRestoreGapOverload_reportsHoursBehindAcrossARealTrackBoundary() throws {
        let store = InMemoryMarkerStore()
        var reported: [PositionRestoreGapVerdict] = []
        let recorder = AudiobookPositionTraceRecorder(
            bookID: bookIdentifier,
            markerStore: store,
            diagnosticsEnabled: { true },
            reportGapVerdict: { reported.append($0) },
            fileLog: { _ in }
        )

        // Last live position: start of track 3. Restored: start of track 1.
        let third = tracks.tracks[2]
        let first = try XCTUnwrap(tracks.tracks.first)
        store.save(LastLivePositionMarker(
            bookID: bookIdentifier,
            trackKey: third.key,
            timestamp: 0,
            recordedAt: Date()
        ))

        recorder.evaluateRestoreGap(
            restoredPosition: TrackPosition(track: first, timestamp: 0, tracks: tracks),
            in: toc
        )

        guard case let .behind(seconds)? = reported.first else {
            return XCTFail("expected .behind across real tracks, got \(reported)")
        }
        let expected = first.duration + tracks.tracks[1].duration
        XCTAssertEqual(seconds, expected, accuracy: 1.0,
                       "the gap is the sum of the two skipped tracks")
    }

    func testRestoreGapOverload_reportsUnresolvableForAMarkerOutsideTheManifest() throws {
        let store = InMemoryMarkerStore()
        var reported: [PositionRestoreGapVerdict] = []
        let recorder = AudiobookPositionTraceRecorder(
            bookID: bookIdentifier,
            markerStore: store,
            diagnosticsEnabled: { true },
            reportGapVerdict: { reported.append($0) },
            fileLog: { _ in }
        )
        store.save(LastLivePositionMarker(
            bookID: bookIdentifier,
            trackKey: "foreign-track-from-a-previous-fulfilment",
            timestamp: 90,
            recordedAt: Date()
        ))

        let first = try XCTUnwrap(tracks.tracks.first)
        recorder.evaluateRestoreGap(
            restoredPosition: TrackPosition(track: first, timestamp: 0, tracks: tracks),
            in: toc
        )

        XCTAssertEqual(
            reported.first,
            .markerUnresolvable(trackKey: "foreign-track-from-a-previous-fulfilment"),
            "a marker naming a track this manifest lacks must not read as agreement"
        )
    }

    // MARK: - The production dispatch path, end to end

    /// Review found dispatch and payload were each tested with the other
    /// injected away: replacing the default `reportSaveVerdict` with a no-op
    /// left every test green and the fleet silent. This drives the DEFAULT
    /// path — no `reportSaveVerdict` injected — and only substitutes the final
    /// emit, so a severed default reporter fails here.
    func testDefaultReporter_emitsAFleetEventForADryVerdict() throws {
        var emitted: [(String, [String: Any]?)] = []
        let recorder = AudiobookPositionTraceRecorder(
            bookID: bookIdentifier,
            markerStore: InMemoryMarkerStore(),
            diagnosticsEnabled: { false },
            fileLog: { _ in },
            emitFleetEvent: { _, summary, metadata in emitted.append((summary, metadata)) },
            now: { Date(timeIntervalSince1970: 1_010_800) }
        )

        recorder.notePlaybackTick(trackKey: "k", timestamp: 0,
                                  at: Date(timeIntervalSince1970: 1_000_000))
        recorder.noteSave(at: Date(timeIntervalSince1970: 1_000_000))
        recorder.notePlaybackTick(trackKey: "k", timestamp: 10_800,
                                  at: Date(timeIntervalSince1970: 1_010_800))

        recorder.applicationDidBecomeActive()

        XCTAssertEqual(emitted.count, 1,
                       "the shipped default reporter must actually emit; a silent "
                       + "default means an empty fleet, which reads as no defect")
        let drySeconds = try XCTUnwrap(emitted.first?.1?["drySeconds"] as? Double)
        XCTAssertEqual(drySeconds, 10_800, accuracy: 1)
    }

    /// The foreground notification is the ONLY production trigger for any
    /// verdict. Deleting that subscription left every test green.
    func testForegroundNotification_triggersAVerdict() {
        var emitted = 0
        let recorder = AudiobookPositionTraceRecorder(
            bookID: bookIdentifier,
            markerStore: InMemoryMarkerStore(),
            diagnosticsEnabled: { false },
            fileLog: { _ in },
            emitFleetEvent: { _, _, _ in emitted += 1 },
            now: { Date(timeIntervalSince1970: 1_010_800) }
        )
        let center = NotificationCenter()
        recorder.observe(
            positionPublisher: Empty<TrackPosition, Never>().eraseToAnyPublisher(),
            notificationCenter: center
        )

        recorder.notePlaybackTick(trackKey: "k", timestamp: 0,
                                  at: Date(timeIntervalSince1970: 1_000_000))
        recorder.noteSave(at: Date(timeIntervalSince1970: 1_000_000))
        recorder.notePlaybackTick(trackKey: "k", timestamp: 10_800,
                                  at: Date(timeIntervalSince1970: 1_010_800))

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(emitted, 1,
                       "returning to the foreground must produce a verdict; without "
                       + "that subscription nothing is ever reported")
    }

    /// `XCTAssertTrue(logLines.isEmpty)` was the only assertion on the file
    /// trace anywhere, so deleting the write from `traceLine` passed. The
    /// device run reads this file — if it is never written there is nothing to
    /// read after three hours.
    func testFileTrace_isWritten_whenTheTraceIsOn() {
        var lines: [String] = []
        let recorder = AudiobookPositionTraceRecorder(
            bookID: bookIdentifier,
            markerStore: InMemoryMarkerStore(),
            diagnosticsEnabled: { true },
            fileLog: { lines.append($0) },
            emitFleetEvent: { _, _, _ in }
        )

        recorder.noteSave(at: Date(timeIntervalSince1970: 1_000_000))

        XCTAssertFalse(lines.isEmpty, "a save must be written to the per-book trace")
        XCTAssertTrue(lines.contains { $0.contains("[AUDIOPOS-TRACE]") && $0.contains("save") },
                      "and it must be the save line: \(lines)")
    }

    /// The seam previously omitted the error code, so both signals emitted
    /// under 404 and code 405 was unreachable — three review rounds could not
    /// see it because every test injected a seam that had erased the
    /// distinction. These assert the codes directly.
    func testSaveFinding_filesUnderTheDrySaveCode() {
        var codes: [TPPErrorCode] = []
        AudiobookPositionTraceRecorder.crashlyticsSaveReport(
            .dry(seconds: 10_800), stateAtLastTick: "background",
            emit: { code, _, _ in codes.append(code) }
        )
        XCTAssertEqual(codes, [.audiobookPositionSaveDry])
    }

    func testRestoreGapFinding_filesUnderTheRestoreGapCode_not404() {
        var codes: [TPPErrorCode] = []
        AudiobookPositionTraceRecorder.crashlyticsGapReport(
            .behind(seconds: 10_800),
            emit: { code, _, _ in codes.append(code) }
        )
        XCTAssertEqual(codes, [.audiobookPositionRestoreGap],
                       "a restore-gap finding filed under the dry-save code would "
                       + "conflate the two signals this instrument exists to separate")
    }

    /// The whole production chain, not the static helper: a recorder built with
    /// only the emit substituted must route a gap finding to 405.
    func testDefaultGapReporter_routesToTheRestoreGapCode() {
        var codes: [TPPErrorCode] = []
        let store = InMemoryMarkerStore()
        let recorder = AudiobookPositionTraceRecorder(
            bookID: bookIdentifier,
            markerStore: store,
            diagnosticsEnabled: { true },
            fileLog: { _ in },
            emitFleetEvent: { code, _, _ in codes.append(code) }
        )
        store.save(LastLivePositionMarker(
            bookID: bookIdentifier, trackKey: "a", timestamp: 10_800, recordedAt: Date()
        ))

        recorder.evaluateRestoreGap(
            restoredTrackKey: "a", restoredTimestamp: 0,
            absoluteOffset: { _, t in t }
        )

        XCTAssertEqual(codes, [.audiobookPositionRestoreGap])
    }

    // MARK: - observe(): the only production entry point

    /// Without this, nothing pinned that a position emitted by the player
    /// actually reaches the recorder — the wiring could be removed entirely and
    /// every other test would still pass.
    func testObserve_deliversPlayerPositionsToTheRecorder() throws {
        let store = InMemoryMarkerStore()
        let recorder = AudiobookPositionTraceRecorder(
            bookID: bookIdentifier,
            markerStore: store,
            diagnosticsEnabled: { true },
            fileLog: { _ in }
        )
        let subject = PassthroughSubject<TrackPosition, Never>()
        recorder.observe(positionPublisher: subject.eraseToAnyPublisher())

        let first = try XCTUnwrap(tracks.tracks.first)
        subject.send(TrackPosition(track: first, timestamp: 42, tracks: tracks))

        let marker = try XCTUnwrap(
            store.marker(forBookID: bookIdentifier),
            "a position emitted by the player must reach the recorder; if this is "
            + "nil the subscription is not wired and the instrument is deaf"
        )
        XCTAssertEqual(marker.trackKey, first.key)
        XCTAssertEqual(marker.timestamp, 42, accuracy: 0.001)
    }
}

/// Minimal store for the seam tests. Deliberately not the UserDefaults-backed
/// production one — these assert wiring, not persistence.
private final class InMemoryMarkerStore: LastLivePositionMarkerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var markers: [String: LastLivePositionMarker] = [:]

    func marker(forBookID bookID: String) -> LastLivePositionMarker? {
        lock.lock(); defer { lock.unlock() }
        return markers[bookID]
    }

    func save(_ marker: LastLivePositionMarker) {
        lock.lock(); defer { lock.unlock() }
        markers[marker.bookID] = marker
    }
}
