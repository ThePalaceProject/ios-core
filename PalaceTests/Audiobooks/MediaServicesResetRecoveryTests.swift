//
//  MediaServicesResetRecoveryTests.swift
//  PalaceTests
//
//  PP-5241: when iOS restarts its media server (mediaserverd), every
//  AVFoundation player and audio-session object becomes invalid. The player
//  reports AVError -11819 (`mediaServicesWereReset`) and, 25 ms to 1.3 s later,
//  usually a second failure (`OpenAccessPlayerError.playerNotReady`, code 2) at
//  position 0.0. AVAudioSession also posts `mediaServicesWereResetNotification`.
//  The notification and the failure can arrive in either order.
//
//  These tests pin four layers:
//    1. `MediaServicesReset.isMediaServicesReset`, the error classifier.
//    2. `MediaServicesResetRecoveryReducer.reduce`: the full states x events
//       table, one assertion per cell.
//    3. `MediaServicesResetRecovery`: the coordinator's observation, de-dup,
//       swallow and bound, driven through a private NotificationCenter and a
//       spy host.
//    4. The session manager's pure inputs to the coordinator: what counts as
//       "was playing", and when a notification finds a session to recover.
//
//  NOT pinned here: the manager's one-line hooks into `handleManagerState`
//  (`.playbackFailed` / `.playbackBegan`) and `openAudiobook`. Reaching
//  `handleManagerState` needs `currentBook`, which only the auth-gated open
//  path writes (see the note in the `.playbackCompleted` arm), so those call
//  sites are covered by reading them, not by a test.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import XCTest
@testable import Palace
import PalaceBookModel

// MARK: - Classifier

final class MediaServicesResetClassifierTests: XCTestCase {

    private func avError(_ code: Int, underlying: Error? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: AVFoundationErrorDomain, code: code, userInfo: info)
    }

    func testIsMediaServicesReset_topLevel11819_isTrue() {
        XCTAssertTrue(MediaServicesReset.isMediaServicesReset(avError(-11819)))
    }

    func testIsMediaServicesReset_nestedUnderToolkitError_isTrue() {
        // The field shape: a wrapper error whose NSUnderlyingError is the AV one.
        let wrapper = NSError(domain: "org.thepalaceproject.audiobook", code: 7,
                              userInfo: [NSUnderlyingErrorKey: avError(-11819)])
        XCTAssertTrue(MediaServicesReset.isMediaServicesReset(wrapper))
    }

    func testIsMediaServicesReset_twoLevelsDeep_isTrue() {
        let inner = NSError(domain: AVFoundationErrorDomain, code: -11800,
                            userInfo: [NSUnderlyingErrorKey: avError(-11819)])
        let outer = NSError(domain: NSURLErrorDomain, code: -1,
                            userInfo: [NSUnderlyingErrorKey: inner])
        XCTAssertTrue(MediaServicesReset.isMediaServicesReset(outer))
    }

    func testIsMediaServicesReset_generic11800WithNonResetUnderlying_isFalse() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12873)
        XCTAssertFalse(MediaServicesReset.isMediaServicesReset(avError(-11800, underlying: underlying)))
    }

    func testIsMediaServicesReset_sameCodeOtherDomain_isFalse() {
        XCTAssertFalse(MediaServicesReset.isMediaServicesReset(NSError(domain: NSOSStatusErrorDomain, code: -11819)))
    }

    func testIsMediaServicesReset_playerNotReady_isFalse() {
        let playerNotReady = NSError(domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer", code: 2)
        XCTAssertFalse(MediaServicesReset.isMediaServicesReset(playerNotReady))
    }

    func testIsMediaServicesReset_nil_isFalse() {
        XCTAssertFalse(MediaServicesReset.isMediaServicesReset(nil))
    }

    func testIsMediaServicesReset_resetBelowTheWalkDepth_isFalse() {
        // The walk is bounded so a pathological chain cannot spin; a reset
        // buried deeper than the bound is not recognised. 20 wrappers deep.
        var error: NSError = avError(-11819)
        for i in 0..<20 {
            error = NSError(domain: "wrapper", code: i, userInfo: [NSUnderlyingErrorKey: error])
        }
        XCTAssertFalse(MediaServicesReset.isMediaServicesReset(error))
    }
}

// MARK: - Transition table

/// States x events for the recovery phase. Every cell is listed explicitly and
/// asserted; `testTable_coversEveryStateEventPair` fails if a state or event is
/// added without a row.
///
/// | state \ event              | idle                         | recovering(B)                    | recovered(B)                  |
/// |----------------------------|------------------------------|----------------------------------|-------------------------------|
/// | resetNotification(B)       | recovering(B), startRecovery | recovering(B), none              | recovered(B), none            |
/// | resetNotification(nil)     | idle, none                   | recovering(B), none              | recovered(B), none            |
/// | resetFailure(B)            | recovering(B), startRecovery | recovering(B), swallow           | recovered(B), passThrough     |
/// | otherFailure(B)            | idle, passThrough            | recovering(B), swallow           | recovered(B), passThrough     |
/// | recoverySucceeded(B)       | idle, none                   | recovered(B), none               | recovered(B), none            |
/// | recoveryFailed(B)          | idle, none                   | idle, failTerminally(B)          | recovered(B), none            |
/// | playbackBegan(B)           | idle, none                   | recovering(B), none              | idle, none                    |
/// | sessionEnded               | idle, none                   | idle, none                       | idle, none                    |
/// | any event naming book C≠B  | —                            | evaluated as idle                | evaluated as idle             |
///
/// `recovered(B)` is the one-recovery-per-episode bound: it holds until the
/// re-established session plays or the patron starts a fresh open.
final class MediaServicesResetRecoveryTableTests: XCTestCase {

    typealias Phase = MediaServicesResetRecoveryPhase
    typealias Event = MediaServicesResetRecoveryEvent
    typealias Effect = MediaServicesResetRecoveryEffect

    private let b = "book-B"
    private let c = "book-C"

    private struct Cell {
        let from: Phase
        let event: Event
        let to: Phase
        let effect: Effect
        let line: UInt
    }

    private var cells: [Cell] {
        let idle = Phase.idle
        let recovering = Phase.recovering(bookId: b)
        let recovered = Phase.recovered(bookId: b)
        return [
            // resetNotification with the book loaded
            Cell(from: idle, event: .resetNotification(loadedBookId: b), to: recovering, effect: .startRecovery(bookId: b), line: #line),
            Cell(from: recovering, event: .resetNotification(loadedBookId: b), to: recovering, effect: .none, line: #line),
            Cell(from: recovered, event: .resetNotification(loadedBookId: b), to: recovered, effect: .none, line: #line),
            // resetNotification with nothing loaded
            Cell(from: idle, event: .resetNotification(loadedBookId: nil), to: idle, effect: .none, line: #line),
            Cell(from: recovering, event: .resetNotification(loadedBookId: nil), to: recovering, effect: .none, line: #line),
            Cell(from: recovered, event: .resetNotification(loadedBookId: nil), to: recovered, effect: .none, line: #line),
            // -11819 failure
            Cell(from: idle, event: .resetFailure(bookId: b), to: recovering, effect: .startRecovery(bookId: b), line: #line),
            Cell(from: recovering, event: .resetFailure(bookId: b), to: recovering, effect: .swallow, line: #line),
            Cell(from: recovered, event: .resetFailure(bookId: b), to: recovered, effect: .passThrough, line: #line),
            // any other failure (the follow-on storm while recovering)
            Cell(from: idle, event: .otherFailure(bookId: b), to: idle, effect: .passThrough, line: #line),
            Cell(from: recovering, event: .otherFailure(bookId: b), to: recovering, effect: .swallow, line: #line),
            Cell(from: recovered, event: .otherFailure(bookId: b), to: recovered, effect: .passThrough, line: #line),
            // recovery re-established the session
            Cell(from: idle, event: .recoverySucceeded(bookId: b), to: idle, effect: .none, line: #line),
            Cell(from: recovering, event: .recoverySucceeded(bookId: b), to: recovered, effect: .none, line: #line),
            Cell(from: recovered, event: .recoverySucceeded(bookId: b), to: recovered, effect: .none, line: #line),
            // recovery did not re-establish the session
            Cell(from: idle, event: .recoveryFailed(bookId: b), to: idle, effect: .none, line: #line),
            Cell(from: recovering, event: .recoveryFailed(bookId: b), to: idle, effect: .failTerminally(bookId: b), line: #line),
            Cell(from: recovered, event: .recoveryFailed(bookId: b), to: recovered, effect: .none, line: #line),
            // the session played again
            Cell(from: idle, event: .playbackBegan(bookId: b), to: idle, effect: .none, line: #line),
            Cell(from: recovering, event: .playbackBegan(bookId: b), to: recovering, effect: .none, line: #line),
            Cell(from: recovered, event: .playbackBegan(bookId: b), to: idle, effect: .none, line: #line),
            // the patron started a fresh open (book changed or re-tapped)
            Cell(from: idle, event: .sessionEnded, to: idle, effect: .none, line: #line),
            Cell(from: recovering, event: .sessionEnded, to: idle, effect: .none, line: #line),
            Cell(from: recovered, event: .sessionEnded, to: idle, effect: .none, line: #line),
        ]
    }

    func testTable_everyCell() {
        for cell in cells {
            let (to, effect) = MediaServicesResetRecoveryReducer.reduce(cell.from, cell.event)
            XCTAssertEqual(to, cell.to, "\(cell.from) + \(cell.event): next state", line: cell.line)
            XCTAssertEqual(effect, cell.effect, "\(cell.from) + \(cell.event): effect", line: cell.line)
        }
    }

    func testTable_coversEveryStateEventPair() {
        // 3 states x 8 event shapes (resetNotification counted twice: loaded / nil).
        let pairs = Set(cells.map { "\($0.from.shape)|\($0.event.shape)" })
        XCTAssertEqual(pairs.count, 3 * 8, "every (state, event) pair needs exactly one row")
        XCTAssertEqual(cells.count, pairs.count, "no duplicate rows")
    }

    // Events naming a different book than the phase are evaluated as if idle:
    // the phase is stale (its book is no longer the session's book).

    func testStaleBook_resetFailureForOtherBookWhileRecovering_startsRecoveryForThatBook() {
        let (to, effect) = MediaServicesResetRecoveryReducer.reduce(.recovering(bookId: b), .resetFailure(bookId: c))
        XCTAssertEqual(to, .recovering(bookId: c))
        XCTAssertEqual(effect, .startRecovery(bookId: c))
    }

    func testStaleBook_otherFailureForOtherBookWhileRecovering_passesThrough() {
        let (to, effect) = MediaServicesResetRecoveryReducer.reduce(.recovering(bookId: b), .otherFailure(bookId: c))
        XCTAssertEqual(to, .idle)
        XCTAssertEqual(effect, .passThrough)
    }

    // A completion names the book its recovery task was started for. When
    // that is not the phase's book, the task was superseded: its result
    // belongs to no live episode and must not move the phase.

    func testStaleBook_recoveryFailedForOtherBook_leavesTheLiveRecoveryAlone() {
        let (to, effect) = MediaServicesResetRecoveryReducer.reduce(.recovering(bookId: b), .recoveryFailed(bookId: c))
        XCTAssertEqual(to, .recovering(bookId: b))
        XCTAssertEqual(effect, .none)
    }

    func testStaleBook_recoverySucceededForOtherBook_leavesTheLiveRecoveryAlone() {
        let (to, effect) = MediaServicesResetRecoveryReducer.reduce(.recovering(bookId: b), .recoverySucceeded(bookId: c))
        XCTAssertEqual(to, .recovering(bookId: b))
        XCTAssertEqual(effect, .none)
    }

    func testStaleBook_completionForOtherBookWhileRecovered_leavesThePhaseAlone() {
        XCTAssertEqual(MediaServicesResetRecoveryReducer.reduce(.recovered(bookId: b), .recoverySucceeded(bookId: c)).0,
                       .recovered(bookId: b))
        XCTAssertEqual(MediaServicesResetRecoveryReducer.reduce(.recovered(bookId: b), .recoveryFailed(bookId: c)).0,
                       .recovered(bookId: b))
    }

    func testStaleBook_resetFailureForOtherBookWhileRecovered_startsRecovery() {
        let (to, effect) = MediaServicesResetRecoveryReducer.reduce(.recovered(bookId: b), .resetFailure(bookId: c))
        XCTAssertEqual(to, .recovering(bookId: c))
        XCTAssertEqual(effect, .startRecovery(bookId: c))
    }

    func testStaleBook_notificationForOtherLoadedBookWhileRecovered_startsRecovery() {
        let (to, effect) = MediaServicesResetRecoveryReducer.reduce(.recovered(bookId: b), .resetNotification(loadedBookId: c))
        XCTAssertEqual(to, .recovering(bookId: c))
        XCTAssertEqual(effect, .startRecovery(bookId: c))
    }
}

private extension MediaServicesResetRecoveryPhase {
    var shape: String {
        switch self {
        case .idle: return "idle"
        case .recovering: return "recovering"
        case .recovered: return "recovered"
        }
    }
}

private extension MediaServicesResetRecoveryEvent {
    var shape: String {
        switch self {
        case .resetNotification(let id): return id == nil ? "notification-nil" : "notification"
        case .resetFailure: return "resetFailure"
        case .otherFailure: return "otherFailure"
        case .recoverySucceeded: return "recoverySucceeded"
        case .recoveryFailed: return "recoveryFailed"
        case .playbackBegan: return "playbackBegan"
        case .sessionEnded: return "sessionEnded"
        }
    }
}

// MARK: - Coordinator

@MainActor
private final class SpyResetHost: MediaServicesResetRecoveryHost {
    var loadedSession: MediaServicesResetSession?
    /// What `reestablish` returns. Set to nil to suspend until `release(_:)`.
    var reestablishResult: Bool? = true

    private(set) var enteredRecovering: [String] = []
    private(set) var persistedLastKnownPosition: [String] = []
    /// Every host call in the order it arrived, so a test can pin sequencing.
    private(set) var callOrder: [String] = []
    private(set) var reestablishCalls: [(bookId: String, resumePlaying: Bool)] = []
    private(set) var terminalFailures: [String] = []
    /// Suspended `reestablish` calls, oldest first, so a test can complete a
    /// superseded recovery after a newer one started.
    private var pending: [CheckedContinuation<Bool, Never>] = []
    /// Releases that land before a recovery task reaches `reestablish`. The
    /// task is only scheduled when the recovery starts, so a test that releases
    /// straight after triggering usually gets here first; without this the
    /// release is dropped and the task suspends for good.
    private var earlyReleases: [Bool] = []

    func mediaServicesResetLoadedSession() -> MediaServicesResetSession? { loadedSession }

    func mediaServicesResetPersistLastKnownPosition(bookId: String) {
        persistedLastKnownPosition.append(bookId)
        callOrder.append("persist:\(bookId)")
    }

    func mediaServicesResetEnterRecovering(bookId: String) {
        enteredRecovering.append(bookId)
        callOrder.append("enterRecovering:\(bookId)")
    }

    func mediaServicesResetReestablish(book: TPPBook, resumePlaying: Bool) async -> Bool {
        reestablishCalls.append((book.identifier, resumePlaying))
        callOrder.append("reestablish:\(book.identifier)")
        if let reestablishResult { return reestablishResult }
        if !earlyReleases.isEmpty { return earlyReleases.removeFirst() }
        return await withCheckedContinuation { pending.append($0) }
    }

    func mediaServicesResetFailTerminally(bookId: String) { terminalFailures.append(bookId) }

    /// Completes the oldest suspended recovery.
    func release(_ result: Bool) {
        guard !pending.isEmpty else {
            earlyReleases.append(result)
            return
        }
        pending.removeFirst().resume(returning: result)
    }

    /// Completes every suspended recovery (teardown).
    func releaseAll(_ result: Bool) {
        while !pending.isEmpty { pending.removeFirst().resume(returning: result) }
    }
}

@MainActor
final class MediaServicesResetRecoveryCoordinatorTests: XCTestCase {

    private var center: NotificationCenter!
    private var host: SpyResetHost!
    private var recovery: MediaServicesResetRecovery!
    private var book: TPPBook!

    private let resetError = NSError(domain: AVFoundationErrorDomain, code: -11819)
    /// The same reset as AVFoundation also reports it: -11800 with the -11819
    /// underneath. One reset can surface in both encodings.
    private let wrappedResetError = NSError(
        domain: AVFoundationErrorDomain,
        code: -11800,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: AVFoundationErrorDomain, code: -11819)]
    )
    /// How many crash reports the coordinator asked for.
    private var recordedFailures = 0

    private func recordFailure() { recordedFailures += 1 }
    private let playerNotReady = NSError(domain: "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer", code: 2)

    override func setUp() async throws {
        try await super.setUp()
        center = NotificationCenter()
        host = SpyResetHost()
        recovery = MediaServicesResetRecovery(notificationCenter: center)
        recovery.host = host
        recordedFailures = 0
        book = TPPBookMocker.mockBook(identifier: "reset-book", title: "Reset Book", distributorType: .OpenAccessAudiobook)
    }

    override func tearDown() async throws {
        host?.releaseAll(false)
        recovery = nil
        host = nil
        center = nil
        book = nil
        try await super.tearDown()
    }

    private func postReset() {
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    private func awaitRecovery() async {
        await recovery.recoveryTask?.value
    }

    // MARK: One crash report per reset episode

    // PP-5242's deduplicator keys on the error's structure, so the two
    // encodings of one reset are two different keys to it. Episode identity
    // therefore comes from here: the first reset-shaped failure of an episode
    // is reported, and nothing else in that episode is.

    func testResetFailure_startingARecovery_isReportedOnce() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await awaitRecovery()

        XCTAssertEqual(recordedFailures, 1)
    }

    func testBothEncodingsOfOneReset_produceOneReport() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)
        host.reestablishResult = nil

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: wrappedResetError, resumePlaying: true, record: recordFailure))
        host.release(true)
        await awaitRecovery()

        XCTAssertEqual(recordedFailures, 1)
    }

    func testNotificationFirst_thenResetFailure_reportsTheFailureOnce() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)
        host.reestablishResult = nil

        postReset()
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: wrappedResetError, resumePlaying: true, record: recordFailure))
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        host.release(true)
        await awaitRecovery()

        XCTAssertEqual(recordedFailures, 1, "the reset must stay visible in Crashlytics when the notification wins the race")
    }

    func testNotificationOnly_reportsNothing() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)

        postReset()
        await awaitRecovery()

        XCTAssertEqual(recordedFailures, 0)
    }

    func testFollowOnNonResetFailure_duringRecovery_isNotReported() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)
        host.reestablishResult = nil

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: playerNotReady, resumePlaying: true, record: recordFailure))
        host.release(true)
        await awaitRecovery()

        XCTAssertEqual(recordedFailures, 1)
    }

    func testANewEpisodeAfterPlaybackResumes_isReportedAgain() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await awaitRecovery()
        recovery.handlePlaybackBegan(bookId: book.identifier)
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await awaitRecovery()

        XCTAssertEqual(recordedFailures, 2)
    }

    func testFailurePassedThroughToNormalHandling_isNotReportedHere() async {
        // After a completed recovery and before playback begins, a further
        // reset falls through to today's handling, which reports it itself.
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await awaitRecovery()
        XCTAssertFalse(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))

        XCTAssertEqual(recordedFailures, 1)
    }

    // MARK: A superseded recovery's completion is ignored

    // A recovery task can outlive its episode: the session can end mid-recovery
    // and a new reset start a new episode, or the patron can switch books. The
    // old task's completion must not move the NEW episode's phase.

    private let otherBook = TPPBookMocker.mockBook(identifier: "other-book", title: "Other Book", distributorType: .OpenAccessAudiobook)

    func testLateCompletionFromAnEndedEpisode_doesNotMoveTheNewEpisodeOfTheSameBook() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)
        host.reestablishResult = nil

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await settleRecoveryStart()
        let firstEpisodeTask = recovery.recoveryTask
        recovery.handleSessionEnded()
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await settleRecoveryStart()
        XCTAssertEqual(host.reestablishCalls.count, 2, "both recoveries must be suspended in reestablish before the first is released")

        host.release(true) // the FIRST episode's task completes
        await firstEpisodeTask?.value

        XCTAssertEqual(recovery.phase, .recovering(bookId: "reset-book"),
                       "the second episode is still recovering; the first episode's success belongs to nobody")
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: playerNotReady, resumePlaying: true, record: recordFailure),
                      "follow-on failures of the live recovery must still be swallowed")
    }

    func testLateCompletionForAnotherBook_doesNotEndTheCurrentBooksRecovery() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)
        host.reestablishResult = nil

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await settleRecoveryStart()
        let supersededTask = recovery.recoveryTask
        XCTAssertTrue(recovery.handlePlaybackFailure(book: otherBook, error: resetError, resumePlaying: true, record: recordFailure))
        await settleRecoveryStart()
        XCTAssertEqual(host.reestablishCalls.count, 2, "both recoveries must be suspended in reestablish before the first is released")

        host.release(true) // reset-book's (superseded) recovery completes
        await supersededTask?.value

        XCTAssertEqual(recovery.phase, .recovering(bookId: "other-book"))
        XCTAssertTrue(recovery.handlePlaybackFailure(book: otherBook, error: playerNotReady, resumePlaying: true, record: recordFailure))
    }

    func testLateFailureFromAnEndedEpisode_doesNotFailTheNewEpisodeTerminally() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)
        host.reestablishResult = nil

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await settleRecoveryStart()
        let firstEpisodeTask = recovery.recoveryTask
        recovery.handleSessionEnded()
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await settleRecoveryStart()
        XCTAssertEqual(host.reestablishCalls.count, 2, "both recoveries must be suspended in reestablish before the first is released")

        host.release(false) // the FIRST episode's task fails
        await firstEpisodeTask?.value

        XCTAssertTrue(host.terminalFailures.isEmpty)
        XCTAssertEqual(recovery.phase, .recovering(bookId: "reset-book"))
    }

    func testNotificationOnlyEpisode_thenPassThroughReset_isNotReportedHere() async {
        // The pass-through goes to today's handling, which reports it itself.
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)

        postReset()
        await awaitRecovery()
        XCTAssertEqual(recovery.phase, .recovered(bookId: "reset-book"))
        XCTAssertFalse(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))

        XCTAssertEqual(recordedFailures, 0)
    }

    /// Lets a just-started recovery task reach `reestablish` without awaiting a
    /// task that is deliberately suspended. Only used BEFORE a release: a
    /// released task is awaited directly, so a slow runner cannot turn the
    /// "phase unchanged" assertions into checks of a task that has not run.
    private func settleRecoveryStart() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: Position is saved before the session is torn down

    // The rebuild restores the last PERSISTED position, and the periodic
    // autosave writes only every 15 s, so without this save a reset loses up
    // to 15 s of listening (measured on device: 958 s -> 948 s). The save must
    // come first: `reestablish` tears the dead session down without persisting.

    func testRecoveryStart_whilePlaying_persistsLastKnownPositionBeforeTearingDown() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)

        postReset()
        await awaitRecovery()

        XCTAssertEqual(host.callOrder, [
            "persist:reset-book",
            "enterRecovering:reset-book",
            "reestablish:reset-book",
        ])
    }

    func testRecoveryStart_whilePaused_persistsLastKnownPositionBeforeTearingDown() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: false)

        postReset()
        await awaitRecovery()

        XCTAssertEqual(host.callOrder, [
            "persist:reset-book",
            "enterRecovering:reset-book",
            "reestablish:reset-book",
        ])
    }

    func testFailureTriggeredRecovery_persistsLastKnownPositionOnce_evenWithFollowOnFailures() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)
        host.reestablishResult = nil

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: playerNotReady, resumePlaying: true, record: recordFailure))
        postReset()
        host.release(true)
        await awaitRecovery()

        XCTAssertEqual(host.persistedLastKnownPosition, ["reset-book"],
                       "a follow-on failure or a late notification must not save again: the dead player's position is not trusted")
    }

    func testUnrelatedFailure_whenIdle_doesNotPersistAPosition() {
        XCTAssertFalse(recovery.handlePlaybackFailure(book: book, error: playerNotReady, resumePlaying: true, record: recordFailure))

        XCTAssertTrue(host.persistedLastKnownPosition.isEmpty)
    }

    // MARK: Trigger: notification

    func testNotification_whilePlaying_reestablishesOnceAndResumesPlaying() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)

        postReset()
        await awaitRecovery()

        XCTAssertEqual(host.enteredRecovering, ["reset-book"], "the session must show loading while it recovers")
        XCTAssertEqual(host.reestablishCalls.map(\.bookId), ["reset-book"])
        XCTAssertEqual(host.reestablishCalls.first?.resumePlaying, true)
        XCTAssertEqual(recovery.phase, .recovered(bookId: "reset-book"))
    }

    func testNotification_whilePaused_reestablishesWithoutResumingPlayback() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: false)

        postReset()
        await awaitRecovery()

        XCTAssertEqual(host.reestablishCalls.count, 1)
        XCTAssertEqual(host.reestablishCalls.first?.resumePlaying, false)
    }

    func testNotification_withNoLoadedSession_doesNothing() async {
        host.loadedSession = nil

        postReset()
        await awaitRecovery()

        XCTAssertTrue(host.enteredRecovering.isEmpty)
        XCTAssertTrue(host.reestablishCalls.isEmpty)
        XCTAssertEqual(recovery.phase, .idle)
    }

    func testNotification_postedOffMain_stillRecovers() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)
        let delivered = expectation(description: "recovery started")
        let center = self.center!
        DispatchQueue.global().async {
            center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            DispatchQueue.main.async { delivered.fulfill() }
        }
        await fulfillment(of: [delivered], timeout: 2)
        // The off-main post hops to the main actor; give that hop a turn.
        for _ in 0..<5 where recovery.recoveryTask == nil { await Task.yield() }
        await awaitRecovery()

        XCTAssertEqual(host.reestablishCalls.map(\.bookId), ["reset-book"])
    }

    // MARK: Trigger: -11819 failure

    func testResetFailure_isHandled_andReestablishesWithTheCallersPlayIntent() async {
        let handled = recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure)
        await awaitRecovery()

        XCTAssertTrue(handled, "a -11819 must not reach the terminal error arm")
        XCTAssertEqual(host.enteredRecovering, ["reset-book"])
        XCTAssertEqual(host.reestablishCalls.map(\.bookId), ["reset-book"])
        XCTAssertEqual(host.reestablishCalls.first?.resumePlaying, true)
    }

    func testResetFailure_nestedUnderlying_isHandled() async {
        let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: resetError])
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: wrapped, resumePlaying: false, record: recordFailure))
        await awaitRecovery()
        XCTAssertEqual(host.reestablishCalls.first?.resumePlaying, false)
    }

    func testOtherFailure_whenIdle_isNotHandled() {
        XCTAssertFalse(recovery.handlePlaybackFailure(book: book, error: playerNotReady, resumePlaying: true, record: recordFailure))
        XCTAssertTrue(host.reestablishCalls.isEmpty)
        XCTAssertTrue(host.enteredRecovering.isEmpty)
    }

    // MARK: De-dup: both triggers, either order, one recovery

    func testNotificationThenFailure_recoversExactlyOnce() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)
        host.reestablishResult = nil  // hold the recovery in flight

        postReset()
        let handled = recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: false, record: recordFailure)
        host.release(true)
        await awaitRecovery()

        XCTAssertTrue(handled, "the late -11819 must be swallowed, not shown")
        XCTAssertEqual(host.reestablishCalls.count, 1)
        XCTAssertEqual(host.enteredRecovering.count, 1)
    }

    func testFailureThenNotification_recoversExactlyOnce() async {
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)
        host.reestablishResult = nil

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        postReset()
        host.release(true)
        await awaitRecovery()

        XCTAssertEqual(host.reestablishCalls.count, 1)
        XCTAssertEqual(host.enteredRecovering.count, 1)
    }

    func testFailureThenNotificationAfterRecoveryCompleted_doesNotRecoverAgain() async {
        // The notification can land after the re-open already finished.
        host.loadedSession = MediaServicesResetSession(book: book, resumePlaying: true)

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await awaitRecovery()
        postReset()
        await awaitRecovery()

        XCTAssertEqual(host.reestablishCalls.count, 1)
    }

    // MARK: Swallow: the follow-on storm

    func testFollowOnPlayerNotReady_duringRecovery_isSwallowedWithoutAnotherRecovery() async {
        host.reestablishResult = nil

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        let followOn1 = recovery.handlePlaybackFailure(book: book, error: playerNotReady, resumePlaying: false, record: recordFailure)
        let followOn2 = recovery.handlePlaybackFailure(book: book, error: nil, resumePlaying: false, record: recordFailure)
        host.release(true)
        await awaitRecovery()

        XCTAssertTrue(followOn1, "playerNotReady from the dead player must not surface as an error")
        XCTAssertTrue(followOn2)
        XCTAssertEqual(host.reestablishCalls.count, 1)
        XCTAssertTrue(host.terminalFailures.isEmpty)
    }

    // MARK: Bound: one recovery per episode

    func testRecoveryFailure_failsTerminally_andLaterFailuresPassThrough() async {
        host.reestablishResult = false

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await awaitRecovery()

        XCTAssertEqual(host.terminalFailures, ["reset-book"])
        XCTAssertEqual(recovery.phase, .idle)
        XCTAssertFalse(recovery.handlePlaybackFailure(book: book, error: playerNotReady, resumePlaying: false, record: recordFailure),
                       "after a failed recovery, today's failure handling applies")
    }

    func testResetFailure_afterSuccessfulRecoveryBeforePlaybackBegins_passesThrough() async {
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await awaitRecovery()

        let second = recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure)
        await awaitRecovery()

        XCTAssertFalse(second, "a second -11819 before the new session plays must not loop")
        XCTAssertEqual(host.reestablishCalls.count, 1)
    }

    func testResetFailure_afterRecoveredSessionPlays_startsANewEpisode() async {
        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await awaitRecovery()
        recovery.handlePlaybackBegan(bookId: "reset-book")

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        await awaitRecovery()

        XCTAssertEqual(host.reestablishCalls.count, 2)
    }

    // MARK: Session ended mid-recovery

    func testSessionEnded_duringRecovery_thenRecoveryFails_doesNotFailTerminally() async {
        host.reestablishResult = nil

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        recovery.handleSessionEnded()
        host.release(false)
        await awaitRecovery()

        XCTAssertTrue(host.terminalFailures.isEmpty, "a superseded recovery must not publish an error over the new session")
        XCTAssertEqual(recovery.phase, .idle)
    }

    func testSessionEnded_duringRecovery_laterFailurePassesThrough() async {
        host.reestablishResult = nil

        XCTAssertTrue(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure))
        recovery.handleSessionEnded()

        XCTAssertFalse(recovery.handlePlaybackFailure(book: book, error: playerNotReady, resumePlaying: true, record: recordFailure),
                       "after a fresh open, failures belong to the new session")
    }

    // MARK: Host lifetime

    func testNoHost_resetFailureIsNotSwallowed() {
        recovery.host = nil
        XCTAssertFalse(recovery.handlePlaybackFailure(book: book, error: resetError, resumePlaying: true, record: recordFailure),
                       "with no host to recover through, the failure must reach today's handling")
        XCTAssertEqual(recovery.phase, .idle)
    }
}

// MARK: - Session manager inputs

@MainActor
final class MediaServicesResetSessionInputTests: XCTestCase {

    private let book = TPPBookMocker.mockBook(identifier: "b1", title: "B1", distributorType: .OpenAccessAudiobook)

    func testResumePlaying_whenPlaying_isTrue() {
        XCTAssertTrue(AudiobookSessionManager.mediaServicesResetResumePlaying(
            isPlaying: true, state: .playing(bookId: "b1"), bookId: "b1"))
    }

    func testResumePlaying_whenPaused_isFalse() {
        XCTAssertFalse(AudiobookSessionManager.mediaServicesResetResumePlaying(
            isPlaying: false, state: .paused(bookId: "b1"), bookId: "b1"))
    }

    func testResumePlaying_whileOpeningThisBook_isTrue() {
        // Every production open starts playing, so a reset mid-open keeps that intent.
        XCTAssertTrue(AudiobookSessionManager.mediaServicesResetResumePlaying(
            isPlaying: false, state: .loading(bookId: "b1"), bookId: "b1"))
    }

    func testResumePlaying_whileOpeningAnotherBook_isFalse() {
        XCTAssertFalse(AudiobookSessionManager.mediaServicesResetResumePlaying(
            isPlaying: false, state: .loading(bookId: "other"), bookId: "b1"))
    }

    func testResumePlaying_afterTerminalError_isFalse() {
        XCTAssertFalse(AudiobookSessionManager.mediaServicesResetResumePlaying(
            isPlaying: false, state: .error(bookId: "b1", message: "x"), bookId: "b1"))
    }

    func testLoadedSession_withBoundManager_carriesBookAndIntent() {
        let session = AudiobookSessionManager.mediaServicesResetSession(
            book: book, hasActiveManager: true, isPlaying: true, state: .playing(bookId: "b1"))
        XCTAssertEqual(session?.book.identifier, "b1")
        XCTAssertEqual(session?.resumePlaying, true)
    }

    func testLoadedSession_pausedWithBoundManager_doesNotResume() {
        let session = AudiobookSessionManager.mediaServicesResetSession(
            book: book, hasActiveManager: true, isPlaying: false, state: .paused(bookId: "b1"))
        XCTAssertEqual(session?.resumePlaying, false)
    }

    func testLoadedSession_withoutBoundManager_isNil() {
        // Mid-open (no player yet): the notification leaves the open alone. A
        // player built after the reset is valid; if it fails anyway, the -11819
        // failure path recovers it.
        XCTAssertNil(AudiobookSessionManager.mediaServicesResetSession(
            book: book, hasActiveManager: false, isPlaying: false, state: .loading(bookId: "b1")))
    }

    func testLoadedSession_withNoBook_isNil() {
        XCTAssertNil(AudiobookSessionManager.mediaServicesResetSession(
            book: nil, hasActiveManager: true, isPlaying: true, state: .idle))
    }
}
