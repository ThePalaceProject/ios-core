//
//  AudiobookOpenOriginWiringTests.swift
//  PalaceTests
//
//  What each open origin does to the loader and the LCP content gate, through
//  a real open (PP-4973). The bearer-token re-open must fetch a fresh manifest
//  (HelpSpot #18471); the cold-load re-open must skip the content gate.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookOpenOriginWiringTests: AudiobookSessionOpenTestCase {

    func testPatronOpen_usesTheManifestOnDisk() async throws {
        await startParkedOpen(downloadedBook("book-a"))

        XCTAssertEqual(loaders.fetchesFreshManifest, [false])
        await finishOpens()
    }

    func testColdLoadReopen_usesTheManifestOnDisk() async throws {
        await startParkedOpen(downloadedBook("book-a"))

        failFirstPlay()

        await awaitConditionAsync { self.adapters.count == 2 && self.adapters[1].resolveCallCount == 1 }
        XCTAssertEqual(loaders.fetchesFreshManifest, [false, false])
        await finishOpens()
    }

    /// An expired entitlement on a bearer-token audiobook re-opens with a
    /// fresh manifest; the one on disk carries the expired signed URLs.
    func testBearerTokenExpiry_reopensWithAFreshManifest() async throws {
        let book = TPPBookMocker.mockBook(identifier: "bearer-a", title: "bearer-a", distributorType: .BearerToken)
        registry.addBook(book, state: .downloadSuccessful)
        await startParkedOpen(book)

        sut.handleManagerState(.playbackFailed(nil, NSError(domain: "test.playback", code: 1, userInfo: ["httpStatusCode": 410])))

        await awaitConditionAsync { self.adapters.count == 2 && self.adapters[1].resolveCallCount == 1 }
        XCTAssertEqual(loaders.fetchesFreshManifest, [false, true])
        await finishOpens()
    }

#if LCP
    /// A patron open of an LCP book with no content on disk triggers the
    /// download and waits; the cold-load re-open after the first-play failure
    /// has already waited, so it skips the gate and goes straight to the load.
    func testLCPColdLoadReopen_skipsTheContentGate() async throws {
        content.isLocal = false
        let book = lcpBook("lcp-a")
        startOpen(book)
        await awaitConditionAsync { self.content.landed != nil }
        XCTAssertEqual(contentDownloadsTriggered, [book.identifier], "the patron open goes through the gate")
        content.land(true)
        await awaitConditionAsync { self.adapters.count == 1 && self.adapters[0].resolveCallCount == 1 }

        failFirstPlay()
        await awaitConditionAsync { self.content.landed != nil }
        content.land(true)

        await awaitConditionAsync { self.adapters.count == 2 && self.adapters[1].resolveCallCount == 1 }
        XCTAssertEqual(contentDownloadsTriggered, [book.identifier], "the cold-load re-open must not re-enter the gate")
        await finishOpens()
    }
#endif
}
