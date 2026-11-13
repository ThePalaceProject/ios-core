//
//  CarPlayPlaybackOutcomeTests.swift
//  PalaceTests
//
//  What CarPlay tells the patron when an open from the head unit ends. An open
//  replaced by a stop or a newer open returns `.alreadyLoading` (PP-5302) and
//  must not show "Playback failed"; a real failure still must.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class CarPlayPlaybackOutcomeTests: XCTestCase {

    private var session: SpyShimSession!
    private var bridge: CarPlayAudiobookBridge!
    private var outcome: CarPlayAudiobookBridge.PlaybackResult?

    override func setUp() async throws {
        try await super.setUp()
        session = SpyShimSession()
        bridge = CarPlayAudiobookBridge(sessionManager: session)
        outcome = nil
    }

    override func tearDown() async throws {
        bridge = nil
        session = nil
        outcome = nil
        try await super.tearDown()
    }

    /// Plays a book from CarPlay and returns the alert the template manager
    /// would show for the outcome, or nil for none.
    private func alertAfterPlay(whenOpenReturns result: Result<Void, AudiobookSessionError>) async -> (title: String, message: String)? {
        session.openAudiobookResult = result
        bridge.playAudiobook(TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)) { [weak self] in
            self?.outcome = $0
        }
        await awaitConditionAsync { self.outcome != nil }
        guard case .failure(let error)? = outcome else { return nil }
        return error.alertContent
    }

    func testPlay_whenOpenIsSuperseded_showsNoAlert() async {
        let alert = await alertAfterPlay(whenOpenReturns: .failure(.alreadyLoading))

        XCTAssertNotNil(outcome, "the template manager must still hear back, to clear its loading flag")
        XCTAssertNil(alert, "a stopped or replaced open must not tell the patron playback failed: \(String(describing: alert))")
    }

    func testPlay_whenOpenFails_showsPlaybackFailedAlert() async {
        let alert = await alertAfterPlay(whenOpenReturns: .failure(.manifestLoadFailed))

        XCTAssertEqual(alert?.title, Strings.CarPlay.Error.playbackFailed)
        XCTAssertEqual(alert?.message, Strings.CarPlay.Error.tryAgain)
    }

    func testPlay_whenNotSignedIn_showsSignInAlert() async {
        let alert = await alertAfterPlay(whenOpenReturns: .failure(.notAuthenticated))

        XCTAssertEqual(alert?.title, Strings.CarPlay.Error.authRequired)
    }

    func testPlay_whenOpenSucceeds_reportsSuccess() async {
        let alert = await alertAfterPlay(whenOpenReturns: .success(()))

        XCTAssertNil(alert)
        guard case .success? = outcome else {
            return XCTFail("expected success, got \(String(describing: outcome))")
        }
    }
}
