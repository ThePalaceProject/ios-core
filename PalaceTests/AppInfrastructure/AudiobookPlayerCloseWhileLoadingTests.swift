//
//  AudiobookPlayerCloseWhileLoadingTests.swift
//  PalaceTests
//
//  The full player's loading overlays are opaque and cover its top row, so the
//  close control is drawn again above them (PP-5302). These tests mount the real
//  player and check the accessibility tree while it loads: one Close, first in
//  VoiceOver order, that stops playback. They cannot see z-order; the UI journey
//  `AudiobookCloseMidLoadJourneyTests` guards that the ✕ is tappable.
//

import SwiftUI
import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookPlayerCloseWhileLoadingTests: XCTestCase {

    private var host: AccessibilityAuditHost?

    override class func tearDown() {
        MainActor.assumeIsolated { AccessibilityRuntime.restore() }
        super.tearDown()
    }

    override func tearDown() {
        host?.tearDown()
        host = nil
        super.tearDown()
    }

    private func mountPlayer(_ configure: (AudiobookSessionPresenter, SpyShimSession) -> Void) -> (AccessibilityAuditHost, SpyShimSession) {
        let session = SpyShimSession()
        let presenter = AudiobookSessionPresenter(sessionManager: session)
        presenter.adoptBook(TPPBookMocker.snapshotAudiobook())
        presenter.expand()
        configure(presenter, session)
        let suite = "close-while-loading.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let player = AudiobookMorphingPlayerView(
            presenter: presenter, progress: presenter.progress, audiobookSession: session)
            .defaultAppStorage(defaults)
        let host = AccessibilityAuditHost(UIHostingController(rootView: player))
        self.host = host
        host.settle(0.8)
        return (host, session)
    }

    private func closeElements(in host: AccessibilityAuditHost) -> [AXAuditElement] {
        AccessibilityTraversalAudit.traverse(host.window).filter { $0.label == Strings.Generic.close }
    }

    private func isFloatingClose(_ element: AXAuditElement) -> Bool {
        // SwiftUI's accessibility nodes answer the identifier without
        // declaring `UIAccessibilityIdentification`, so read it by key.
        element.object.value(forKey: "accessibilityIdentifier") as? String
            == AudiobookMorphingPlayerView.closeAboveLoadingOverlayIdentifier
    }

    /// While loading, exactly one Close is reachable, it is the overlay copy, it is
    /// first in VoiceOver order, and activating it ends the session.
    private func assertSingleCloseStopsPlayback(_ host: AccessibilityAuditHost, _ session: SpyShimSession,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let closes = closeElements(in: host)
        XCTAssertEqual(closes.count, 1, "one close control, not one per layer", file: file, line: line)
        let close = try XCTUnwrap(closes.first, file: file, line: line)
        XCTAssertTrue(isFloatingClose(close), "the reachable Close must be the overlay copy, not the covered one",
                      file: file, line: line)
        XCTAssertTrue(close.isActionable, file: file, line: line)
        let firstActionable = AccessibilityTraversalAudit.traverse(host.window).first { $0.isActionable }
        XCTAssertEqual(firstActionable?.label, Strings.Generic.close, "close stays first in VoiceOver order",
                       file: file, line: line)

        XCTAssertTrue(AccessibilityTraversalAudit.activate(close, in: host.window).succeeded, file: file, line: line)
        await awaitConditionAsync(file: file, line: line) { session.stopPlaybackCallCount == 1 }
        XCTAssertEqual(session.lastStopPlaybackDismissPhoneUI, true, file: file, line: line)
    }

    func testLoadingSkeleton_offersOneCloseFirstThatStopsPlayback() async throws {
        let (host, session) = mountPlayer { _, session in session.isLoaded = false }

        try await assertSingleCloseStopsPlayback(host, session)
    }

    func testDownloadingPanel_offersOneCloseFirstThatStopsPlayback() async throws {
        let (host, session) = mountPlayer { presenter, session in
            session.isLoaded = false
            presenter.showDownloadProgress(0.3)
        }

        try await assertSingleCloseStopsPlayback(host, session)
    }

    /// A loaded player draws no overlay, so only the top row's own close shows.
    func testLoadedPlayer_hasOnlyItsOwnCloseControl() {
        let (host, _) = mountPlayer { _, _ in }

        let closes = closeElements(in: host)
        XCTAssertEqual(closes.count, 1)
        XCTAssertFalse(closes.contains(where: isFloatingClose))
    }

    /// The load error is opaque too; the empty mid-session reload state is not.
    func testCoveringStates_areExactlyTheOpaqueOverlays() {
        let covering = AudiobookMorphingPlayerView.LoadingOverlayState.allCases
            .filter(AudiobookMorphingPlayerView.loadingOverlayCoversControls)

        XCTAssertEqual(Set(covering.map { "\($0)" }), ["skeleton", "downloading", "loadError"])
    }
}
