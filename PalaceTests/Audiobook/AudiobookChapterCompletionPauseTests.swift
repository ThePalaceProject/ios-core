//
//  AudiobookChapterCompletionPauseTests.swift
//  PalaceTests
//
//  PP-4951, piece 3 (app side): a chapter ending is not a pause.
//
//  `AudiobookSessionManager.handleManagerState` treated the toolkit's
//  `.playbackCompleted` signal as "playback stopped" — it set `isPlaying =
//  false` and moved the session to `.paused`. That signal does not mean the
//  patron stopped listening; it means one chapter ended and the next is
//  starting. Nothing on that path calls `player.pause()` and the audio keeps
//  playing straight through.
//
//  On Findaway (every DRM audiobook) the signal fires at EVERY chapter
//  boundary and always has, so the app has been flipping itself to `.paused`
//  once per chapter for the whole of every DRM title. It is normally invisible
//  because the next chapter's `.playbackBegan` arrives immediately after and
//  puts the state back — but the toolkit documents `FAEPlaybackChapterComplete`
//  as sometimes arriving several seconds late, and if it lands AFTER the next
//  chapter's `.playbackBegan` the app is left showing paused while audio plays
//  on. Unlike the toolkit's `AudiobookPlaybackModel`, which re-syncs from a
//  0.5s `isPlaying` poll, the session manager has no poll to rescue it.
//
//  END OF BOOK still parks the UI, but by a route that differs per player, and
//  the DRM one is the exception — worth stating because "every player pauses at
//  end of book" is nearly true and wrong:
//    * `OpenAccessPlayer` / `LCPStreamingPlayer` send `.bookCompleted` then
//      `.stopped(beginningPosition)` from `handlePlaybackEnd`.
//    * `FindawayPlayer.audioEngineAudiobookCompleted` sends `.bookCompleted`
//      then `.started(beginningPosition)`, and the stop follows indirectly via
//      `shouldPauseWhenPlaybackResumes` → `performPause`. The direct `pause()`
//      in `FindawayPlayer` is the track-exhaustion path, NOT the path a
//      completed Findaway book takes.
//  Residual, named rather than papered over: `performPause` emits `.stopped`
//  only when `currentTrackPosition != nil` AND `isPlaying`, and the Findaway
//  SDK's `isPlaying` is documented as transiently false in the post-seek buffer
//  window. So "a stop always arrives" is unconditional in prose and conditional
//  in code. It is not made worse by this change — the old `.completed` pause was
//  itself overwritten by the `.started` that follows it, so it never protected
//  this case either.
//
//  WHAT THESE TESTS PIN, AND WHAT THEY DO NOT. They drive the mapping from a
//  real `AudiobookManagerState` to the play-state it implies. An earlier
//  revision asserted only against the bare signal enum, which left the arm free
//  to pass the wrong signal — swapping `.chapterCompleted` for `.stopped` at the
//  call site reintroduced the defect with every test green. Keying the mapping
//  on the manager state closes that.
//
//  Still NOT pinned: `handleManagerState` itself has no test caller anywhere in
//  PalaceTests, because `currentBook` is `private(set)` and written only on the
//  open path, so reaching the arm needs the whole auth-gated open flow. Someone
//  could still re-add `isPlaying = false` directly inside the `.playbackCompleted`
//  arm, or restore its deleted `playbackStatePublisher.send`, and these tests
//  would stay green. That gap is recorded at the arm itself rather than closed
//  with a test-only setter, which would be a production seam opened for a test.
//

import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class AudiobookChapterCompletionPauseTests: XCTestCase {

    private let bookId = "test-book-id"
    private var tracks: Tracks!

    override func setUp() {
        super.setUp()
        let manifest = try! Manifest.from(
            jsonFileName: ManifestJSON.snowcrash.rawValue,
            bundle: Bundle(for: type(of: self))
        )
        tracks = Tracks(manifest: manifest, audiobookID: "PP4951", token: nil)
    }

    override func tearDown() {
        tracks = nil
        super.tearDown()
    }

    private func position(_ timestamp: Double = 0.0) -> TrackPosition {
        TrackPosition(track: tracks.tracks[0], timestamp: timestamp, tracks: tracks)
    }

    private func playState(
        _ managerState: AudiobookManagerState
    ) -> (isPlaying: Bool, state: AudiobookSessionState)? {
        AudiobookPlaybackLifecycleSignal.playState(for: managerState, bookId: bookId)
    }

    // MARK: - The cell this ticket is about

    func testChapterCompleted_leavesPlayStateAlone() {
        XCTAssertNil(
            playState(.playbackCompleted(position(120.0))),
            "A chapter ending must leave play state alone. Audio continues into the next chapter — nothing pauses it — so reporting `paused` is false, and with a late Findaway notification it is false PERMANENTLY because the session manager has no poll to re-sync from."
        )
    }

    // MARK: - The cells that must NOT move

    func testPlaybackBegan_reportsPlayingAndPairsWithTheMatchingState() {
        let applied = playState(.playbackBegan(position(5.0)))
        XCTAssertEqual(applied?.isPlaying, true, "Playback beginning is the one signal that turns the player UI on.")
        XCTAssertEqual(
            applied?.state, .playing(bookId: bookId),
            "`isPlaying` and `state` are returned together so they can never disagree — true beside `.paused` must be unrepresentable."
        )
    }

    func testPlaybackStopped_reportsPausedAndPairsWithTheMatchingState() {
        let applied = playState(.playbackStopped(position(90.0)))
        XCTAssertEqual(applied?.isPlaying, false, "A real stop — the patron pausing, an interruption, or the pause that follows the end of a book — is what parks the UI.")
        XCTAssertEqual(
            applied?.state, .paused(bookId: bookId),
            "The paused arm must pair `false` with `.paused`; swapping the ternary arms would let the flag and the state disagree on every transition."
        )
    }

    // MARK: - States that are deliberately NOT in the table

    func testPlaybackFailed_isNotTableManaged() {
        XCTAssertNil(
            playState(.playbackFailed(position(10.0), nil)),
            "`.playbackFailed` sets `isPlaying` itself, inside branching recovery that chooses between `.loading`, `.error` and a silent re-open. Folding it into a two-value table would misrepresent it, so it must opt out rather than be absorbed."
        )
    }

    func testNonPlaybackStates_areNotTableManaged() {
        // The table speaks for three of the manager's states. Everything else
        // must decline rather than fall through to a default that pauses.
        let untabled: [AudiobookManagerState] = [
            .positionUpdated(position(3.0)),
            .positionUpdated(nil),
            .playbackUnloaded,
            .refreshRequested,
            .bookmarkSaved(position(4.0), nil),
            .bookmarksFetched([]),
            .bookmarkDeleted(true),
            .locationPosted(nil),
            .overallDownloadProgress(0.5),
            .error(nil, nil),
        ]
        for managerState in untabled {
            XCTAssertNil(
                playState(managerState),
                "\(managerState) must not move play state — only playback lifecycle transitions may."
            )
        }
    }

    // MARK: - The table is total over what it claims

    func testExactlyOneManagerStatePauses() {
        // Enumerating rather than spot-checking: a state added later without a
        // decision here would otherwise silently inherit a neighbour's answer.
        //
        // Scoped honestly to the states this table owns. It is NOT true that
        // `.playbackStopped` is the only thing in the app that can pause — the
        // `.playbackFailed` arm sets `isPlaying = false` on its own, and the
        // open/close paths write play state directly. Asserting otherwise would
        // be a claim about the whole session manager that this table cannot make.
        let tabled: [AudiobookManagerState] = [
            .playbackBegan(position(1.0)),
            .playbackStopped(position(2.0)),
            .playbackCompleted(position(3.0)),
        ]
        let pausing = tabled.filter { playState($0)?.isPlaying == false }

        XCTAssertEqual(pausing.count, 1, "Exactly one of the three tabled states may pause.")
        guard case .playbackStopped = pausing.first else {
            return XCTFail("`.playbackStopped` must be the only tabled state that pauses; `.playbackCompleted` pausing is the PP-4951 defect.")
        }
    }

    func testEverySignalHasAProducingManagerState() {
        // Totality from the other end, and the reason the enum is `CaseIterable`.
        // The test above enumerates manager states; this one enumerates SIGNALS
        // and demands each be reachable. Adding a fourth signal that no state
        // produces — a case written for a transition that was never wired up —
        // fails here rather than sitting inert and looking covered.
        let produced = Set(
            [
                AudiobookManagerState.playbackBegan(position(1.0)),
                .playbackStopped(position(2.0)),
                .playbackCompleted(position(3.0)),
            ].compactMap { AudiobookPlaybackLifecycleSignal.signal(for: $0) }
        )

        XCTAssertEqual(
            produced, Set(AudiobookPlaybackLifecycleSignal.allCases),
            "Every lifecycle signal must be produced by some manager state. A signal no state maps to is dead code that reads as covered — and one this test cannot see is a state whose decision nothing pins."
        )
    }
}
