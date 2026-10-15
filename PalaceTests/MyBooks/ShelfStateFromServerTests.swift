//
//  ShelfStateFromServerTests.swift
//  PalaceTests
//
//  PP-5360: a sync moves an existing record between Holds and My Books when the
//  server's availability says the title is now a loan or a hold, and returning
//  to the app triggers a throttled shelf sync.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace

final class ShelfStateFromServerTests: XCTestCase {

    private func book(_ availability: TPPOPDSAcquisitionAvailability?) -> TPPBook {
        let acquisitions = availability.map {
            [TPPOPDSAcquisition(relation: .borrow, type: "application/epub+zip",
                                hrefURL: URL(string: "https://example.com/borrow")!,
                                indirectAcquisitions: [], availability: $0)]
        } ?? []
        return TPPBook(
            acquisitions: acquisitions,
            authors: nil, categoryStrings: nil, distributor: nil,
            identifier: "shelf-state", imageURL: nil, imageThumbnailURL: nil,
            published: nil, publisher: nil, subtitle: nil, summary: nil,
            title: "Shelf State", updated: Date(),
            annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
            relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
            contributors: nil, bookDuration: nil, imageCache: MockImageCache()
        )
    }

    private let loan = TPPOPDSAcquisitionAvailabilityLimited(copiesAvailable: 1, copiesTotal: 1, since: nil, until: nil)
    private let openLoan = TPPOPDSAcquisitionAvailabilityUnlimited()
    private let queued = TPPOPDSAcquisitionAvailabilityReserved(holdPosition: 2, copiesTotal: 1, since: nil, until: nil)
    private let readyHold = TPPOPDSAcquisitionAvailabilityReady(since: nil, until: nil)
    private let unavailable = TPPOPDSAcquisitionAvailabilityUnavailable(copiesHeld: 1, copiesTotal: 1)

    func testStateAfterServerUpdate_movesRecordsBetweenHoldsAndMyBooks() {
        let cases: [(name: String, current: TPPBookState, availability: TPPOPDSAcquisitionAvailability?, expected: TPPBookState)] = [
            ("hold that became a loan", .holding, loan, .downloadNeeded),
            ("hold that became an open loan", .holding, openLoan, .downloadNeeded),
            ("hold still queued", .holding, queued, .holding),
            ("hold ready to borrow stays a hold", .holding, readyHold, .holding),
            ("hold with unavailable status is left alone", .holding, unavailable, .holding),
            ("no acquisition keeps the state", .holding, nil, .holding),
            ("undownloaded loan that is now a hold", .downloadNeeded, queued, .holding),
            ("undownloaded loan that is now a ready hold", .downloadNeeded, readyHold, .holding),
            ("undownloaded loan stays a loan", .downloadNeeded, loan, .downloadNeeded),
            ("undownloaded open loan stays a loan", .downloadNeeded, openLoan, .downloadNeeded),
            ("undownloaded loan with unavailable status stays", .downloadNeeded, unavailable, .downloadNeeded),
            ("failed download that is now a ready hold", .downloadFailed, readyHold, .holding),
            ("failed download that is still a loan", .downloadFailed, loan, .downloadFailed),
            ("downloaded loan keeps its content state", .downloadSuccessful, queued, .downloadSuccessful),
            ("download in progress is not interrupted", .downloading, queued, .downloading),
            ("opened book keeps its state", .used, queued, .used),
            ("return in progress keeps its state", .returning, queued, .returning),
            ("SAML sign-in in progress keeps its state", .SAMLStarted, queued, .SAMLStarted),
            ("unsupported title keeps its state", .unsupported, queued, .unsupported),
            ("loan stays a loan", .downloadSuccessful, loan, .downloadSuccessful),
            ("unregistered hold becomes a hold", .unregistered, queued, .holding),
            ("unregistered ready hold becomes a hold", .unregistered, readyHold, .holding),
            ("unregistered loan stays unregistered", .unregistered, loan, .unregistered),
            ("unregistered with unavailable status stays", .unregistered, unavailable, .unregistered),
            ("unregistered with no acquisition stays", .unregistered, nil, .unregistered),
        ]
        for c in cases {
            XCTAssertEqual(TPPBookRegistryRecord.stateAfterServerUpdate(current: c.current, book: book(c.availability)),
                           c.expected, c.name)
        }
    }

    /// The merge writes past the setState transition check, so every move it can
    /// make must be one the state machine allows.
    func testStateAfterServerUpdate_onlyMakesAllowedTransitions() {
        let availabilities: [TPPOPDSAcquisitionAvailability?] = [loan, openLoan, queued, readyHold, unavailable, nil]
        for state in TPPBookState.allCases {
            for availability in availabilities {
                let next = TPPBookRegistryRecord.stateAfterServerUpdate(current: state, book: book(availability))
                XCTAssertTrue(next == state || TPPBookState.canTransition(from: state, to: next),
                              "\(state) -> \(next) is not an allowed transition")
            }
        }
    }
}

/// Returning to the app syncs the shelf, at most once per interval, sharing the
/// timestamp the push-notification sync uses.
@MainActor
final class ForegroundShelfSyncTests: XCTestCase {

    private final class InMemoryTimestampStore: ShelfSyncTimestampStore {
        var lastSyncStarted: TimeInterval = 0
    }

    private var syncs = 0
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var store = InMemoryTimestampStore()

    /// Reset the counters, clock and store so no test sees another's state.
    override func tearDown() {
        syncs = 0
        now = Date(timeIntervalSince1970: 1_000_000)
        store = InMemoryTimestampStore()
        super.tearDown()
    }

    private func makeSUT() -> ForegroundShelfSync {
        ForegroundShelfSync(minimumInterval: 30, store: store,
                            now: { [unowned self] in self.now },
                            sync: { [unowned self] in self.syncs += 1 })
    }

    func testFirstForeground_syncs_andRecordsWhenItStarted() {
        makeSUT().appWillEnterForeground()
        XCTAssertEqual(syncs, 1)
        XCTAssertEqual(store.lastSyncStarted, now.timeIntervalSince1970)
    }

    /// The window runs from the last sync that ran: a skipped foreground does
    /// not push it back.
    func testWindow_isMeasuredFromTheLastSyncThatRan() {
        let sut = makeSUT()
        sut.appWillEnterForeground()          // t=0  sync
        now.addTimeInterval(20)
        sut.appWillEnterForeground()          // t=20 skip
        now.addTimeInterval(20)
        sut.appWillEnterForeground()          // t=40 sync
        XCTAssertEqual(syncs, 2)
    }

    func testForegroundRightAtTheInterval_skips() {
        let sut = makeSUT()
        sut.appWillEnterForeground()
        now.addTimeInterval(30)
        sut.appWillEnterForeground()
        XCTAssertEqual(syncs, 1)
    }

    /// A push-triggered sync writes the same timestamp, so a foreground just
    /// after it does not sync again.
    func testRecentPushSync_suppressesTheForegroundSync() {
        store.lastSyncStarted = now.timeIntervalSince1970 - 10
        makeSUT().appWillEnterForeground()
        XCTAssertEqual(syncs, 0)
    }

    func testProductionStore_usesTheKeyThePushSyncReads() {
        let suite = "test.ForegroundShelfSync.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        UserDefaultsShelfSyncTimestampStore(defaults: defaults).lastSyncStarted = 123
        XCTAssertEqual(defaults.double(forKey: "lastForegroundSyncTimestamp"), 123)
    }

    /// The test host is a full app launch; its own foreground must not run a
    /// real registry sync or write the shared timestamp under every test.
    func testSceneDelegate_underXCTest_hasNoDefaultForegroundSync() {
        XCTAssertNil(SceneDelegate().foregroundShelfSync)
    }

    func testSceneWillEnterForeground_drivesTheShelfSync() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first)
        let sceneDelegate = SceneDelegate()
        sceneDelegate.foregroundShelfSync = makeSUT()
        sceneDelegate.sceneWillEnterForeground(scene)
        XCTAssertEqual(syncs, 1)
    }

    private final class FailingSyncRegistry: TPPBookRegistryMock, @unchecked Sendable {
        override func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?) {
            completion?(["title": "offline"], false)
        }
    }

    func testRegistrySync_afterASuccessfulSync_updatesTheBadge() {
        var badgeUpdates = 0
        ForegroundShelfSync.registrySync(registry: { TPPBookRegistryMock() },
                                         updateBadge: { _ in badgeUpdates += 1 })()
        XCTAssertEqual(badgeUpdates, 1)
    }

    func testRegistrySync_afterAFailedSync_leavesTheBadge() {
        var badgeUpdates = 0
        ForegroundShelfSync.registrySync(registry: { FailingSyncRegistry() },
                                         updateBadge: { _ in badgeUpdates += 1 })()
        XCTAssertEqual(badgeUpdates, 0)
    }
}
