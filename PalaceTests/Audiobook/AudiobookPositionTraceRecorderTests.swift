//
//  AudiobookPositionTraceRecorderTests.swift
//  PalaceTests
//
//  PP-4963 — orchestration around the two pure policies. The decisions are
//  tabled in `AudiobookPositionTraceTests`; what is pinned here is the wiring
//  that makes those decisions mean anything.
//
//  Three of these tests exist because review found the first draft could not
//  see the defects they cover: the save clock could be deleted outright with
//  every test still green, the recorder was deallocated seconds after playback
//  began, and the "nothing was reported" assertions passed on an empty array.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

private final class SpyMarkerStore: LastLivePositionMarkerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var markers: [String: LastLivePositionMarker] = [:]
    private(set) var writeCount = 0

    func marker(forBookID bookID: String) -> LastLivePositionMarker? {
        lock.lock(); defer { lock.unlock() }
        return markers[bookID]
    }

    func save(_ marker: LastLivePositionMarker) {
        lock.lock(); defer { lock.unlock() }
        markers[marker.bookID] = marker
        writeCount += 1
    }

    func seed(_ marker: LastLivePositionMarker) {
        lock.lock(); defer { lock.unlock() }
        markers[marker.bookID] = marker
    }
}

final class AudiobookPositionTraceRecorderTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var store: SpyMarkerStore!
    private var reported: [PositionSaveVerdict] = []
    private var reportedStates: [String] = []
    private var gapsReported: [PositionRestoreGapVerdict] = []
    /// Collected instead of written. The previous draft left `fileLog`
    /// defaulted, so every test drove the real `AudiobookFileLogger.shared` —
    /// FileHandle appends, directory creation and a size-triggered rollover —
    /// against CLAUDE.md's rule about real singletons, and as a cross-test
    /// pollution vector.
    private var logLines: [String] = []

    private func makeRecorder(diagnosticsEnabled: Bool = true) -> AudiobookPositionTraceRecorder {
        store = SpyMarkerStore()
        reported = []
        reportedStates = []
        gapsReported = []
        logLines = []
        return AudiobookPositionTraceRecorder(
            bookID: "book-1",
            markerStore: store,
            diagnosticsEnabled: { diagnosticsEnabled },
            reportSaveVerdict: { [weak self] verdict, state in
                self?.reported.append(verdict)
                self?.reportedStates.append(state)
            },
            reportGapVerdict: { [weak self] in self?.gapsReported.append($0) },
            fileLog: { [weak self] in self?.logLines.append($0) },
            now: { [weak self] in self?.clock ?? Date() }
        )
    }

    private func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    // MARK: - The save clock must actually be recorded

    /// A CONTINUOUS chain of playback ticks spanning `seconds`, spaced well
    /// inside the freshness window.
    ///
    /// Two ticks `seconds` apart would measure something else entirely. A gap
    /// wider than `tickFreshnessWindow` is a RESUME: it opens a new
    /// `PlaybackStretch` whose `lastSaveAt` is nil and whose `startedAt` is the
    /// second tick, so the quiet window collapses to zero and the verdict is
    /// `.saving` no matter how long the session ran. Only an unbroken chain
    /// describes three hours of continuous locked playback — which is also the
    /// honest shape, since real playback ticks about four times a second.
    private func driveLivePlayback(_ recorder: AudiobookPositionTraceRecorder,
                                   for seconds: TimeInterval,
                                   trackKey: String = "a") {
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            let step = min(5.0, seconds - elapsed)
            advance(step)
            elapsed += step
            recorder.notePlaybackTick(trackKey: trackKey, timestamp: elapsed, at: clock)
        }
    }

    /// THE test the first draft was missing. Deleting `lastSaveAt = date` from
    /// `noteSave` left all 33 tests green, because the two tests that looked
    /// like they covered it were confounded: one called `noteSave` at exactly
    /// `sessionStartedAt`, so the policy's reference Date was identical either
    /// way, and the other only asserted "not `.dry`".
    ///
    /// Without this, unwiring the save hook would make the instrument report
    /// `.dry` for every healthy locked session — manufacturing the exact
    /// finding PP-4963 exists to test for.
    func testSaveIsRecorded_soAHealthySessionIsNotReportedDry() {
        let recorder = makeRecorder()

        // CONTINUOUS playback well past the dry threshold before saving, so the
        // stretch's start and the save are distinguishable reference points.
        // Two ticks 200s apart would not do: that gap is a stretch boundary, the
        // save would land on the stretch it ends, and the verdict would be
        // `.tickGap` — a different cell, testing something this test does not
        // mean to ask about.
        driveLivePlayback(recorder, for: 200)
        recorder.noteSave(at: clock)

        recorder.applicationDidBecomeActive()

        guard case let .saving(sinceLastSave)? = reported.first else {
            return XCTFail("a session that saved 0s ago is saving, not \(reported)")
        }
        XCTAssertEqual(sinceLastSave, 0, accuracy: 0.001)
    }

    /// Architect review found this cell unenumerated in a change whose whole
    /// thesis is enumeration, so it is pinned rather than argued.
    ///
    /// A save arriving before any playback tick has nowhere to go: a save
    /// belongs to the stretch it happened in, and there is no stretch. It is
    /// dropped. That is safe in both directions — the verdict is `.noPlayback`
    /// regardless, and a dropped save can only ever SHRINK a reported quiet
    /// window, never invent one — but the behaviour is new in this change
    /// (`noteSave` used to record unconditionally) and worth a test rather
    /// than a comment.
    ///
    /// It also reconciles the termination call site's comment, which says
    /// leaving that hook out "would make a session that only ever saved on
    /// termination look as though it had never saved at all": true once
    /// playback has ticked, and moot before it has, because there is no
    /// verdict to distort.
    func testSaveBeforeAnyTick_isDroppedAndReportsNoPlayback() {
        let recorder = makeRecorder()

        recorder.noteSave(at: clock)
        advance(300)
        recorder.applicationDidBecomeActive()

        guard case .noPlayback? = reported.first else {
            return XCTFail(
                "a save with no playback behind it cannot support any verdict "
                + "about playback, got \(reported)"
            )
        }
    }

    // MARK: - The instrument must not agree with itself

    /// If a save also refreshed the last-live marker, the restore gap would be
    /// the difference between a value and itself, and a book that lost three
    /// hours would report a perfect restore.
    func testNoteSave_doesNotWriteTheLastLiveMarker() {
        let recorder = makeRecorder()
        recorder.noteSave(at: clock)
        advance(300)
        recorder.noteSave(at: clock)

        XCTAssertEqual(store.writeCount, 0,
                       "a save must never advance the marker it is measured against")
        XCTAssertNil(store.marker(forBookID: "book-1"))
    }

    func testPlaybackTick_writesTheMarker_onItsOwnCadence() {
        let recorder = makeRecorder()
        recorder.notePlaybackTick(trackKey: "a", timestamp: 10, at: clock)
        XCTAssertEqual(store.writeCount, 1, "the first tick establishes the marker")

        advance(1)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 11, at: clock)
        XCTAssertEqual(store.writeCount, 1, "a tick inside the write interval is absorbed")

        advance(AudiobookPositionTraceRecorder.markerWriteInterval)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 71, at: clock)
        XCTAssertEqual(store.writeCount, 2, "a tick past the interval advances the marker")

        let marker = store.marker(forBookID: "book-1")
        XCTAssertEqual(marker?.trackKey, "a")
        XCTAssertEqual(marker?.timestamp ?? 0, 71, accuracy: 0.001)
    }

    func testPlaybackTick_exactlyOnTheWriteInterval_advancesTheMarker() {
        let recorder = makeRecorder()
        recorder.notePlaybackTick(trackKey: "a", timestamp: 0, at: clock)
        XCTAssertEqual(store.writeCount, 1)

        advance(AudiobookPositionTraceRecorder.markerWriteInterval)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 60, at: clock)

        XCTAssertEqual(store.writeCount, 2,
                       "a tick exactly at the interval must write; the comparison is >=, not >")
    }

    func testPlaybackTick_justInsideTheWriteInterval_doesNotAdvanceTheMarker() {
        let recorder = makeRecorder()
        recorder.notePlaybackTick(trackKey: "a", timestamp: 0, at: clock)

        advance(AudiobookPositionTraceRecorder.markerWriteInterval - 0.001)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 60, at: clock)

        XCTAssertEqual(store.writeCount, 1, "a tick just short of the interval is absorbed")
    }

    /// The scenario PP-4963 exists to catch, in the shape where the instrument
    /// is ALSO impaired — and the one the first version of this refactor
    /// reported as healthy.
    ///
    /// Playback runs, saves die, and the tick stream stalls too (delivery is on
    /// the main queue, which is the suspect). Three hours later the patron
    /// unlocks and ticks resume. The inputs reaching the recorder are
    /// BYTE-IDENTICAL to a patron who simply paused for three hours — there is
    /// no discriminator available, and `timestamp` cannot supply one because it
    /// is scoped to a track and any gap this long has crossed a boundary.
    ///
    /// So the instrument must decline to answer rather than guess, and it must
    /// decline in the direction that does not manufacture health: `.saving`
    /// here is not merely wrong, it is invisible, because `.saving` is never
    /// emitted to the fleet.
    func testTicksResumeAfterAGap_withNoSaveSince_reportsTheGapRatherThanAVerdict() {
        let recorder = makeRecorder()
        driveLivePlayback(recorder, for: 60)
        recorder.noteSave(at: clock)

        advance(10_800)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 60, at: clock)
        for second in 1...3 {
            advance(1)
            recorder.notePlaybackTick(trackKey: "a", timestamp: 60 + Double(second), at: clock)
        }

        recorder.applicationDidBecomeActive()

        guard case let .tickGap(gap)? = reported.first else {
            return XCTFail(
                "the instrument must report that it could not see, not that all "
                + "is well — got \(reported)"
            )
        }
        XCTAssertEqual(gap, 10_800, accuracy: 1,
                       "the gap duration is what separates a pause from a stall "
                       + "once the fleet aggregates many sessions")

        // The round-four requirement, still binding: this must NOT be `.dry`.
        // A patron who merely paused presents these same inputs, and reporting
        // a three-hour dry window for them would manufacture the finding the
        // ticket is trying to confirm. `.tickGap` is the only verdict that is
        // honest under both readings — which is the point of it existing.
        if case .dry = reported.first {
            XCTFail("a pause and a stall are indistinguishable here; neither may be called dry")
        }
    }

    // MARK: - The default-off gate

    /// The marker records where a patron was in a book, which is a library
    /// record. With the trace off — the shipped default — nothing about the
    /// patron's position may be persisted at all.
    func testMarkerIsNotPersisted_whenTheTraceIsOff() {
        let recorder = makeRecorder(diagnosticsEnabled: false)

        recorder.notePlaybackTick(trackKey: "a", timestamp: 10, at: clock)
        advance(AudiobookPositionTraceRecorder.markerWriteInterval * 2)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 130, at: clock)

        XCTAssertEqual(store.writeCount, 0,
                       "no patron position may be written to disk with the trace switched off")
        XCTAssertTrue(logLines.isEmpty, "and nothing may be written to the local log either")
    }

    /// The fleet detector is deliberately NOT gated — it carries no patron
    /// data and is the signal that answers the ticket at scale.
    func testDryVerdictStillReported_whenTheTraceIsOff() {
        let recorder = makeRecorder(diagnosticsEnabled: false)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 0, at: clock)
        recorder.noteSave(at: clock)
        driveLivePlayback(recorder, for: 10_800)

        recorder.applicationDidBecomeActive()

        guard case .dry = reported.first else {
            return XCTFail("the fleet signal must survive the local-trace switch: \(reported)")
        }
    }

    // MARK: - Foreground verdict

    func testForegroundReturn_afterLivePlaybackWithNoSaves_reportsDry() {
        let recorder = makeRecorder()
        recorder.notePlaybackTick(trackKey: "a", timestamp: 0, at: clock)
        recorder.noteSave(at: clock)

        driveLivePlayback(recorder, for: 10_800)

        recorder.applicationDidBecomeActive()

        XCTAssertEqual(reported.count, 1, "exactly one verdict per foreground return")
        guard case let .dry(seconds)? = reported.first else {
            return XCTFail("expected a dry verdict, got \(reported)")
        }
        XCTAssertEqual(seconds, 10_800, accuracy: 1)
    }

    /// `XCTAssertFalse(contains:)` passes on an EMPTY array, so the previous
    /// form also passed if the recorder stopped reporting altogether. Asserting
    /// the exact verdict is what distinguishes "reported healthy" from
    /// "reported nothing".
    func testForegroundReturn_withSavesKeepingPace_reportsSavingNotDry() {
        let recorder = makeRecorder()
        recorder.notePlaybackTick(trackKey: "a", timestamp: 0, at: clock)
        advance(10)
        recorder.noteSave(at: clock)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 10, at: clock)

        recorder.applicationDidBecomeActive()

        XCTAssertEqual(reported, [.saving(sinceLastSave: 0)],
                       "a healthy session reports saving, and reports exactly once")
    }

    /// A recorder that never saw the playback clock has learned nothing and
    /// must say so. Asserted by value, for the same reason as above.
    func testForegroundReturn_withNoPlaybackEver_reportsNoPlayback() {
        let recorder = makeRecorder()
        advance(10_800)

        recorder.applicationDidBecomeActive()

        XCTAssertEqual(reported, [.noPlayback],
                       "an inert recorder must report that it learned nothing, not .dry")
    }

    // MARK: - What actually leaves the device

    /// The commit claims the fleet event carries no book, title, or patron
    /// identity. The tests inject upstream of the real reporter, so without
    /// this that claim has no pin at all.
    func testCrashlyticsPayload_carriesNoPatronOrBookIdentity() {
        var captured: [String: Any] = [:]
        AudiobookPositionTraceRecorder.crashlyticsSaveReport(
            .dry(seconds: 10_800),
            stateAtLastTick: "background",
            emit: { _, _, metadata in captured = metadata ?? [:] }
        )

        XCTAssertEqual(captured["drySeconds"] as? Double, 10_800)
        XCTAssertEqual(captured["applicationStateAtLastTick"] as? String, "background")

        let rendered = captured.map { "\($0.key)=\($0.value)" }.joined(separator: " ").lowercased()
        for forbidden in ["book-1", "bookid", "title", "trackkey", "patron", "barcode"] {
            XCTAssertFalse(rendered.contains(forbidden),
                           "fleet telemetry must not carry \(forbidden): \(rendered)")
        }
    }

    /// Only findings leave the device. A healthy session emitting an event
    /// would bury the signal under every paused session in the install base.
    func testCrashlyticsPayload_isSilentForHealthyVerdicts() {
        var emitted = 0
        for verdict in [PositionSaveVerdict.saving(sinceLastSave: 5),
                        .noPlayback,
                        .playbackStale(sinceLastTick: 900)] {
            AudiobookPositionTraceRecorder.crashlyticsSaveReport(
                verdict, stateAtLastTick: "active", emit: { _, _, _ in emitted += 1 }
            )
        }
        XCTAssertEqual(emitted, 0, "only .dry is a finding")
    }

    // MARK: - Restore gap

    func testRestoreGap_againstAMarkerHoursAhead_reportsBehind() {
        let recorder = makeRecorder()
        store.seed(LastLivePositionMarker(
            bookID: "book-1", trackKey: "a", timestamp: 10_800, recordedAt: clock
        ))

        recorder.evaluateRestoreGap(
            restoredTrackKey: "a",
            restoredTimestamp: 0,
            absoluteOffset: { _, timestamp in timestamp }
        )

        guard case let .behind(seconds)? = gapsReported.first else {
            return XCTFail("expected .behind, got \(gapsReported)")
        }
        XCTAssertEqual(seconds, 10_800, accuracy: 0.001)
    }

    func testRestoreGap_withNoMarker_reportsNoMarker() {
        let recorder = makeRecorder()

        recorder.evaluateRestoreGap(
            restoredTrackKey: "a",
            restoredTimestamp: 0,
            absoluteOffset: { _, timestamp in timestamp }
        )

        XCTAssertEqual(gapsReported.first, .noMarker)
    }

    /// The store is keyed by book id, so a foreign marker is simply absent and
    /// this reports `.noMarker`. Named for what it actually pins — that the
    /// lookup is scoped to this book — rather than claiming to exercise
    /// `.markerForDifferentBook`, which is unreachable through the recorder.
    func testRestoreGap_looksUpOnlyThisBooksMarker() {
        let recorder = makeRecorder()
        store.seed(LastLivePositionMarker(
            bookID: "some-other-book", trackKey: "a", timestamp: 10_800, recordedAt: clock
        ))

        recorder.evaluateRestoreGap(
            restoredTrackKey: "a",
            restoredTimestamp: 0,
            absoluteOffset: { _, timestamp in timestamp }
        )

        XCTAssertEqual(gapsReported.first, .noMarker,
                       "another book's marker is not this book's evidence")
    }
}


/// Lifetime. The first draft created the recorder in `AudiobookLoader` and hung
/// it off the `LoadedAudiobook` STRUCT, which `AudiobookSessionManager.bind`
/// destructures and drops. Every other reference was deliberately weak, so the
/// recorder deallocated seconds after playback began, both Combine
/// subscriptions cancelled, and no verdict could ever fire. A three-hour locked
/// listen would have produced an empty trace, and an empty fleet is
/// indistinguishable from "no defect".
///
/// The recorder is now owned by `AudiobookBookmarkBusinessLogic`, which
/// `AudiobookManager.bookmarkDelegate` retains and the session manager retains
/// in turn, so it lives exactly as long as the saves it measures.
final class AudiobookPositionTraceLifetimeTests: XCTestCase {

    func testRecorder_survivesWhenOnlyTheBookmarkLogicHoldsIt() {
        let book = TPPBookMocker.snapshotAudiobook()
        weak var weakRecorder: AudiobookPositionTraceRecorder?
        var logic: AudiobookBookmarkBusinessLogic?

        autoreleasepool {
            let recorder = AudiobookPositionTraceRecorder(bookID: book.identifier)
            weakRecorder = recorder
            logic = AudiobookBookmarkBusinessLogic(
                book: book,
                registry: TPPBookRegistryMock(),
                annotationsManager: TPPAnnotationMock(),
                positionWriter: nil,
                positionTrace: recorder
            )
        }

        XCTAssertNotNil(
            weakRecorder,
            "the bookmark logic must RETAIN the recorder — it is the only thing that "
            + "outlives session construction, and without it the instrument is inert"
        )
        XCTAssertNotNil(logic)

        logic = nil
        XCTAssertNil(weakRecorder, "and it must not outlive the session either")
    }
}
