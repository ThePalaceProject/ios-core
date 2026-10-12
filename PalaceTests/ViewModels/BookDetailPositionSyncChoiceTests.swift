//
//  BookDetailPositionSyncChoiceTests.swift
//  PalaceTests
//
//  Covers `BookDetailViewModel.chooseLocalLocation`, which decides whether a
//  resumed audiobook starts from the on-device position or the server's. The
//  branches here are the ones that answer without presenting the move/stay
//  alert; the two prompting branches are recorded at the bottom of this file.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
import PalacePreferences
@testable import Palace
// `Tracks.init` is internal to the toolkit, so the fixture needs @testable.
@testable import PalaceAudiobookToolkit

@MainActor
final class BookDetailPositionSyncChoiceTests: XCTestCase {

    private var appContainer: AppContainer!
    private var tracks: Tracks!

    override func setUpWithError() throws {
        try super.setUpWithError()
        appContainer = makeTestAppContainer()
        let manifest = try Manifest.from(jsonFileName: ManifestJSON.snowcrash.rawValue,
                                         bundle: Bundle(for: type(of: self)))
        tracks = Tracks(manifest: manifest, audiobookID: "BookDetailPositionSyncChoiceTests", token: nil)
    }

    override func tearDown() {
        tracks = nil
        appContainer = nil
        super.tearDown()
    }

    private func makeViewModel() -> BookDetailViewModel {
        BookDetailViewModel(
            book: TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook),
            registry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { _ in nil }
        )
    }

    /// Distinct positions so `remotePosition.description != localPosition?.description`
    /// can differ; `timestamp` is what makes the descriptions differ.
    private func position(timestamp: Double, savedAt: String) throws -> TrackPosition {
        let track = try XCTUnwrap(tracks.first, "snowcrash fixture must yield at least one track")
        var p = TrackPosition(track: track, timestamp: timestamp, tracks: tracks)
        p.lastSavedTimeStamp = savedAt
        return p
    }

    // MARK: - Branches that answer without the alert

    /// Nothing saved anywhere: the operation must not run at all, or playback
    /// would start from a position the caller never supplied.
    func test_chooseLocalLocation_bothNil_doesNotInvokeOperation() {
        var chosen: [TrackPosition] = []

        makeViewModel().chooseLocalLocation(localPosition: nil,
                                            remotePosition: nil,
                                            serverUpdateDelay: 0) { chosen.append($0) }

        XCTAssertTrue(chosen.isEmpty, "With no local and no remote position there is nothing to resume from")
    }

    /// Only the device has a position. The server has nothing to offer, so the
    /// local one is used with no prompt.
    func test_chooseLocalLocation_localOnly_usesLocalWithoutPrompting() throws {
        let local = try position(timestamp: 30, savedAt: "2026-03-30T12:00:00Z")
        var chosen: [TrackPosition] = []

        makeViewModel().chooseLocalLocation(localPosition: local,
                                            remotePosition: nil,
                                            serverUpdateDelay: 0) { chosen.append($0) }

        XCTAssertEqual(chosen.count, 1, "The local position is answerable immediately")
        XCTAssertEqual(chosen.first?.timestamp, 30)
    }

    /// Both exist and the LOCAL one is newer. The server's position is stale,
    /// so it is used without asking the patron — asking here is the regression
    /// this pins, because an unnecessary prompt interrupts every open.
    func test_chooseLocalLocation_localNewerThanRemote_usesLocalWithoutPrompting() throws {
        let local = try position(timestamp: 90, savedAt: "2026-03-30T12:00:00Z")
        let remote = try position(timestamp: 15, savedAt: "2026-03-30T09:00:00Z")
        var chosen: [TrackPosition] = []

        makeViewModel().chooseLocalLocation(localPosition: local,
                                            remotePosition: remote,
                                            serverUpdateDelay: 0) { chosen.append($0) }

        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(chosen.first?.timestamp, 90, "The newer local position wins over a stale remote one")
    }

    /// `serverUpdateDelay` is added to the REMOTE timestamp
    /// (`String.isDate` computes `remote + delay > local`), so it is a tolerance
    /// in the server's favour: a remote position slightly older than the local
    /// one still counts as newer. This pins the far side of that tolerance —
    /// once the remote is older by more than the delay, the local position wins
    /// outright and no prompt is raised.
    func test_chooseLocalLocation_remoteOlderThanServerDelayAllows_usesLocal() throws {
        let local = try position(timestamp: 42, savedAt: "2026-03-30T12:00:00Z")
        let remote = try position(timestamp: 7, savedAt: "2026-03-30T11:00:00Z")
        var chosen: [TrackPosition] = []

        makeViewModel().chooseLocalLocation(localPosition: local,
                                            remotePosition: remote,
                                            serverUpdateDelay: 60) { chosen.append($0) }

        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(chosen.first?.timestamp, 42,
                       "An hour-old remote position is not rescued by a 60-second tolerance")
    }

    /// Identical positions: the guard compares descriptions before prompting,
    /// so a remote position equal to the local one must not raise the alert.
    func test_chooseLocalLocation_remoteIdenticalToLocal_usesLocalWithoutPrompting() throws {
        let local = try position(timestamp: 55, savedAt: "2026-03-30T12:00:00Z")
        var remote = local
        remote.lastSavedTimeStamp = "2026-03-30T18:00:00Z"
        var chosen: [TrackPosition] = []

        makeViewModel().chooseLocalLocation(localPosition: local,
                                            remotePosition: remote,
                                            serverUpdateDelay: 0) { chosen.append($0) }

        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(chosen.first?.timestamp, 55,
                       "Same position means nothing to choose between, however new the remote timestamp is")
    }

    // Not covered here: the two branches that call `requestSyncWithCompletion`
    // — local nil with a remote position, and both present with a strictly
    // newer remote. Both present a `UIAlertController` through
    // `TPPAlertUtils.presentFromViewControllerOrNil`, so reaching them needs a
    // prompt seam on the view model that does not exist yet. Covering them by
    // restating the condition in the test, rather than driving the method, is
    // what the deleted `BookAvailabilityFormatterTests` did.
}
