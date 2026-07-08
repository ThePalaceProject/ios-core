//
//  BackgroundSessionRoutingTests.swift
//  PalaceTests
//
//  Reliability WS-A — INV-7: the background-session completion handler is
//  routed by identifier (download-center vs. audiobook) and invoked exactly
//  once. These pin the pure routing predicate the app delegate uses (so the
//  audiobook route is preserved) and the store/invoke-once/clear contract of
//  the download center's finish-events callback.
//

import XCTest
@testable import Palace

final class BackgroundSessionRoutingTests: XCTestCase {

    // MARK: - Routing predicate (INV-7)

    func testIsDownloadCenterBackgroundSession_matchesOwnIdentifier() {
        let ownID = MyBooksDownloadCenter.backgroundSessionIdentifier
        XCTAssertTrue(MyBooksDownloadCenter.isDownloadCenterBackgroundSession(ownID))
    }

    func testIsDownloadCenterBackgroundSession_rejectsAudiobookIdentifier() {
        // A Findaway / OpenAccess audiobook background-session identifier must
        // NOT be claimed by the download center — the app delegate keeps routing
        // it to the audiobook lifecycle manager (INV-7).
        let audiobookID = (Bundle.main.bundleIdentifier ?? "") + ".findaway.background"
        XCTAssertFalse(MyBooksDownloadCenter.isDownloadCenterBackgroundSession(audiobookID))
        XCTAssertFalse(MyBooksDownloadCenter.isDownloadCenterBackgroundSession("com.audioengine.some.other"))
        XCTAssertFalse(MyBooksDownloadCenter.isDownloadCenterBackgroundSession(""))
    }

    func testDownloadCenterIdentifier_hasExpectedSuffix() {
        XCTAssertTrue(
            MyBooksDownloadCenter.backgroundSessionIdentifier.hasSuffix(".downloadCenterBackgroundIdentifier"),
            "background identifier suffix is the contract the app delegate matches on")
    }

    // MARK: - Finish-events store/invoke-once/clear (INV-7)

    @MainActor
    private func makeCenter() -> MyBooksDownloadCenter {
        MyBooksDownloadCenter(
            bookRegistry: TPPBookRegistryMock(),
            stateManager: DownloadStateManager(),
            reachability: MockReachability(initiallyConnected: true)
        )
    }

    @MainActor
    func testFinishEvents_invokesStoredHandlerOnce() {
        let center = makeCenter()
        let session = URLSession(configuration: .ephemeral)

        var invocationCount = 0
        center.setBackgroundCompletionHandler { invocationCount += 1 }

        // iOS could deliver the finish-events callback more than once across
        // session re-creation; the handler must fire exactly once then be cleared.
        center.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        center.urlSessionDidFinishEvents(forBackgroundURLSession: session)

        XCTAssertEqual(invocationCount, 1,
                       "stored system completion handler must be invoked exactly once, then cleared")
    }

    @MainActor
    func testFinishEvents_withNoStoredHandler_isNoOp() {
        let center = makeCenter()
        let session = URLSession(configuration: .ephemeral)
        // Must not crash when iOS delivers finish-events with nothing stored.
        center.urlSessionDidFinishEvents(forBackgroundURLSession: session)
    }

    @MainActor
    func testFinishEvents_afterClear_newHandlerCanBeStoredAndFiredOnce() {
        let center = makeCenter()
        let session = URLSession(configuration: .ephemeral)

        var first = 0, second = 0
        center.setBackgroundCompletionHandler { first += 1 }
        center.urlSessionDidFinishEvents(forBackgroundURLSession: session)

        center.setBackgroundCompletionHandler { second += 1 }
        center.urlSessionDidFinishEvents(forBackgroundURLSession: session)

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1, "a fresh handler stored after a prior wake fires once on the next wake")
    }
}
