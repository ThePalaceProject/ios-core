//
//  AudiobookOverdriveRefulfillWiringTests.swift
//  PalaceTests
//
//  Drives the session manager's own bound wiring for the OverDrive
//  re-fulfilment: which opens re-arm it, what a failure decides from the live
//  bounds, and that the recovery leaves flight when it ends (PP-4967). The
//  struct and the reducer are tabled elsewhere; this pins the call sites.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace
#if FEATURE_OVERDRIVE
import OverdriveProcessor
#endif

#if FEATURE_OVERDRIVE
@MainActor
private final class StarterSpy {
    var started: [String] = []
}

@MainActor
final class AudiobookOverdriveRefulfillWiringTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var sut: AudiobookSessionManager!
    private var spy: StarterSpy!
    private var started: [String] { spy.started }
    private var book: TPPBook!

    override func setUp() {
        super.setUp()
        registry = TPPBookRegistryMock()
        let spy = StarterSpy()
        self.spy = spy
        sut = AudiobookSessionManager(
            appContainer: makeTestAppContainer(bookRegistry: registry),
            overdriveRefulfillStarter: { book in spy.started.append(book.identifier) }
        )
        book = TPPBook(
            acquisitions: [TPPOPDSAcquisition(
                relation: .generic,
                type: "application/vnd.overdrive.circulation.api+json;profile=audiobook",
                hrefURL: URL(string: "https://od.test/fulfill")!,
                indirectAcquisitions: [],
                availability: TPPOPDSAcquisitionAvailabilityUnlimited()
            )],
            authors: [], categoryStrings: [], distributor: OverdriveDistributorKey,
            identifier: "urn:od:wiring", imageURL: nil, imageThumbnailURL: nil,
            published: Date(), publisher: "Test", subtitle: nil, summary: nil,
            title: "OD Wiring", updated: Date(), annotationsURL: nil, analyticsURL: nil,
            alternateURL: nil, relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil, contributors: [:],
            bookDuration: nil, imageCache: MockImageCache()
        )
        registry.addBook(book, state: .downloadSuccessful)
    }

    override func tearDown() {
        sut = nil
        spy = nil
        registry = nil
        book = nil
        super.tearDown()
    }

    private var expired: NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable)
    }

    private func recovery(for error: Error) -> AudiobookPlaybackRecovery? {
        guard case .publish(_, let recovery) = sut.playbackFailureOutcome(for: book, bookId: book.identifier, error: error) else {
            return nil
        }
        return recovery
    }

    private func patronOpen() {
        XCTAssertTrue(sut.noteOpenForRecoveryBounds(
            of: book.identifier, forceRefulfill: false, isColdLoadRecovery: false, isRecoveryReopen: false))
    }

    /// Starts the one re-fulfilment exactly as the `.playbackFailed` arm does.
    private func startRefulfilment() throws {
        let recovery = try XCTUnwrap(recovery(for: expired))
        XCTAssertEqual(recovery, .overdriveRefulfill, "arrange")
        sut.noteRecoveryStarted(recovery, for: book.identifier)
    }

    func testExpiredLink_whileTheRefulfilmentRuns_isSuppressed() throws {
        patronOpen()
        try startRefulfilment()

        XCTAssertEqual(
            sut.playbackFailureOutcome(for: book, bookId: book.identifier, error: expired),
            .suppressFollowOnFailure,
            "a follow-on failure from the old player must not start a second re-fulfilment")
    }

    func testRefulfilment_runsTheDownloadCentreOnce_andLeavesFlight() async throws {
        patronOpen()
        try startRefulfilment()

        await sut.recoverExpiredOverdriveByRefulfilling(book)

        XCTAssertEqual(started, [book.identifier], "fulfilment is re-run through the download centre, once")
        XCTAssertEqual(registry.state(for: book.identifier), .downloadNeeded,
                       "the download centre ignores a start for a downloaded book, so the state is reset first")
        XCTAssertEqual(sut.recoveryAttempts.overdriveRefulfill(for: book.identifier), .spent)
        XCTAssertEqual(recovery(for: expired), .overdriveRefulfillExhausted,
                       "the re-open's own expiry is the answer and ends the session with the message")
    }

    func testRecoveryReopen_doesNotReArmTheRefulfilment() async throws {
        patronOpen()
        try startRefulfilment()
        await sut.recoverExpiredOverdriveByRefulfilling(book)

        XCTAssertFalse(sut.noteOpenForRecoveryBounds(
            of: book.identifier, forceRefulfill: false, isColdLoadRecovery: false, isRecoveryReopen: true))

        XCTAssertEqual(recovery(for: expired), .overdriveRefulfillExhausted,
                       "re-arming here is what let a fresh link that also failed re-fulfil without end")
    }

    func testColdLoadReopen_doesNotReArmTheRefulfilment() async throws {
        patronOpen()
        try startRefulfilment()
        await sut.recoverExpiredOverdriveByRefulfilling(book)

        XCTAssertFalse(sut.noteOpenForRecoveryBounds(
            of: book.identifier, forceRefulfill: false, isColdLoadRecovery: true, isRecoveryReopen: false))

        XCTAssertEqual(recovery(for: expired), .overdriveRefulfillExhausted)
    }

    func testPatronOpen_afterExhaustion_allowsOneMoreRefulfilment() async throws {
        patronOpen()
        try startRefulfilment()
        await sut.recoverExpiredOverdriveByRefulfilling(book)

        patronOpen()

        XCTAssertEqual(recovery(for: expired), .overdriveRefulfill,
                       "the patron tapping the book again is a fresh attempt")
    }
}
#endif
