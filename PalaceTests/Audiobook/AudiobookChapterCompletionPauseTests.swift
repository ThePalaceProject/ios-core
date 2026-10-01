//
//  AudiobookChapterCompletionPauseTests.swift
//
//  PP-4951 (app side): `.playbackCompleted` means a chapter ended, not that
//  playback stopped. Findaway emits it at every boundary, sometimes seconds late
//  (after the next `.playbackBegan`), which left the session showing paused while
//  audio played. Pinned: the mapping from a real `AudiobookManagerState` to its
//  play-state, so passing the wrong signal at the call site fails. Not pinned:
//  `handleManagerState` itself (reaching it needs the auth-gated open flow); that
//  gap is noted at the arm.

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
