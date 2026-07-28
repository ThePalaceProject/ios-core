//
//  AudiobookSessionPresenterLifecycleContractTests.swift
//  PalaceTests
//
//  PRE-WAVE decomposition pin pack for
//  `Palace/Audiobooks/AudiobookSessionManager.swift` (2,761 LOC — the biggest
//  file in the app). Target of the god-class decomposition campaign, Wave 6
//  (see docs/architecture/god-class-decomposition-plan.md §3a-1 + §5 row
//  "AudiobookSessionManager").
//
//  WHY THIS FILE EXISTS (and why it is NOT a duplicate of the existing suite):
//
//  The existing audiobook tests
//  (`AudiobookSessionManagerPresenterMigrationTests`,
//  `AudiobookFirstOpenHangTests`, `AudiobookPositionRestoreTests`, …) are
//  thorough, but they assert on call COUNTS and final published STATE
//  (`adoptBookCallCount == 1`, `presenter.currentBook == B`,
//  `adoptedBookIdentifiersInOrder == [A, B]`). None of them locks the
//  *relative ORDER of the calls within a single open* as a byte-equal JSON
//  snapshot.
//
//  That gap is exactly the regression class `ContractSnapshot.swift` was
//  built to catch (see its header): 3.1.0's Phase-7 extraction of
//  MyBooksDownloadCenter leaked FOUR silent call-SEQUENCE regressions
//  (F-011/F-014/F-016/F-017) that the per-case count/unit tests were blind to.
//  AudiobookSessionManager is the NEXT god-class extraction, and §5's general
//  contract is explicit: "no extraction PR merges unless the target's pre-wave
//  test pack existed BEFORE the move and passes identically AFTER it —
//  'identically' means byte-equal JSON under __Snapshots__/."
//
//  WHAT THIS PINS — the reachable subset of §5's "session-state contract
//  (spy … recording bind/play/teardown call ORDER)":
//
//  The `bind → present` and `teardown → dismiss` sequencing that the Wave-6
//  Shell keeps (per §3a-1, toolkit binding glue stays in the Shell; the
//  orchestration decision logic moves to `AudiobookOpenReducer`). These
//  snapshots drift loudly if the extraction reorders the presenter-facing
//  calls — e.g. moving `presentOnFirstOpen()` (which renders the mini-player
//  chrome off `presenter.currentBook`) BEFORE `adoptBook(_:)` would render a
//  nil-book / blank first frame. That reorder passes EVERY existing count
//  assertion (both calls still fire exactly once) and drifts ONLY this
//  snapshot.
//
//  SEAM — the toolkit-manager half of §5's ask is NOT reachable without DRM /
//  the toolkit graph:
//    The true bind/play/teardown ORDER into the toolkit `AudiobookManager`
//    (`manager.saveLocation` → `manager.pause` → `manager.unload` in
//    `stopPlayback`, and `manager.statePublisher`/`positionPublisher`
//    subscription order in `bind`) CANNOT be contract-snapshotted from a unit
//    test. Although `PalaceAudiobookToolkit.AudiobookManager` is a `public
//    protocol` (a spy could conform), there is NO injection seam to bind a
//    spy: `bind(loaded:for:startPlaying:)` is `private`, the `manager`
//    property is `private(set)`, and `bind` takes a `LoadedAudiobook` whose
//    `audiobook: Audiobook` + `playbackModel: AudiobookPlaybackModel` are
//    concrete toolkit classes over a full Manifest graph that is impractical
//    to construct from XCTest (documented in
//    `AudiobookPositionAdapterContractTests` and `PresenterMigrationTests`).
//    // SEAM: to contract-snapshot the toolkit-manager teardown order, the
//    // Wave-6 extraction must expose a bindable seam — e.g. an injectable
//    // `manager` (protocol-typed `AudiobookManaging`) or an internal
//    // `bind(loaded:)` overload accepting a spy `AudiobookManager` + a
//    // test-constructable `LoadedAudiobook`. Until then that ordering stays
//    // sim-verified (simdrive), as does LCP first-open reliable-start (DRM).
//
//  ASSERTION FORM: inline `CallLog` method-order equality
//  (`XCTAssertEqual(log.snapshot().map(\.method), [...])`), NOT the file-based
//  `ContractSnapshot.assert`. The expected sequence is stated explicitly in each
//  test — derived from AND verified against the production call order in
//  `AudiobookSessionManager.pushSessionToPresenter` / `dismissPlayerOnPhone` —
//  so the pack is GREEN on its first CI run (no external `__Snapshots__/`
//  baseline to record, no records-then-fails first pass). Wave 6 must keep the
//  stated sequence identical; a reorder drifts the array and fails loudly.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import UIKit
import XCTest
import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel

// MARK: - Recording presenter (subclasses the concrete presenter, records order)

/// Subclass of the concrete `AudiobookSessionPresenter` that records every
/// action call — in order, with argument shape — into a shared `CallLog`,
/// then forwards to `super` so the published mirrors (`currentBook`,
/// `isPlayerExpanded`) still flip. Mirrors the `RecordingRegistry` decorator
/// pattern from `AudiobookPositionAdapterContractTests`.
///
/// We subclass (not compose) because the manager consumes the concrete
/// `AudiobookSessionPresenter` type via its `audiobookSessionPresenterProvider`
/// closure — there is no presenter protocol to conform to (the same reason
/// `SpyAudiobookSessionPresenter` subclasses it). `SpyShimSession` from the
/// shared mocks satisfies the presenter's `init(sessionManager:)` requirement
/// without a real session graph.
@MainActor
private final class RecordingSessionPresenter: AudiobookSessionPresenter {
    let log: CallLog
    private let shim: SpyShimSession

    init(log: CallLog) {
        self.log = log
        let shim = SpyShimSession()
        self.shim = shim
        super.init(sessionManager: shim)
    }

    override func adoptBook(_ book: TPPBook) {
        log.record("presenter.adoptBook", args: ["bookID": book.identifier])
        super.adoptBook(book)
    }

    override func adoptPlaybackModel(_ model: AudiobookPlaybackModel) {
        // Not exercised here (production passes a real model; tests pass nil
        // because the toolkit graph can't be built from XCTest — see SEAM in
        // the file header). Recorded for completeness if a future seam allows it.
        log.record("presenter.adoptPlaybackModel")
        super.adoptPlaybackModel(model)
    }

    override func presentOnFirstOpen() {
        log.record("presenter.presentOnFirstOpen")
        super.presentOnFirstOpen()
    }

    override func clearActiveSession() {
        log.record("presenter.clearActiveSession")
        super.clearActiveSession()
    }

    override func adoptCoverImage(_ image: UIImage?) {
        log.record("presenter.adoptCoverImage", args: ["hasImage": image != nil])
        super.adoptCoverImage(image)
    }
}

// MARK: - Tests

@MainActor
final class AudiobookSessionPresenterLifecycleContractTests: XCTestCase {

    private var log: CallLog!
    private var presenter: RecordingSessionPresenter!
    private var appContainer: AppContainer!
    private var sut: AudiobookSessionManager!

    override func setUp() async throws {
        try await super.setUp()
        log = CallLog()
        presenter = RecordingSessionPresenter(log: log)
        appContainer = makeTestAppContainer()
        // Flag ON: the presenter owns the player chrome, so the presenter-facing
        // calls (adopt/present/clear) are the ones that fire. Flag-OFF routes
        // through the legacy NavigationCoordinator and is covered elsewhere
        // (`AudiobookSessionManagerFlagGatePresentationTests`).
        sut = AudiobookSessionManager(
            appContainer: appContainer,
            audiobookSessionPresenterProvider: { [unowned self] in self.presenter },
            inAppPlaybackNavEnabledProvider: { true }
        )
    }

    override func tearDown() async throws {
        await sut?.stopPlayback(dismissPhoneUI: false)
        sut = nil
        appContainer = nil
        presenter = nil
        log = nil
        try await super.tearDown()
    }

    // MARK: - 1. First-open present ORDER: adoptBook BEFORE presentOnFirstOpen

    /// Drives the migrated production seam `pushSessionToPresenter(book:
    /// playbackModel:)` — the call `bind()` makes via
    /// `presentCoverArtAndNavigation` — and locks the ORDER:
    ///   1. `presenter.adoptBook(book)`
    ///   2. `presenter.presentOnFirstOpen()`
    ///
    /// (playbackModel is nil here — the toolkit-graph SEAM in the header — so
    /// the intermediate `adoptPlaybackModel` is absent from the snapshot; the
    /// order of the two REACHABLE calls is what the extraction must preserve.)
    ///
    /// Regression this catches that the count-based
    /// `PresenterMigrationTests.testOpenAudiobook_firstOpen_callsPresenter…`
    /// does NOT: a refactor that emits `presentOnFirstOpen()` before
    /// `adoptBook(_:)` keeps BOTH counts at 1 (that test still passes) but the
    /// mini-player chrome renders off a still-nil `presenter.currentBook` — a
    /// blank/stale first frame. Only this byte-equal snapshot drifts.
    func test_firstOpenPresentSequence() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        sut.pushSessionToPresenter(book: book, playbackModel: nil)

        XCTAssertEqual(
            log.snapshot().map(\.method),
            ["presenter.adoptBook", "presenter.presentOnFirstOpen"],
            "First-open must adoptBook BEFORE presentOnFirstOpen (playbackModel nil → no adoptPlaybackModel)."
        )
    }

    // MARK: - 2. Open → dismiss lifecycle ORDER (flag-ON teardown)

    /// Locks the reachable open→teardown presenter sequence end to end:
    ///   1. `presenter.adoptBook(book)`
    ///   2. `presenter.presentOnFirstOpen()`
    ///   3. `presenter.clearActiveSession()`   ← from `dismissPlayerOnPhone`
    ///
    /// `dismissPlayerOnPhone(bookId:)` is the seam `stopPlayback(dismissPhoneUI:
    /// true)` calls; on the flag-ON path it clears the presenter (it does NOT
    /// touch the legacy coordinator — PP-3783 back-stack preservation). Pinning
    /// the full sequence guards against an extraction that drops the teardown
    /// clear (the "✕ did nothing" regression PR #1230 fixed) OR inserts a stray
    /// clear before present — both invisible to the existing count assertions
    /// when taken in isolation.
    func test_openThenDismissSequence() {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        sut.pushSessionToPresenter(book: book, playbackModel: nil)
        sut.dismissPlayerOnPhone(bookId: book.identifier)

        XCTAssertEqual(
            log.snapshot().map(\.method),
            ["presenter.adoptBook", "presenter.presentOnFirstOpen", "presenter.clearActiveSession"],
            "Open→dismiss must end with clearActiveSession (guards the '✕ did nothing' regression PR #1230)."
        )
    }

    // MARK: - 3. Switch A→B ORDER: replace-not-stack (PP-3783)

    /// Two consecutive opens (A then B) lock the interleaved sequence:
    ///   1. adoptBook(A) 2. presentOnFirstOpen 3. adoptBook(B) 4. presentOnFirstOpen
    ///
    /// The existing `testOpenAudiobook_switchingAudiobooks…` asserts the FIFO
    /// `adoptedBookIdentifiersInOrder == [A, B]` and final `currentBook == B`,
    /// but not that each open's `adoptBook` precedes its own `presentOnFirstOpen`.
    /// This snapshot locks the full interleave so a reordering within either
    /// open (present-before-adopt on the SECOND open only, say) drifts here.
    func test_switchBooksSequence() {
        let bookA = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        let bookB = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)

        sut.pushSessionToPresenter(book: bookA, playbackModel: nil)
        sut.pushSessionToPresenter(book: bookB, playbackModel: nil)

        XCTAssertEqual(
            log.snapshot().map(\.method),
            ["presenter.adoptBook", "presenter.presentOnFirstOpen", "presenter.adoptBook", "presenter.presentOnFirstOpen"],
            "A→B switch must interleave adopt-before-present within each open (PP-3783 replace-not-stack)."
        )
    }
}
