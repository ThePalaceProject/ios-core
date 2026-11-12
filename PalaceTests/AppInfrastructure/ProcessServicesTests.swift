//
//  ProcessServicesTests.swift
//  PalaceTests
//
//  Each separately built container owns one set of process-lifetime services,
//  wired to its own graph; copies of a container share it (PP-5545).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceBookRegistry
@testable import Palace

@MainActor
final class ProcessServicesTests: XCTestCase {

    private var containerA: AppContainer!
    private var containerB: AppContainer!

    override func setUp() {
        super.setUp()
        containerA = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        containerB = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
    }

    override func tearDown() {
        containerA = nil
        containerB = nil
        super.tearDown()
    }

    // MARK: - Audiobook services

    /// B's session reads B's registry, so a book B opens is looked up in B's graph.
    func testAudiobookSession_IsPerContainerAndReadsItsOwnRegistry() {
        let sessionA = containerA.audiobookSession as AnyObject
        let sessionB = containerB.audiobookSession

        XCTAssertFalse(sessionA === (sessionB as AnyObject), "Two containers must not share one audiobook session")
        let concrete = try? XCTUnwrap(sessionB as? AudiobookSessionManager)
        XCTAssertTrue((concrete?.bookRegistry as AnyObject) === (containerB.bookRegistry as AnyObject),
                      "B's session must read B's book registry")
        XCTAssertTrue((containerB.audiobookSession as AnyObject) === (sessionB as AnyObject),
                      "One container must keep handing back the same session")
    }

    /// B's presenter shows B's session, which is the one CarPlay and book open drive.
    func testAudiobookSessionPresenter_IsPerContainerAndWrapsItsOwnSession() {
        let presenterA = containerA.audiobookSessionPresenter
        let presenterB = containerB.audiobookSessionPresenter

        XCTAssertFalse(presenterA === presenterB, "Two containers must not share one session presenter")
        let wrapped: AudiobookSessionManaging? = reflected("sessionManager", of: presenterB)
        XCTAssertTrue((wrapped as AnyObject) === (containerB.audiobookSession as AnyObject),
                      "B's presenter must wrap B's session")
    }

    /// Initializing B's bootstrapper builds B's session and leaves A without one.
    func testPlaybackBootstrapper_IsPerContainerAndInitializesItsOwnSession() {
        let bootstrapperA = containerA.playbackBootstrapper
        let bootstrapperB = containerB.playbackBootstrapper
        XCTAssertNil(containerB.processServices.audiobookSession, "Setup: B must start without a session")

        bootstrapperB.ensureInitialized()

        XCTAssertFalse(bootstrapperA === bootstrapperB, "Two containers must not share one playback bootstrapper")
        XCTAssertNotNil(containerB.processServices.audiobookSession,
                        "Initializing B's bootstrapper must build B's session")
        XCTAssertNil(containerA.processServices.audiobookSession,
                     "Initializing B's bootstrapper must not build a session in A")
    }

    /// B's play-time uploader sends through B's executor.
    func testPlaytimeUploader_IsPerContainerAndSendsThroughItsOwnExecutor() {
        let uploaderA = containerA.playtimeUploader
        let uploaderB = containerB.playtimeUploader

        XCTAssertFalse(uploaderA === uploaderB, "Two containers must not share one play-time uploader")
        let executor: TPPNetworkExecutor? = reflected("networkService", of: uploaderB)
        XCTAssertTrue(executor === containerB.networkExecutor, "B's uploader must send through B's executor")
    }

    // MARK: - Policy, samples, rating

    func testActivityPolicy_IsPerContainerAndStableWithinOne() {
        XCTAssertFalse(containerA.activityPolicy === containerB.activityPolicy,
                       "Two containers must not share one activity policy")
        XCTAssertTrue(containerB.activityPolicy === containerB.activityPolicy,
                      "One container must keep handing back the same activity policy")
    }

    /// B's sample player follows B's activity policy.
    func testSamplePreviewManager_IsPerContainerAndUsesItsOwnPolicy() {
        let managerA = containerA.samplePreviewManager
        let managerB = containerB.samplePreviewManager

        XCTAssertFalse(managerA === managerB, "Two containers must not share one sample preview manager")
        let policy: ActivityPolicy? = reflected("activityPolicy", of: managerB)
        XCTAssertTrue(policy === containerB.activityPolicy, "B's sample manager must use B's activity policy")
    }

    /// A session recorded through B is counted in B's settings only.
    func testAppRatingService_RecordsSessionsInItsOwnContainersSettings() {
        let countA = containerA.settings.appRatingSessionCount
        let countB = containerB.settings.appRatingSessionCount

        containerB.appRatingService.recordSession()

        XCTAssertFalse(containerA.appRatingService === containerB.appRatingService,
                       "Two containers must not share one rating service")
        XCTAssertEqual(containerB.settings.appRatingSessionCount, countB + 1,
                       "B's rating service must count the session in B's settings")
        XCTAssertEqual(containerA.settings.appRatingSessionCount, countA,
                       "A's settings must not see a session recorded through B")
    }

    func testRatingPromptPresenter_IsPerContainerAndDrivesItsOwnService() {
        let presenterA = containerA.ratingPromptPresenter
        let presenterB = containerB.ratingPromptPresenter

        XCTAssertFalse(presenterA === presenterB, "Two containers must not share one rating prompt presenter")
        let service: AppRatingService? = reflected("service", of: presenterB)
        XCTAssertTrue(service === containerB.appRatingService, "B's prompt must drive B's rating service")
    }

    // MARK: - Side-loading and offline queue

    func testSideloadedBookRegistry_IsPerContainer() {
        XCTAssertFalse(containerA.sideloadedBookRegistry === containerB.sideloadedBookRegistry,
                       "Two containers must not share one side-loaded registry")
        XCTAssertTrue(containerB.sideloadedBookRegistry === containerB.sideloadedBookRegistry,
                      "One container must keep handing back the same side-loaded registry")
    }

    /// B's side-load manager writes B's registries.
    func testSideloadedBookManager_IsPerContainerAndWritesItsOwnRegistries() {
        let managerA = containerA.sideloadedBookManager
        let managerB = containerB.sideloadedBookManager

        XCTAssertFalse(managerA === managerB, "Two containers must not share one side-load manager")
        let registry: TPPBookRegistryProvider? = reflected("bookRegistry", of: managerB)
        XCTAssertTrue((registry as AnyObject) === (containerB.bookRegistry as AnyObject), "B's side-load manager must write B's book registry")
        let sideloaded: SideloadedBookRegistry? = reflected("sideloadedRegistry", of: managerB)
        XCTAssertTrue(sideloaded === containerB.sideloadedBookRegistry,
                      "B's side-load manager must write B's side-loaded registry")
    }

    /// Registering B's offline-queue executor fills B's slot and leaves A's empty.
    func testOfflineQueueCoordinator_RegistersInItsOwnContainerOnly() {
        containerB.ensureOfflineQueueExecutorRegistered()

        XCTAssertNotNil(containerB.processServices.offlineQueueCoordinator.withLock { $0 },
                        "Registering through B must fill B's slot")
        XCTAssertNil(containerA.processServices.offlineQueueCoordinator.withLock { $0 },
                     "Registering through B must leave A's slot empty, so A can register its own")
    }

    // MARK: - One owner

    /// Every `production()` read and every copy of a container reach one set.
    func testProduction_KeepsOneProcessServicesInstance() {
        let first = AppContainer.production().processServices // MIGRATED-DEFERRED: the app's one set is what this pins
        let second = AppContainer.production().processServices // MIGRATED-DEFERRED: the app's one set is what this pins

        XCTAssertTrue(first === second, "Every production() read must reach the same process services")
        XCTAssertTrue(AppContainer.production().nonOwningCopy().processServices === first, // MIGRATED-DEFERRED: the app's one set is what this pins
                      "A non-owning copy must reach the same process services")
        let copy = containerB.withAudiobookSessionPresenter(SpyAudiobookSessionPresenter())
        XCTAssertTrue(copy.processServices === containerB.processServices,
                      "A copy with an override must keep its container's process services")
        XCTAssertTrue((copy.audiobookSession as AnyObject) === (containerB.audiobookSession as AnyObject),
                      "A copy with an override must keep its container's audiobook session")
    }

    /// A rebuilt test graph gets a new set, so no process service from a
    /// discarded graph survives the reset.
    func testResetForTesting_BuildsANewProcessServicesInstance() {
        let before = AppContainer.production().processServices // MIGRATED-DEFERRED: the reset rebuilds the app's graph

        AppContainer._resetForTesting()

        XCTAssertFalse(AppContainer.production().processServices === before, // MIGRATED-DEFERRED: the reset rebuilds the app's graph
                       "The rebuilt graph must own a new set of process services")
    }

    // MARK: - Helpers

    /// Reads a stored property by name; the services keep these private.
    private func reflected<T>(_ label: String, of subject: Any) -> T? {
        Mirror(reflecting: subject).children.first { $0.label == label }?.value as? T
    }
}
