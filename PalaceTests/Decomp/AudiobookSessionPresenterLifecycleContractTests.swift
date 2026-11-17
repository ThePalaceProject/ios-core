//
//  AudiobookSessionPresenterLifecycleContractTests.swift
//  PalaceTests
//
//  Pins the presenter-facing call ORDER within a single audiobook open
//  (`bind → present`, `teardown → dismiss`) in `AudiobookSessionManager`.
//  Existing suites assert call counts and final state; a reorder such as
//  `presentOnFirstOpen()` before `adoptBook(_:)` (a blank first frame) passes
//  them and fails only here. See docs/architecture/god-class-decomposition-plan.md.
//  The toolkit `AudiobookManager` teardown order is not reachable: `bind` is
//  private and `LoadedAudiobook` needs a full toolkit graph, so it stays sim-verified.
//  Expected sequences are stated inline (CallLog method-order equality).
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
