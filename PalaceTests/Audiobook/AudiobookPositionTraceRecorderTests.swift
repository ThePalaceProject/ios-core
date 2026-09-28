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
    private var reportedContexts: [PositionTraceContext] = []
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
        reportedContexts = []
        gapsReported = []
        logLines = []
        return AudiobookPositionTraceRecorder(
            bookID: "book-1",
            markerStore: store,
            diagnosticsEnabled: { diagnosticsEnabled },
            reportSaveVerdict: { [weak self] verdict, context in
                self?.reported.append(verdict)
                self?.reportedContexts.append(context)
            },
            reportGapVerdict: { [weak self] in self?.gapsReported.append($0) },
            fileLog: { [weak self] in self?.logLines.append($0) },
            now: { [weak self] in self?.clock ?? Date() }
        )
    }

    /// Drops the per-test collections and the spy store.
    ///
    /// `makeRecorder` resets them on the way in, so no test reads another
    /// test's state today. The declaration is still required: the file names
    /// `AudiobookFileLogger.shared` — which is the singleton every one of these
    /// recorders is built to avoid — and a later test that forgets to go
    /// through `makeRecorder` would inherit whatever the previous one left.
    /// `XCTestCase` keeps an instance per test method alive until the whole
    /// suite finishes, so these arrays are also held for the length of the run
    /// unless something releases them.
    override func tearDownWithError() throws {
        store = nil
        reported = []
        reportedContexts = []
        gapsReported = []
        logLines = []
        try super.tearDownWithError()
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

    /// Every save in a stretch moves the window, not just the first.
    ///
    /// Review found nothing drove two `noteSave` calls inside one live
    /// stretch: gating the update on `current.lastSaveAt == nil` — freezing
    /// the clock after a stretch's first save — left all 67 tests green. The
    /// only two-save test had no stretch at all, so both saves were dropped
    /// and it could not see this.
    ///
    /// Production saves land about every five seconds, so a frozen clock makes
    /// a perfectly healthy three-hour listen report `.dry(10800)` on the
    /// ungated fleet signal — the instrument manufacturing the finding it
    /// exists to test for, which is the worst outcome available here.
    func testSecondSaveInAStretch_movesTheWindowForward() {
        let recorder = makeRecorder()

        driveLivePlayback(recorder, for: 60)
        recorder.noteSave(at: clock)               // first save

        // Keep playing well past the dry threshold, then save again. If only
        // the first save counted, this window is 210s and reads as dry.
        driveLivePlayback(recorder, for: 200)
        recorder.noteSave(at: clock)               // second save
        driveLivePlayback(recorder, for: 10)

        recorder.applicationDidBecomeActive()

        guard case let .saving(since)? = reported.first else {
            return XCTFail(
                "saves kept pace with playback, so this is not a finding — got "
                + "\(reported), which is the first save being measured against "
                + "the whole stretch"
            )
        }
        XCTAssertEqual(since, 10, accuracy: 1,
                       "the window is measured from the LATEST save, not the first")
    }

    /// `.playbackStale` had no recorder-side test — it was produced only by
    /// hand-built stretches in the policy tests, so nothing checked that the
    /// recorder ever reaches it.
    ///
    /// It is the cell that keeps the instrument honest about a session that
    /// ENDED: playback stopped before the check, which explains a quiet save
    /// window on its own and must not be reported as a dry one.
    func testForegroundReturn_afterPlaybackStopped_reportsStaleNotDry() {
        let recorder = makeRecorder()

        driveLivePlayback(recorder, for: 60)
        recorder.noteSave(at: clock)
        advance(900)                                // playback stopped: no ticks

        recorder.applicationDidBecomeActive()

        guard case let .playbackStale(sinceLastTick)? = reported.first else {
            return XCTFail(
                "playback had already stopped, which explains the quiet window "
                + "without a defect — got \(reported)"
            )
        }
        XCTAssertEqual(sinceLastTick, 900, accuracy: 1)
    }

    /// Resume out of an UNSAVED stretch — the remaining gap-bookkeeping cell.
    ///
    /// The covered resume case came out of a stretch that had saved. Out of an
    /// unsaved one there is no save to drop, so the only thing the new stretch
    /// inherits is the gap, and the verdict must still decline to claim health.
    func testResumeOutOfAnUnsavedStretch_stillReportsTheGap() {
        let recorder = makeRecorder()

        driveLivePlayback(recorder, for: 30)   // a stretch that never saves
        advance(600)
        driveLivePlayback(recorder, for: 5)    // resumed

        recorder.applicationDidBecomeActive()

        guard case let .tickGap(gap)? = reported.first else {
            return XCTFail(
                "a stretch opened by a gap has earned no health claim whether or "
                + "not its predecessor saved — got \(reported)"
            )
        }
        XCTAssertEqual(gap, 605, accuracy: 1)
    }

    /// A tick arriving out of order, or after the wall clock steps backwards.
    ///
    /// The policy clamps its quiet window with `max(0, …)`; the recorder
    /// clamps nothing, so a negative interval reaches the stretch bookkeeping.
    /// It must not be counted as a gap — a backwards clock is not evidence
    /// that playback stopped — and it must not produce a negative verdict.
    func testOutOfOrderTick_isNotCountedAsAGap() {
        let recorder = makeRecorder()

        driveLivePlayback(recorder, for: 60)
        advance(-30)                            // clock steps backwards
        recorder.notePlaybackTick(trackKey: "a", timestamp: 61, at: clock)
        advance(30)
        driveLivePlayback(recorder, for: 5)

        recorder.applicationDidBecomeActive()

        XCTAssertEqual(reportedContexts.first?.tickGapCount, 0,
                       "a backwards clock step is not a tick-stream gap; counting "
                       + "it would make every NTP correction look like a stall")
        if case let .dry(seconds)? = reported.first {
            XCTAssertGreaterThanOrEqual(seconds, 0, "no negative dry window")
        }
        if case let .tickGap(seconds)? = reported.first {
            XCTAssertGreaterThanOrEqual(seconds, 0, "no negative gap")
        }
    }

    /// Foregrounding twice reports twice, and the second report is not a
    /// stale copy of the first.
    ///
    /// The verdict is computed per call rather than cached, and nothing
    /// asserted that: a cached first verdict would keep reporting a resolved
    /// finding for the rest of the session, inflating the fleet count from one
    /// session.
    func testRepeatedForegroundReturns_reportEachTimeFromCurrentState() {
        let recorder = makeRecorder()

        driveLivePlayback(recorder, for: 200)   // no saves yet — dry
        recorder.applicationDidBecomeActive()

        guard case .dry? = reported.first else {
            return XCTFail("precondition: a 200s unsaved stretch is dry, got \(reported)")
        }

        recorder.noteSave(at: clock)            // the save lands
        driveLivePlayback(recorder, for: 5)
        recorder.applicationDidBecomeActive()

        XCTAssertEqual(reported.count, 2, "each foreground return produces a verdict")
        guard case let .saving(since)? = reported.last else {
            return XCTFail(
                "the second verdict must reflect the save, not repeat the first — "
                + "got \(reported)"
            )
        }
        XCTAssertEqual(since, 5, accuracy: 1)
    }

    /// A backwards clock step must not turn a pause into a health claim.
    ///
    /// The monotonic clamp added for a single out-of-order tick broke this: a
    /// sustained backwards step holds the reference AHEAD of now for the
    /// step's duration, so a pause ending in that shadow measures a negative
    /// gap, opens no stretch, keeps the stale save, and the verdict resolves
    /// toward health. Measured against a control — the same ten-minute pause
    /// reports `.tickGap(605)` on a steady clock and reported `.saving(0.0)`
    /// across a thirty-minute step. `.saving` never reaches the fleet, so that
    /// was a silent false negative of the kind this instrument exists to avoid.
    func testSustainedBackwardsClockStep_isReportedNotMeasuredThrough() {
        let recorder = makeRecorder()
        driveLivePlayback(recorder, for: 60)
        recorder.noteSave(at: clock)
        driveLivePlayback(recorder, for: 60)

        advance(-1800)
        driveLivePlayback(recorder, for: 60)
        advance(600)
        driveLivePlayback(recorder, for: 5)

        recorder.applicationDidBecomeActive()

        guard case let .clockRegressed(by)? = reported.first else {
            return XCTFail(
                "a reference ahead of now cannot measure anything, so the "
                + "regression is the verdict — got \(reported)"
            )
        }
        XCTAssertGreaterThan(by, 0, "the regression carries how far back the clock went")
        XCTAssertEqual(reportedContexts.first?.clockRegressionCount, 1,
                       "one episode, not one per tick — the count sits beside "
                       + "tickGapCount and has to mean the same kind of thing")
    }

    /// The control: the same pause on a steady clock is still a tick gap, so
    /// the regression case cannot be swallowing every pause.
    func testControl_samePauseOnASteadyClock_isStillATickGap() {
        let recorder = makeRecorder()
        driveLivePlayback(recorder, for: 60)
        recorder.noteSave(at: clock)
        driveLivePlayback(recorder, for: 60)

        advance(600)
        driveLivePlayback(recorder, for: 5)

        recorder.applicationDidBecomeActive()

        guard case .tickGap? = reported.first else {
            return XCTFail("a pause with no clock step is a tick gap, got \(reported)")
        }
        XCTAssertEqual(reportedContexts.first?.clockRegressionCount, 0)
    }

    /// A clock that steps FORWARD and is then corrected BACK.
    ///
    /// Review found this reachable on the tip that introduced the clamp: the
    /// forward step stamps `lastTickAt` in the future, the clamp pins it there
    /// for the excursion, and `sinceLastTick` goes negative — so the
    /// `.playbackStale` guard never fires and a session whose playback STOPPED
    /// is measured as live. Measured there as `.dry(190)` on the ungated 404
    /// signal: an affirmative finding the instrument had not earned, which is
    /// the one outcome `.tickGap`, `.playbackStale` and `.markerUnresolvable`
    /// all exist to prevent.
    ///
    /// It is reported rather than measured through. `.clockRegressed` is not
    /// `.playbackStale` — the stale reading is the one a steady clock would
    /// have produced, and it is lost here. That is the honest trade: this
    /// session's intervals are unusable, and saying so beats reporting either
    /// of the two readings that could be wrong.
    func testForwardClockStepThenCorrection_isReportedNotMeasuredThrough() {
        let recorder = makeRecorder()

        driveLivePlayback(recorder, for: 5)
        advance(300)                                        // clock jumps forward
        recorder.notePlaybackTick(trackKey: "a", timestamp: 305, at: clock)
        advance(-295)                                       // and is corrected back
        recorder.noteSave(at: clock)
        driveLivePlayback(recorder, for: 5)                 // plays a little, then stops
        advance(185)                                        // patron foregrounds much later

        recorder.applicationDidBecomeActive()

        if case .dry = reported.first {
            XCTFail(
                "a reference stamped in the future makes every interval wrong; "
                + "reporting a dry window from it is an unearned finding on the "
                + "ungated signal — got \(reported)"
            )
        }
        guard case .clockRegressed? = reported.first else {
            return XCTFail("expected the regression to be reported, got \(reported)")
        }
    }

    /// The E-recovery path: a gap-born stretch earns its health back.
    ///
    /// The policy decides this on a hand-built stretch; nothing showed the
    /// RECORDER can produce one. Closes the resume -> save -> keep playing ->
    /// foreground scenario, which is three cells of the table at once.
    func testGapBornStretch_thatThenSaves_reportsSaving() {
        let recorder = makeRecorder()

        driveLivePlayback(recorder, for: 30)
        advance(600)                            // a gap opens a new stretch
        driveLivePlayback(recorder, for: 20)
        recorder.noteSave(at: clock)            // which then saves
        driveLivePlayback(recorder, for: 5)

        recorder.applicationDidBecomeActive()

        guard case let .saving(since)? = reported.first else {
            return XCTFail(
                "a stretch that has saved has evidence of its own and no longer "
                + "depends on how it began — got \(reported)"
            )
        }
        XCTAssertEqual(since, 5, accuracy: 1)
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

    /// The gap counters are what let the fleet separate an overnight pause
    /// from an overnight stall, and nothing asserted either of them: review
    /// found `tickGapCount += 1` -> `-= 1` survived the whole suite.
    ///
    /// Also pins the app state observed at the last TICK rather than at
    /// foreground return, where it is `.active` by definition and would be a
    /// constant dressed as a measurement.
    func testVerdictContext_countsEveryGapAndKeepsTheLongest() {
        let recorder = makeRecorder()

        driveLivePlayback(recorder, for: 30)          // stretch 1
        advance(600)                                  // gap 1 — ten minutes
        driveLivePlayback(recorder, for: 30)          // stretch 2
        advance(10_800)                               // gap 2 — three hours
        driveLivePlayback(recorder, for: 30)          // stretch 3
        advance(120)                                  // gap 3 — two minutes
        driveLivePlayback(recorder, for: 30)          // stretch 4

        recorder.applicationDidBecomeActive()

        let context = reportedContexts.first
        XCTAssertEqual(context?.tickGapCount, 3,
                       "three gaps opened three stretches; a count that drifts "
                       + "makes a choppy session and a clean one look alike")
        // 10_805, not 10_800: `driveLivePlayback` advances one stride before
        // its first tick, so the measured gap is the pause plus that stride.
        XCTAssertEqual(context?.longestTickGap ?? 0, 10_805, accuracy: 1,
                       "the worst gap is the one that distinguishes a stall, so "
                       + "the later two-minute gap must not replace it")

        // `applicationStateAtLastTick` is deliberately NOT asserted here. In a
        // test host the app is `.active` when the tick is recorded and
        // `.active` again at foreground return, so an assertion would pass
        // whichever of the two the code sampled — it cannot tell them apart,
        // which is the only thing worth checking about that field.
    }

    /// Only the LARGEST gap is kept, asserted in the order that would hide a
    /// bug: the big gap first, then a small one. `max` replaced by an
    /// unconditional assignment passes the test above and fails this one.
    func testVerdictContext_keepsTheLargestGap_notTheMostRecent() {
        let recorder = makeRecorder()

        driveLivePlayback(recorder, for: 30)
        advance(10_800)
        driveLivePlayback(recorder, for: 30)
        advance(60)
        driveLivePlayback(recorder, for: 30)

        recorder.applicationDidBecomeActive()

        XCTAssertEqual(reportedContexts.first?.longestTickGap ?? 0, 10_805, accuracy: 1,
                       "a three-hour gap followed by a one-minute gap must still "
                       + "report three hours; the recent one is not the worst one")
    }

    /// `gap == 0` is not a clock regression, and the clamp is what makes that
    /// case reachable at all: during a backwards excursion the reference is
    /// pinned at a fixed value, so the instant the clock catches up exactly the
    /// gap is zero. A duplicate tick carrying an identical `Date` produces it
    /// too.
    ///
    /// Review measured `gap < 0` -> `<=` SURVIVING the whole suite. Counting
    /// those would inflate the one field whose stated job is marking sessions
    /// for exclusion from the aggregate — the sibling guard in the policy got
    /// its zero boundary pinned and this one had not.
    func testTickAtExactlyTheSameInstant_isNotAClockRegression() {
        let recorder = makeRecorder()

        driveLivePlayback(recorder, for: 30)
        // Same instant as the previous tick: gap is exactly 0, not negative.
        recorder.notePlaybackTick(trackKey: "a", timestamp: 30, at: clock)
        recorder.notePlaybackTick(trackKey: "a", timestamp: 30, at: clock)
        driveLivePlayback(recorder, for: 5)

        recorder.applicationDidBecomeActive()

        XCTAssertEqual(reportedContexts.first?.clockRegressionCount, 0,
                       "a tick at the same instant is not the clock moving "
                       + "backwards; counting it inflates the exclusion key")
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
            context: PositionTraceContext(applicationStateAtLastTick: "background",
                                          tickGapCount: 0, longestTickGap: 0,
                                          clockRegressionCount: 0),
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

    /// Which verdicts leave the device, stated over the whole enum.
    ///
    /// The previous version listed three cases by hand and asserted nothing was
    /// emitted, with the message "only .dry is a finding". When `.tickGap` was
    /// added that message became false and the list became one short — and a
    /// case missing from a list reads exactly like a case that stays silent.
    /// Deleting the entire `.tickGap` emit arm left all 63 tests green.
    ///
    /// The `switch` below has no `default`, so adding a verdict case stops this
    /// file COMPILING until someone says which side of the partition it is on.
    /// That is the part a list cannot do.
    func testCrashlyticsSaveReport_emitsExactlyTheFindings() {
        let samples: [PositionSaveVerdict] = [
            .noPlayback,
            .playbackStale(sinceLastTick: 900),
            .saving(sinceLastSave: 5),
            .dry(seconds: 10_800),
            .tickGap(seconds: 10_800),
            .clockRegressed(by: 1_800)
        ]

        for verdict in samples {
            let expected: TPPErrorCode?
            switch verdict {
            case .noPlayback, .playbackStale, .saving:
                // Healthy, or the instrument has nothing to say. Reporting
                // these would bury the signal under every paused session in
                // the install base.
                expected = nil
            case .dry:
                expected = .audiobookPositionSaveDry
            case .tickGap:
                expected = .audiobookPositionTickGap
            case .clockRegressed:
                expected = .audiobookPositionClockRegressed
            }

            var codes: [TPPErrorCode] = []
            AudiobookPositionTraceRecorder.crashlyticsSaveReport(
                verdict,
                context: PositionTraceContext(applicationStateAtLastTick: "active",
                                              tickGapCount: 0, longestTickGap: 0,
                                              clockRegressionCount: 0),
                emit: { code, _, _ in codes.append(code) }
            )
            XCTAssertEqual(codes, expected.map { [$0] } ?? [],
                           "\(verdict) routed wrongly")
        }
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
